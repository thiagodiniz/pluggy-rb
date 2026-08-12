# frozen_string_literal: true

module Pluggy
  module Resources
    # The counterparty of a transaction, resolved from its CNPJ.
    class Merchant < APIResource
      fields :name, :businessName, :cnpj, :cnae
    end

    # GET /merchants returns neither a list envelope nor a bare array, but three
    # named buckets, so it gets its own type rather than being forced into the
    # list interface.
    class MerchantSearch < APIResource
      fields :notFoundMerchants, :invalidCnpjs
      nested foundMerchants: Merchant

      alias found found_merchants
      alias not_found not_found_merchants
      alias invalid invalid_cnpjs

      # Look up a resolved merchant by the CNPJ you asked for.
      def [](key)
        return super if key.is_a?(Symbol) || !key.to_s.match?(/\A\d{14}\z/)

        (found_merchants || []).find { |m| m["cnpj"] == key.to_s }
      end

      def to_h_by_cnpj
        (found_merchants || []).to_h { |m| [m["cnpj"], m] }
      end
    end
  end
end
