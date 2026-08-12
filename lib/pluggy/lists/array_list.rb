# frozen_string_literal: true

module Pluggy
  module Lists
    # A bare JSON array with no envelope at all.
    #
    # GET /categories declares `{type: array}` in its schema while its own
    # `example` shows an offset envelope -- the spec contradicts itself. The
    # shape sniffer in Pluggy::Lists.wrap resolves it at runtime, so a caller
    # gets a working list either way and never has to care which shipped.
    class ArrayList < BaseList
      def initialize(payload, klass:, requestor:, path: nil, filters: {}, client: nil)
        super
      end

      def more? = false
      def next_page = nil

      # Lets an ArrayList be splatted or passed to Array().
      def to_ary = @results
    end
  end
end
