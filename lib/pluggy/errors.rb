# frozen_string_literal: true

module Pluggy
  # Flat, one-level hierarchy off a single base carrying the whole HTTP
  # transcript. Unlike Stripe there is no request id: the Pluggy spec documents
  # zero response headers, so nothing reliable exists to capture.
  class Error < StandardError
    attr_reader :http_status, :http_body, :http_headers, :json_body,
      :code, :code_description, :data, :api_message

    def initialize(message = nil, http_status: nil, http_body: nil, http_headers: nil, json_body: nil)
      @http_status = http_status
      @http_body = http_body
      @http_headers = http_headers || {}
      @json_body = json_body

      if json_body.is_a?(Hash)
        @code = json_body["code"]
        @code_description = json_body["codeDescription"]
        @data = json_body["data"]
      end

      # The API's own text, undecorated. #message and #to_s append the
      # codeDescription because that is what you want in a log line; this is
      # here for when you want to render just the message.
      @api_message = message || @json_body&.fetch("message", nil) || default_message

      super(@api_message)
    end

    def to_s
      @code_description ? "#{@api_message} (#{@code_description})" : @api_message
    end

    private

    def default_message
      @http_status ? "Pluggy API returned HTTP #{@http_status}" : "Pluggy API error"
    end
  end

  # Raised locally, before any request goes out.
  class ConfigurationError < Error; end

  # Transport-level: nothing came back, or the socket died.
  class ConnectionError < Error; end
  class TimeoutError < ConnectionError; end

  # POST /auth rejected the client keys (CLIENT_KEYS_UNAUTHORIZED,
  # CLIENT_DISABLED), or an apiKey was rejected and could not be renewed --
  # either because it survived its one automatic retry, or because the client
  # was built with a static api_key: and has no credentials to renew with.
  class AuthenticationError < Error; end

  # A 403 that carries a codeDescription: the request authenticated fine but
  # was denied on the merits, e.g. BALANCE_CONSENT_ERROR when the institution
  # refuses to share a balance. Distinct from AuthenticationError because these
  # must never trigger a re-auth or a retry.
  class PermissionError < Error; end

  class InvalidRequestError < Error
    ParameterError = Struct.new(:parameter, :code, :message)

    # POST /items 400 declares `errors: ParameterValidationError[]` in the
    # schema but every example in the spec emits `details` instead. Read both.
    def parameter_errors
      raw = json_body&.values_at("errors", "details")&.compact&.first || []
      raw.filter_map do |e|
        next unless e.is_a?(Hash)

        ParameterError.new(e["parameter"], e["code"], e["message"])
      end
    end

    # GET /v2/transactions rejects a malformed `after` cursor with a 400.
    def invalid_cursor?
      code_description == "invalidCursor" || message.to_s.downcase.include?("cursor")
    end
  end

  class NotFoundError < Error; end

  class ConflictError < Error
    # The ITEM_USER_ALREADY_EXISTS response carries the ids of the items that
    # already exist for this clientUserId (and omits `code` entirely).
    def duplicate_item_ids
      json_body&.fetch("items", nil) || []
    end
  end

  class RateLimitError < Error
    # Undocumented in the spec, so read it opportunistically and never depend
    # on it. GET /accounts/{id}/balance is the endpoint that documents a 429,
    # and that limit belongs to the financial institution, not to Pluggy.
    def retry_after
      value = http_headers["retry-after"]
      value&.to_i
    end
  end

  # 500
  class APIError < Error; end

  # 502 -- the financial institution is temporarily unavailable.
  class BadGatewayError < Error; end

  ERROR_CLASSES = {
    400 => InvalidRequestError,
    401 => AuthenticationError,
    403 => PermissionError,
    404 => NotFoundError,
    409 => ConflictError,
    429 => RateLimitError,
    500 => APIError,
    502 => BadGatewayError
  }.freeze

  # By the time this is consulted the requestor has already resolved the
  # expired-apiKey case, so a surviving 403 really is a permission problem.
  def self.error_class_for(status)
    ERROR_CLASSES.fetch(status) do
      status >= 500 ? APIError : Error
    end
  end
end
