# frozen_string_literal: true

require "json"
require "time"

module Pluggy
  # An apiKey from POST /auth, with its expiry.
  #
  # Pluggy documents a 2-hour lifetime, but the token is a JWT, so read the
  # `exp` claim instead of assuming: it costs nothing, needs no dependency, and
  # self-corrects if Pluggy ever changes the TTL. No signature verification --
  # we are only reading the clock on a token we were just handed.
  class ApiKey
    # Used only when `exp` cannot be read (an opaque token, or a shape change).
    FALLBACK_TTL = 2 * 60 * 60

    # Renew slightly early so a request can't expire in flight.
    SKEW = 60

    attr_reader :token, :expires_at

    def initialize(token, expires_at: nil)
      raise ArgumentError, "apiKey cannot be empty" if token.nil? || token.to_s.empty?

      @token = token.to_s
      @expires_at = expires_at || self.class.jwt_expiry(@token) || (Time.now + FALLBACK_TTL)
    end

    def expired?(now = Time.now)
      now >= (@expires_at - SKEW)
    end

    def to_s = @token

    def inspect
      "#<Pluggy::ApiKey ***#{@token[-6..]} expires_at=#{@expires_at.iso8601}>"
    end

    # Decode a base64url JWT payload and read `exp`.
    #
    # Deliberately does not require "base64": it is a *bundled*, not a default,
    # gem from Ruby 3.4 on, so requiring it can fail under Bundler.
    # String#unpack1("m0") is core and does the same job.
    def self.jwt_expiry(token)
      segment = token.split(".")[1]
      return nil unless segment

      padded = segment.tr("-_", "+/")
      padded += "=" * ((4 - (padded.length % 4)) % 4)

      exp = JSON.parse(padded.unpack1("m0"))["exp"]
      exp.is_a?(Numeric) ? Time.at(exp) : nil
    rescue StandardError
      nil
    end
  end
end
