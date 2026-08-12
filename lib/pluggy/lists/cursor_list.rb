# frozen_string_literal: true

require "uri"

module Pluggy
  module Lists
    # The {results, next} envelope -- GET /v2/transactions only, the single
    # cursor-paginated endpoint in the entire API.
    #
    # `next` is a ready-to-use query string including the leading "?" and every
    # filter, e.g. "?accountId=562b...&after=MjAyMC0x...==", or null when
    # exhausted. We append it VERBATIM and never parse it back apart:
    #
    #   1. The spec says to. It also says that building the request manually
    #      requires the URL-*decoded* `after` value -- and Ruby cannot decode it
    #      losslessly, because URI.decode_www_form and CGI.parse both turn a "+"
    #      into a space. (In practice Pluggy's date|uuid cursors don't seem to
    #      produce a "+", but there is no reason to stand near that.)
    #   2. The server has already baked every filter into the string, so
    #      appending it makes filter propagation correct by construction -- our
    #      `filters` hash cannot drift from the server's notion of the query.
    class CursorList < BaseList
      # The resume token. Persist THIS -- the whole "?..." string -- not a
      # parsed cursor. See TransactionService#resume.
      def next_query = @raw.is_a?(Hash) ? @raw["next"] : nil
      alias next_token next_query

      def more?
        query = next_query
        !query.nil? && !query.empty?
      end

      def next_page
        return nil unless more?

        query = next_query
        unless query.start_with?("?")
          raise Error, "malformed pagination cursor from Pluggy (expected a leading '?'): #{query.inspect}"
        end

        @requestor.list_raw("#{@path}#{query}", klass: @klass, client: @client)
      end

      # The bare `after` value, for logging and debugging only. Never used to
      # build a request -- see the class comment.
      def next_cursor
        return nil unless more?

        encoded = next_query.delete_prefix("?")
                            .split("&")
                            .find { |pair| pair.start_with?("after=") }
                            &.delete_prefix("after=")
        encoded && URI.decode_www_form_component(encoded)
      end
    end
  end
end
