# frozen_string_literal: true

module Pluggy
  module Lists
    # Shared iteration for all three of Pluggy's pagination shapes. Subclasses
    # differ only in `more?` and `next_page`.
    class BaseList
      include Enumerable

      attr_reader :results, :filters, :path, :raw

      def initialize(payload, klass:, requestor:, path:, filters: {}, client: nil)
        @raw = payload
        @klass = klass
        @requestor = requestor
        @path = path
        @filters = filters || {}
        @client = client
        @results = extract(payload).map { |item| build(item) }
      end

      def each(&) = @results.each(&)
      def empty? = @results.empty?
      def length = @results.length
      alias size length
      alias count length

      def more? = false
      def next_page = nil

      # Walks every page. Returns an Enumerator when called without a block, so
      # `.lazy`, `.first(n)` and `.to_a` all work and only fetch the pages they
      # actually need.
      def auto_paging_each(&block)
        return enum_for(:auto_paging_each) unless block_given?

        page = self
        loop do
          page.each(&block)
          break unless page.more?

          page = page.next_page
          break if page.nil? || page.empty?
        end
        self
      end

      # Every page, eagerly. Convenient, but unbounded -- prefer
      # auto_paging_each for large histories.
      def auto_paging_to_a = auto_paging_each.to_a

      def inspect
        "#<#{self.class.name} results=#{@results.length} more=#{more?}>"
      end

      private

      def extract(payload)
        return payload if payload.is_a?(Array)

        payload["results"] || []
      end

      def build(item)
        item.is_a?(Hash) ? @klass.new(item, client: @client) : item
      end
    end
  end
end
