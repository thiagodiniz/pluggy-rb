# frozen_string_literal: true

require "set"
require "json"
require "time"
require "date"

module Pluggy
  # Base value object wrapping an API JSON payload.
  #
  # The access contract, which is the one thing worth memorising:
  #
  #   txn.date      / txn[:date]     => Time      (coerced Ruby view)
  #   txn["date"]   / txn["createdAt"] => String  (verbatim wire value)
  #   txn.to_h                        => wire values, nested objects flattened
  #
  # Symbol keys and readers give you the coerced Ruby value; String keys read
  # the original payload and accept the original camelCase spelling.
  #
  # Fields are declared once per class with the `fields` DSL rather than
  # defined per instance (Stripe's approach), because a 500-transaction page
  # would otherwise mean ~11,500 define_method calls per response. Undeclared
  # keys are still kept and still reachable -- via method_missing and via []
  # -- so fields Pluggy adds after this gem ships are not lost.
  #
  # Deliberately does NOT include Enumerable: iterating a Transaction and
  # getting its own field values is a confusing API, and it would collide with
  # ICountResponse#count. Only the list objects are Enumerable.
  class PluggyObject
    # Overriding any of these would break the object itself.
    RESERVED = Set.new(%w[
                         class send __send__ public_send object_id __id__ method methods
                         respond_to? respond_to_missing? instance_variable_get instance_variable_set
                         instance_variables singleton_class is_a? kind_of? instance_of? nil? tap
                         then itself extend display equal? to_h to_hash to_s to_json as_json inspect
                         keys values each_pair [] == eql? hash dup clone freeze frozen? initialize
                         method_missing client read key?
                       ]).freeze

    # Time coercion is keyed on the wire field name, guarded by the value's
    # shape. A blanket ISO-8601 sniff would be dangerous -- a descriptionRaw
    # reading "2020-10-15" would silently become a Time.
    TEMPORAL_KEYS = Set.new(%w[
                              date createdAt updatedAt lastUpdatedAt nextAutoSyncAt consentExpiresAt
                              expiresAt dueDate billClosingDate contractDate settlementDate
                              firstInstallmentDueDate paymentDate purchaseDate balanceCloseDate
                              balanceDueDate updateDateTime issueDate expirationDate paidDate
                            ]).freeze

    # Anchored, and requires a full date. This is what keeps `monthYear` and
    # `billForecastDate` ("2024-03") as Strings, and `installmentPeriodicity`
    # ("MES") untouched.
    ISO8601 = /\A\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?\z/

    class << self
      # Wire field name => nested class, inherited by subclasses.
      def nested_types
        @nested_types ||= superclass.respond_to?(:nested_types) ? superclass.nested_types.dup : {}
      end

      def declared_fields
        @declared_fields ||=
          superclass.respond_to?(:declared_fields) ? superclass.declared_fields.dup : Set.new
      end

      # fields :id, :descriptionRaw, "CET"
      #
      # Pass wire names (camelCase or otherwise); readers are generated in
      # snake_case, with a camelCase alias so code transliterated from Pluggy's
      # own docs also works.
      def fields(*names)
        names.flatten.each { |n| define_field(n.to_s) }
      end

      # nested connector: Connector, financeCharges: BillFinanceCharge
      def nested(map)
        map.each do |wire, klass|
          nested_types[Util.wire_key(wire)] = klass
          define_field(Util.wire_key(wire))
        end
      end

      def define_field(wire)
        declared_fields << wire
        ruby = Util.snake_case(wire)

        # Genuinely unusable names ("2fa", "foo-bar") stay reachable via [].
        return unless ruby.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)
        return if RESERVED.include?(ruby)

        define_method(ruby) { read(wire) }

        # camelCase alias, e.g. loan.CET alongside loan.cet
        define_method(wire) { read(wire) } unless wire == ruby || RESERVED.include?(wire)
      end
    end

    attr_reader :client

    # Accepts the payload either braced or as a bare trailing hash. Ruby routes
    # an unbraced hash into **extra (String keys included), so
    # `Transaction.new("id" => "x")` and `Transaction.new({"id" => "x"})` and
    # `Transaction.new(payload, client: c)` all work.
    #
    # Keys are wire names -- "createdAt", not :created_at.
    def initialize(values = {}, client: nil, **extra)
      @client = client
      @values = {}
      @coerced = {}

      source = values.nil? || values.empty? ? extra : values.merge(extra)

      source.each do |key, value|
        k = key.to_s
        @values[k] = convert(k, value)
      end
    end

    # Coerced read, memoised. Used by every generated accessor.
    def read(wire)
      return @coerced[wire] if @coerced.key?(wire)

      raw = @values[wire]
      @coerced[wire] = TEMPORAL_KEYS.include?(wire) ? coerce_time(raw) : raw
    end

    # String key => verbatim wire value (accepts the camelCase spelling).
    # Symbol key => coerced value, same as the reader.
    def [](key)
      if key.is_a?(Symbol)
        wire = @values.key?(key.to_s) ? key.to_s : Util.camel_case(key)
        read(wire)
      else
        k = key.to_s
        @values.key?(k) ? @values[k] : @values[Util.camel_case(k)]
      end
    end

    def key?(key)
      k = key.to_s
      @values.key?(k) || @values.key?(Util.camel_case(k))
    end

    def keys = @values.keys
    def values = @values.values
    def each_pair(&) = @values.each_pair(&)

    # Wire-shaped hash: nested objects flattened back to plain hashes. Values
    # are the parsed ones (so amounts are BigDecimal), which is what `as_json`
    # then renders correctly.
    def to_h
      @values.transform_values { |v| unwrap(v) }
    end
    alias to_hash to_h

    # JSON.generate serialises a BigDecimal as a *quoted string*
    # ('{"amount":"-0.21245e3"}'), which would break round-tripping. Wrap them
    # so they render as unquoted numbers matching the original wire literal.
    def as_json(*)
      deep_render(to_h)
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    def ==(other)
      other.is_a?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash = to_h.hash

    def inspect
      id = @values["id"]
      "#<#{self.class.name}#{":#{id}" if id} #{@values.keys.join(" ")}>"
    end

    # Forward-compat path for fields Pluggy adds after this gem ships, and for
    # the undeclared-but-real ones (Bill#accountId, Item#clientUserId,
    # Connector#isSandbox).
    def method_missing(name, *args)
      n = name.to_s
      return super if n.end_with?("=", "!") || !args.empty?

      if n.end_with?("?")
        base = n.delete_suffix("?")
        wire = resolve_wire(base)
        return !read(wire).nil? && read(wire) != false if wire
      end

      wire = resolve_wire(n)
      return read(wire) if wire

      super
    end

    def respond_to_missing?(name, include_private = false)
      n = name.to_s.sub(/[?]\z/, "")
      !resolve_wire(n).nil? || super
    end

    private

    # Map a Ruby method name back onto a present wire key.
    def resolve_wire(name)
      return name if @values.key?(name)

      camel = Util.camel_case(name)
      return camel if @values.key?(camel)

      # Last resort: an acronym-bearing key our camelizer cannot reproduce
      # ("issuerCNPJ" from :issuer_cnpj).
      @values.keys.find { |k| Util.snake_case(k) == name }
    end

    def convert(wire, value)
      case value
      when Hash
        (self.class.nested_types[wire] || PluggyObject).new(value, client: @client)
      when Array
        item_class = self.class.nested_types[wire]
        value.map do |e|
          e.is_a?(Hash) ? (item_class || PluggyObject).new(e, client: @client) : e
        end
      else
        value
      end
    end

    # The client's own configuration when the object came from one, so
    # Client.new(coerce_times: false) is honoured; the global defaults
    # otherwise.
    def config = @client&.config || Pluggy.config

    def unwrap(value)
      case value
      when PluggyObject then value.to_h
      when Array then value.map { |e| unwrap(e) }
      else value
      end
    end

    def coerce_time(raw)
      return raw unless raw.is_a?(String)
      return raw unless config.coerce_times
      return raw unless raw.match?(ISO8601)

      # A bare "2024-03-15" is a Date; anything with a time part is a Time.
      raw.length == 10 ? Date.iso8601(raw) : Time.iso8601(raw)
    rescue ArgumentError, TypeError
      # Never raise on a malformed date -- too much of this spec disagrees
      # with the live API to be strict here.
      raw
    end

    def deep_render(value)
      case value
      when BigDecimal then RawNumber.new(value)
      when Hash then value.transform_values { |v| deep_render(v) }
      when Array then value.map { |v| deep_render(v) }
      else value
      end
    end

    # Renders a BigDecimal as an unquoted JSON number.
    class RawNumber
      def initialize(decimal)
        # "F" gives "-212.45" rather than "-0.21245e3".
        @literal = decimal.to_s("F")
        # Trim the trailing ".0" BigDecimal adds to integral values.
        @literal = @literal.sub(/\.0\z/, "")
      end

      def to_json(*) = @literal
      def to_s = @literal
    end
  end
end
