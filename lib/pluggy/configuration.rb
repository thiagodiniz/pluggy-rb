# frozen_string_literal: true

require "uri"

module Pluggy
  class Configuration
    DEFAULTS = {
      api_base: "https://api.pluggy.ai",
      client_id: nil,
      client_secret: nil,
      # A pre-existing apiKey. Disables automatic renewal: there are no
      # credentials to renew with, so an expiry raises AuthenticationError.
      api_key: nil,
      open_timeout: 30,
      # Generous because GET /accounts/{id}/balance proxies to the financial
      # institution in real time -- it is the one endpoint in scope that
      # documents both a 429 and a 502.
      read_timeout: 80,
      write_timeout: 30,
      max_network_retries: 2,
      initial_network_retry_delay: 0.5,
      max_network_retry_delay: 4.0,
      logger: nil,
      log_level: :info,
      # Parse JSON numbers as BigDecimal. Turning this off yields plain Floats
      # and makes the gem dependency-free.
      decimal_amounts: true,
      coerce_times: true,
      user_agent_suffix: nil,
      verify_ssl_certs: true,
      # :v2 (cursor, current) or :v1 (offset, deprecated, sunset 2026-12-31).
      transactions_api_version: :v2
    }.freeze

    LOG_LEVELS = { debug: 0, info: 1, error: 2 }.freeze

    SECRET_OPTIONS = %i[client_secret api_key].freeze

    DEFAULTS.each_key { |key| attr_accessor key }

    def self.setup
      new.tap { |config| yield config if block_given? }
    end

    def initialize(**overrides)
      DEFAULTS.each { |key, value| instance_variable_set(:"@#{key}", value) }
      apply(overrides)
    end

    # Per-client options win over the globals they were merged from, but only
    # where explicitly given -- Stripe's reverse_duplicate_merge.
    def merge(**overrides)
      dup.tap { |config| config.send(:apply, overrides.compact) }
    end

    def uri
      @uri ||= URI.parse(api_base)
    end

    # Net::HTTP pool key: two configs pointing at the same endpoint share a
    # connection.
    def connection_key
      [uri.host, uri.port, verify_ssl_certs]
    end

    def credentials?
      !(client_id.nil? || client_secret.nil?)
    end

    def validate!
      return if credentials? || api_key

      raise ConfigurationError,
        "provide client_id: and client_secret: (or api_key:) to Pluggy::Client.new, " \
        "or set Pluggy.client_id / Pluggy.client_secret"
    end

    def log(level, message, **context)
      return unless logger
      return unless LOG_LEVELS.fetch(level, 1) >= LOG_LEVELS.fetch(log_level, 1)

      suffix = context.map { |k, v| "#{k}=#{v}" }.join(" ")
      logger.public_send(level, "[pluggy] #{message}#{" #{suffix}" unless suffix.empty?}")
    end

    # Never leak secrets into a log, a console session or an exception.
    def inspect
      shown = DEFAULTS.keys.map do |key|
        value = public_send(key)
        value = redact(value) if SECRET_OPTIONS.include?(key)
        "#{key}=#{value.inspect}"
      end
      "#<Pluggy::Configuration #{shown.join(" ")}>"
    end
    alias to_s inspect

    private

    def apply(overrides)
      overrides.each do |key, value|
        raise ArgumentError, "unknown Pluggy configuration option: #{key}" unless DEFAULTS.key?(key)

        public_send(:"#{key}=", value)
      end
      @uri = nil
    end

    def redact(value)
      return nil if value.nil?

      "***#{value.to_s[-4..]}"
    end
  end
end
