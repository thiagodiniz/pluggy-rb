# frozen_string_literal: true

require_relative "lists/base_list"
require_relative "lists/offset_list"
require_relative "lists/cursor_list"
require_relative "lists/array_list"

module Pluggy
  module Lists
    # Pick a list type by looking at the payload rather than by trusting the
    # endpoint's declared schema.
    #
    # This is deliberate: GET /categories declares a bare array but its own
    # example is an offset envelope, so any per-endpoint assumption is a coin
    # flip against the live API. Sniffing costs one hash lookup and makes every
    # list endpoint present the same interface.
    def self.wrap(payload, klass:, requestor:, path:, filters: {}, client: nil, paginated: false)
      common = { klass: klass, requestor: requestor, path: path, filters: filters, client: client }

      case payload
      when Array
        ArrayList.new(payload, **common)
      when Hash
        if payload.key?("next")
          CursorList.new(payload, **common)
        elsif payload.key?("results")
          OffsetList.new(payload, paginated: paginated, **common)
        else
          raise Error, "unrecognized list envelope from #{path} (keys: #{payload.keys.inspect})"
        end
      else
        raise Error, "expected an array or object from #{path}, got #{payload.class}"
      end
    end
  end
end
