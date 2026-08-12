# frozen_string_literal: true

module Pluggy
  module Lists
    # The {results, page, total, totalPages} envelope.
    #
    # Used by /accounts, /bills, /loans, /connectors, /accounts/{id}/statements
    # and /transactions (v1) -- but only /transactions and /connectors actually
    # accept `page`/`pageSize`. The rest return a paged envelope with no
    # documented way to ask for page 2, so services pass `paginated: false` and
    # `more?` stays false. auto_paging_each then yields the single page and
    # stops, rather than issuing a request that would return the same rows.
    class OffsetList < BaseList
      # Prose-only default in the spec (no JSON-Schema `default` exists
      # anywhere), so the SDK has to supply it.
      DEFAULT_PAGE_SIZE = 500
      MAX_PAGE_SIZE = 500

      def initialize(payload, paginated: false, **kwargs)
        @paginated = paginated
        super(payload, **kwargs)
      end

      def page = @raw.is_a?(Hash) ? (@raw["page"]&.to_i || 1) : 1
      def total = @raw.is_a?(Hash) ? @raw["total"]&.to_i : nil
      def total_pages = @raw.is_a?(Hash) ? (@raw["totalPages"]&.to_i || 1) : 1
      def paginated? = @paginated

      def more?
        @paginated && !empty? && page < total_pages
      end

      def next_page
        return nil unless more?

        @requestor.list(
          @path,
          params: @filters.merge(page: page + 1),
          klass: @klass,
          client: @client,
          paginated: true
        )
      end
    end
  end
end
