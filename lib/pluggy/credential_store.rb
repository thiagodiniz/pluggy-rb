# frozen_string_literal: true

module Pluggy
  # Holds the current apiKey for one client and renews it as needed.
  #
  # One store per Client, so a key is fetched at most once per lifetime
  # regardless of how many services or threads use it.
  class CredentialStore
    def initialize(config)
      @config = config
      @mutex = Mutex.new
      @key = config.api_key ? ApiKey.new(config.api_key) : nil
      # A caller-supplied key with no credentials behind it cannot be renewed.
      @static = !config.api_key.nil? && !config.credentials?
    end

    def static? = @static

    def fetch(requestor)
      @mutex.synchronize do
        @key = authenticate(requestor) if @key.nil? || (!@static && @key.expired?)
        @key
      end
    end

    # Called after a 403 whose body carried no codeDescription -- see
    # APIRequestor#expired_key?.
    #
    # `stale` is the key that just failed. If another thread has already
    # rotated it, reuse theirs rather than authenticating again: N threads
    # hitting expiry together produce exactly one POST /auth.
    def refresh!(requestor, stale:)
      if @static
        raise AuthenticationError,
          "the supplied apiKey was rejected and there are no credentials to renew it with; " \
          "construct Pluggy::Client with client_id: and client_secret: for automatic renewal"
      end

      @mutex.synchronize do
        return @key if @key && !@key.equal?(stale)

        @key = authenticate(requestor)
      end
    end

    private

    def authenticate(requestor)
      @config.validate!

      body = requestor.execute_unauthenticated(
        :post, "/auth",
        body: { "clientId" => @config.client_id, "clientSecret" => @config.client_secret }
      )

      unless body.is_a?(Hash) && body["apiKey"]
        raise AuthenticationError.new("POST /auth succeeded but returned no apiKey", json_body: body)
      end

      ApiKey.new(body["apiKey"]).tap do |key|
        @config.log(:info, "authenticated", expires_at: key.expires_at.iso8601)
      end
    end
  end
end
