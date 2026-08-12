# frozen_string_literal: true

module Pluggy
  module Services
    class TransactionService < BaseService
      V2_PATH = "/v2/transactions"
      V1_PATH = "/transactions"

      # Filters that only exist on the deprecated v1 endpoint. Passing any of
      # them routes there automatically.
      V1_ONLY_PARAMS = %i[bill_id page page_size].freeze

      # List an account's transactions.
      #
      # Defaults to GET /v2/transactions (cursor-paginated, current). Routes to
      # the deprecated GET /transactions when a v1-only filter is given, or when
      # version: :v1 is explicit.
      #
      # v2 filters: date_from, date_to, created_at_from, ids, after
      # v1 filters: from, to, created_at_from, ids, bill_id, page, page_size
      def list(account_id:, version: nil, **filters)
        require_args!(account_id: account_id)

        resolved = version || implied_version(filters)
        resolved == :v1 ? list_v1(account_id, **filters) : list_v2(account_id, **filters)
      end

      # Resume cursor pagination from a persisted CursorList#next_token.
      #
      # The token is the whole "?..." query string the API handed back, filters
      # included -- not a bare `after` value. See Lists::CursorList.
      def resume(next_token)
        token = next_token.to_s
        unless token.start_with?("?")
          raise ArgumentError,
            "expected a cursor token starting with '?' (use CursorList#next_token), got #{token.inspect}"
        end

        @requestor.list_raw("#{V2_PATH}#{token}", klass: Resources::Transaction, client: @client)
      end

      def retrieve(id)
        require_args!(id: id)
        object_request(:get, "#{V1_PATH}/#{id}", klass: Resources::Transaction)
      end

      # PATCH /transactions/{id}. Recategorizing is the only supported edit.
      def update(id, category_id:)
        require_args!(id: id, category_id: category_id)
        object_request(:patch, "#{V1_PATH}/#{id}",
          klass: Resources::Transaction,
          body: { category_id: category_id })
      end

      private

      def implied_version(filters)
        return :v1 if V1_ONLY_PARAMS.any? { |p| filters.key?(p) }

        config.transactions_api_version
      end

      def list_v2(account_id, date_from: nil, date_to: nil, created_at_from: nil,
        ids: nil, after: nil, **rest)
        reject_unknown!(rest, V2_PATH)

        # The API returns a 400 for this combination; catching it locally saves
        # a round-trip and gives a clearer message.
        if date_from && created_at_from
          raise ArgumentError,
            "date_from cannot be combined with created_at_from on #{V2_PATH} " \
            "(the API rejects it with a 400); use one or the other"
        end

        check_ids!(ids)

        list_request(V2_PATH,
          klass: Resources::Transaction,
          accountId: account_id,
          dateFrom: date_from,
          dateTo: date_to,
          createdAtFrom: created_at_from,
          ids: ids,
          after: after)
      end

      def list_v1(account_id, from: nil, to: nil, created_at_from: nil, ids: nil,
        bill_id: nil, page: nil, page_size: nil, date_from: nil, date_to: nil, **rest)
        reject_unknown!(rest, V1_PATH)
        check_ids!(ids)

        config.log(:info,
          "using deprecated GET /transactions (sunset 2026-12-31)",
          reason: bill_id ? "billId filter is v1-only" : "requested")

        size = page_size || Lists::OffsetList::DEFAULT_PAGE_SIZE
        if size > Lists::OffsetList::MAX_PAGE_SIZE
          raise ArgumentError, "page_size cannot exceed #{Lists::OffsetList::MAX_PAGE_SIZE}"
        end

        list_request(V1_PATH,
          klass: Resources::Transaction,
          paginated: true,
          accountId: account_id,
          # v2 renamed these; accept either spelling here.
          from: from || date_from,
          to: to || date_to,
          createdAtFrom: created_at_from,
          ids: ids,
          billId: bill_id,
          page: page || 1,
          pageSize: size)
      end

      def check_ids!(ids)
        return if ids.nil? || ids.length <= 500

        raise ArgumentError, "at most 500 ids per request (got #{ids.length})"
      end

      def reject_unknown!(rest, path)
        return if rest.empty?

        raise ArgumentError, "unknown filter#{"s" if rest.size > 1} for #{path}: #{rest.keys.join(", ")}"
      end
    end
  end
end
