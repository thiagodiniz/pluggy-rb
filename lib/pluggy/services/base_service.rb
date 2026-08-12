# frozen_string_literal: true

module Pluggy
  module Services
    class BaseService
      def initialize(client)
        @client = client
        @requestor = client.requestor
      end

      private

      def list_request(path, klass:, paginated: false, **params)
        @requestor.list(path, params: params, klass: klass, client: @client, paginated: paginated)
      end

      def object_request(method, path, klass:, body: nil, opaque: [], **params)
        payload = @requestor.request(
          method, path,
          params: params.empty? ? nil : params,
          body: body,
          opaque_body_keys: opaque
        )
        klass.new(payload, client: @client)
      end

      # Several endpoints take a required query param on an operation that
      # documents only a 200 (/accounts and /loans need itemId; /bills and
      # /transactions need accountId). Failing here with a clear message beats
      # a confusing empty result or a 500.
      def require_args!(**args)
        missing = args.select { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }.keys
        return if missing.empty?

        name = self.class.name.split("::").last
        raise ArgumentError, "#{name}: #{missing.join(", ")} #{missing.one? ? "is" : "are"} required"
      end

      def config = @client.config
    end
  end
end
