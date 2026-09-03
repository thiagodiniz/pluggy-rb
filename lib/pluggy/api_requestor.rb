# frozen_string_literal: true

require "net/http"
require "json"
require "bigdecimal"

module Pluggy
  # Builds, sends and interprets every HTTP request.
  #
  # Owns three things worth understanding: the apiKey lifecycle, the 403 fork,
  # and the retry policy.
  class APIRequestor
    IDEMPOTENT_METHODS = %i[get head delete].freeze

    # POST endpoints that are safe to retry because they create no durable
    # resource. POST /items is NOT here on purpose: the API offers no
    # Idempotency-Key, so retrying it risks opening a duplicate bank
    # connection, which is user-visible and awkward to undo.
    RETRYABLE_POST_PATHS = ["/auth", "/connect_token"].freeze

    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

    RETRY_ERRORS = [
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE, Errno::EHOSTUNREACH,
      Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
      EOFError, SocketError, IOError, OpenSSL::SSL::SSLError
    ].freeze

    attr_reader :config, :credentials

    def initialize(config, credentials = nil)
      @config = config
      @credentials = credentials || CredentialStore.new(config)
    end

    # --- surface used by services ------------------------------------------

    def request(method, path, params: nil, body: nil, opaque_body_keys: [])
      url = build_path(path, params)
      payload = body && Util.encode_body(body, opaque: opaque_body_keys)
      execute(method, url, payload, authenticated: true)
    end

    # For cursor pagination: `path_with_query` already carries the server's
    # "?..." string, so no query building happens at all.
    def request_raw(method, path_with_query)
      execute(method, path_with_query, nil, authenticated: true)
    end

    # POST /auth is the only unauthenticated operation in the API.
    def execute_unauthenticated(method, path, body: nil)
      execute(method, path, body, authenticated: false)
    end

    def list(path, params:, klass:, client:, paginated: false)
      Lists.wrap(
        request(:get, path, params: params),
        klass: klass, requestor: self, path: path,
        filters: params || {}, client: client, paginated: paginated
      )
    end

    def list_raw(path_with_query, klass:, client:)
      Lists.wrap(
        request_raw(:get, path_with_query),
        klass: klass, requestor: self, path: path_with_query.split("?").first, client: client
      )
    end

    # --- internals ---------------------------------------------------------

    private

    def execute(method, path, payload, authenticated:)
      attempts = 0
      reauthed = false

      loop do
        key = authenticated ? @credentials.fetch(self) : nil

        response = attempt(method, path, payload, key) do |error|
          attempts += 1
          raise wrap_connection_error(error) unless retryable?(method, path, attempts)

          backoff(attempts, nil)
        end
        next if response.nil? # transport failure, already backed off

        status = response.code.to_i
        parsed = parse_body(response)

        return parsed if status < 300

        if renew_and_retry?(status, response, parsed, authenticated: authenticated, reauthed: reauthed)
          @config.log(:info, "apiKey rejected, renewing", path: path)
          @credentials.refresh!(self, stale: key)
          reauthed = true
          next
        end

        attempts += 1
        if RETRY_STATUSES.include?(status) && retryable?(method, path, attempts)
          backoff(attempts, response["retry-after"])
          next
        end

        raise build_error(status, response, parsed, reauthed: reauthed)
      end
    end

    # Returns the response, or nil when the request died at the transport level
    # and should be retried. The block decides whether a retry is allowed (it
    # raises if not) and applies the backoff.
    def attempt(method, path, payload, key)
      perform_logged(method, path, payload, key)
    rescue *RETRY_ERRORS => e
      # A half-dead keep-alive socket would poison the retry.
      ConnectionManager.current.clear!
      yield e
      nil
    end

    # The 403 fork.
    #
    # Only a 403 with NO codeDescription means the apiKey aged out. One that has
    # a codeDescription (e.g. BALANCE_CONSENT_ERROR) is a domain denial: renewing
    # would mask it and double every affected call.
    def renew_and_retry?(status, response, parsed, authenticated:, reauthed:)
      return false unless status == 403 && authenticated
      return false unless expired_key?(parsed)

      # Nothing to renew with: say so, rather than reporting it as a permission
      # problem the caller cannot act on.
      raise static_key_rejected(status, response, parsed) if @credentials.static?

      !reauthed
    end

    # NotAuthenticatedResponse is {code, message}; GlobalErrorResponse adds
    # codeDescription. That difference is the only signal the API gives us.
    def expired_key?(parsed)
      parsed.is_a?(Hash) && parsed["codeDescription"].nil?
    end

    def perform_logged(method, path, payload, key)
      started = now
      response = perform(method, path, payload, key)
      @config.log(:debug, "#{method.to_s.upcase} #{path}",
        status: response.code, ms: ((now - started) * 1000).round)
      response
    end

    def perform(method, path, payload, key)
      http = ConnectionManager.current.connection_for(@config)
      request_class = Net::HTTP.const_get(method.to_s.capitalize)
      req = request_class.new(path, headers(key, payload))
      req.body = JSON.generate(payload) if payload
      http.request(req)
    end

    def headers(key, payload)
      # Accept-Encoding is left to Net::HTTP: setting it by hand turns off its
      # transparent decompression, which would leave every response body -- and
      # every Error#http_body built from one -- as raw gzip bytes.
      h = {
        "Accept" => "application/json",
        "User-Agent" => user_agent
      }
      h["X-API-KEY"] = key.to_s if key
      h["Content-Type"] = "application/json" if payload
      h
    end

    def user_agent
      @user_agent ||= [
        "pluggy-rb/#{Pluggy::VERSION}",
        "ruby/#{RUBY_VERSION}",
        "(#{RUBY_PLATFORM})",
        @config.user_agent_suffix
      ].compact.join(" ")
    end

    def build_path(path, params)
      query = Util.encode_query(params)
      query.empty? ? path : "#{path}?#{query}"
    end

    def parse_body(response)
      raw = response.body.to_s
      return nil if raw.empty?

      # decimal_class reads the lexical digits straight off the wire, so money
      # never passes through a Float. Integers stay Integer.
      options = @config.decimal_amounts ? { decimal_class: BigDecimal } : {}
      JSON.parse(raw, **options)
    rescue JSON::ParserError
      # A proxy or CDN error page; hand it back for the error builder to show.
      raw
    end

    def retryable?(method, path, attempts)
      return false if attempts > @config.max_network_retries

      idempotent?(method, path)
    end

    def idempotent?(method, path)
      return true if IDEMPOTENT_METHODS.include?(method)
      return RETRYABLE_POST_PATHS.any? { |p| path.start_with?(p) } if method == :post

      # PATCH /items/{id} triggers a re-sync: harmless to repeat, but it queues
      # redundant work at the institution, so leave it alone.
      false
    end

    def backoff(attempts, retry_after)
      base = @config.initial_network_retry_delay * (2**(attempts - 1))
      delay = [base, @config.max_network_retry_delay].min
      delay *= (0.5 + (rand * 0.5)) # jitter: 50-100% of the interval

      # Undocumented in the spec, but honour it when a proxy or the
      # institution sends one.
      delay = [retry_after.to_f, delay].max if retry_after.to_s.match?(/\A\d+(\.\d+)?\z/)

      @config.log(:info, "retrying", attempt: attempts, delay: delay.round(3))
      sleep(delay)
    end

    def build_error(status, response, parsed, reauthed:)
      json = parsed.is_a?(Hash) ? parsed : nil

      klass =
        if status == 403 && reauthed
          # It survived a renewal, so the key is not the problem.
          AuthenticationError
        else
          Pluggy.error_class_for(status)
        end

      klass.new(
        json&.fetch("message", nil),
        http_status: status,
        http_body: response.body,
        http_headers: response.each_header.to_h,
        json_body: json
      )
    end

    def static_key_rejected(status, response, parsed)
      AuthenticationError.new(
        "the supplied apiKey was rejected by Pluggy and there are no credentials to renew it " \
        "with; construct Pluggy::Client with client_id: and client_secret: for automatic renewal",
        http_status: status,
        http_body: response.body,
        http_headers: response.each_header.to_h,
        json_body: parsed.is_a?(Hash) ? parsed : nil
      )
    end

    def wrap_connection_error(error)
      klass = error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout) ? TimeoutError : ConnectionError
      klass.new("#{error.class}: #{error.message} (#{@config.api_base})")
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
