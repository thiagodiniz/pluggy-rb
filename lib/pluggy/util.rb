# frozen_string_literal: true

require "set"
require "uri"
require "time"
require "date"

module Pluggy
  # Naming conversion and request encoding.
  #
  # Pluggy speaks camelCase; Ruby speaks snake_case. Two conversions run in
  # opposite directions: responses are read through snake_case accessors
  # (see PluggyObject), and request params are written from snake_case kwargs
  # into camelCase wire keys.
  #
  # The conversion is deliberately NOT round-tripped: camel_case(snake_case(x))
  # is lossy for acronym-bearing keys ("issuerCNPJ" -> :issuer_cnpj ->
  # "issuerCnpj"). That is fine because only *outgoing* params are camelized,
  # and those are an explicit per-service allowlist rather than something we
  # derive from a response.
  module Util
    # "issuerCNPJName" -> "issuerCNPJ_Name"
    ACRONYM_BOUNDARY = /([A-Z\d]+)([A-Z][a-z])/
    # "createdAt" -> "created_At"
    LOWER_UPPER = /([a-z\d])([A-Z])/

    # Comma-joined in the query string. `countries` and `types` are
    # `style: form, explode: false` in the spec; `cnpjs` is typed as a bare
    # comma-separated string. Everything else (notably `ids`) repeats the key.
    COMMA_JOINED_PARAMS = %w[countries types cnpjs].freeze

    # The spec types these as `format: date-time` but every description says
    # "Format (yyyy-mm-dd)". The descriptions win — see plan §7.
    DATE_ONLY_PARAMS = %w[from to dateFrom dateTo].freeze

    # ...and this one really does want the full timestamp.
    DATETIME_PARAMS = %w[createdAtFrom].freeze

    DATETIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%LZ"

    @snake_cache = {}
    @camel_cache = {}

    class << self
      # "createdAt" => "created_at", "CET" => "cet", "hasMFA" => "has_mfa",
      # "issuerCNPJ" => "issuer_cnpj", "payeeMCC" => "payee_mcc"
      def snake_case(key)
        k = key.to_s
        @snake_cache[k] ||= k.gsub(ACRONYM_BOUNDARY, '\1_\2')
                             .gsub(LOWER_UPPER, '\1_\2')
                             .tr("-", "_")
                             .downcase
      end

      # :item_id => "itemId", :oauth_redirect_uri => "oauthRedirectUri"
      def camel_case(key)
        k = key.to_s
        return k unless k.include?("_")

        @camel_cache[k] ||= begin
          head, *rest = k.split("_")
          head + rest.map(&:capitalize).join
        end
      end

      # Symbol keys are snake_case and get camelized. String keys pass through
      # verbatim -- the escape hatch for any key our camelizer would mangle.
      def wire_key(key)
        key.is_a?(String) ? key : camel_case(key)
      end

      def encode_query(params)
        pairs = []

        (params || {}).each do |key, value|
          next if value.nil?

          wire = wire_key(key)

          case value
          when Array
            next if value.empty?

            if COMMA_JOINED_PARAMS.include?(wire)
              pairs << [wire, value.map { |e| format_param(wire, e) }.join(",")]
            else
              value.each { |e| pairs << [wire, format_param(wire, e)] }
            end
          when Hash
            raise ArgumentError, "nested hash is not encodable in a query string: #{wire}"
          else
            pairs << [wire, format_param(wire, value)]
          end
        end

        URI.encode_www_form(pairs)
      end

      # Per-parameter date formatting (see DATE_ONLY_PARAMS / DATETIME_PARAMS).
      def format_param(wire, value)
        if DATE_ONLY_PARAMS.include?(wire)
          to_date_string(value)
        elsif DATETIME_PARAMS.include?(wire)
          to_datetime_string(value)
        else
          value.to_s
        end
      end

      def to_date_string(value)
        case value
        when Date then value.iso8601
        when Time then value.to_date.iso8601
        else
          # Tolerate a caller passing a full timestamp for a date-only param.
          value.to_s[0, 10]
        end
      end

      def to_datetime_string(value)
        case value
        when Time then value.utc.strftime(DATETIME_FORMAT)
        when DateTime then value.to_time.utc.strftime(DATETIME_FORMAT)
        when Date then Time.utc(value.year, value.month, value.day).strftime(DATETIME_FORMAT)
        else value.to_s
        end
      end

      # Deep snake_case -> camelCase for request bodies.
      #
      # `opaque` names keys whose *contents* must not be touched. POST /items
      # {parameters} and POST /items/{id}/mfa are free-form {String => String}
      # maps whose keys are connector-defined ("user", "cpf", "cpf_cnpj"), so
      # camelizing them would silently break item creation.
      def encode_body(hash, opaque: [])
        (hash || {}).each_with_object({}) do |(key, value), out|
          next if value.nil?

          wire = wire_key(key)
          out[wire] =
            if opaque.include?(wire)
              stringify_keys(value)
            else
              encode_body_value(value, opaque)
            end
        end
      end

      def encode_body_value(value, opaque)
        case value
        when Hash then encode_body(value, opaque: opaque)
        when Array then value.map { |e| e.is_a?(Hash) ? encode_body(e, opaque: opaque) : e }
        else value
        end
      end

      # Shallow String-ify of a free-form map's keys, leaving them otherwise
      # untouched.
      def stringify_keys(value)
        return value unless value.is_a?(Hash)

        value.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end
    end
  end
end
