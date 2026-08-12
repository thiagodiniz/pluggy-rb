# frozen_string_literal: true

require "date"

module Pluggy
  module Resources
    class BillFinanceCharge < APIResource
      fields :id, :type, :amount, :currencyCode, :additionalInfo
      # `creditCardBillId` is in the schema's `required` list but absent from
      # its `properties` (spec bug); it is present at runtime.
      fields :creditCardBillId
    end

    class BillPayment < APIResource
      fields :id, :valueType, :paymentDate, :paymentMode, :amount, :currencyCode

      def full? = self["valueType"] == "FULL_PAYMENT"
      def installment? = self["valueType"] == "INSTALLMENT_PAYMENT"
    end

    # A credit-card statement.
    #
    # Bills carry no line items of their own -- see #transactions.
    class Bill < APIResource
      fields :id, :dueDate, :billClosingDate, :totalAmount,
        :totalAmountCurrencyCode, :minimumPaymentAmount, :allowsInstallments
      # Same spec bug as BillFinanceCharge#creditCardBillId: `accountId` is
      # required-but-undeclared, and present at runtime.
      fields :accountId
      nested financeCharges: BillFinanceCharge, payments: BillPayment

      # How far back to look when the previous cycle is unknown. Two months plus
      # slack, so a 31-day cycle plus a late closing date still fits.
      FALLBACK_WINDOW_DAYS = 62

      # Stamped by BillService#list, which sees the whole cycle sequence and can
      # therefore give #transactions an exact one-cycle window. Nil for a bill
      # fetched on its own via bills.retrieve.
      attr_accessor :previous_closing_date

      def paid?
        list = payments
        return false if list.nil? || list.empty?

        list.sum { |p| p["amount"] || 0 } >= (self["totalAmount"] || 0)
      end

      def finance_charges_total
        (finance_charges || []).sum { |c| c["amount"] || 0 }
      end

      def account = ensure_client!.accounts.retrieve(self["accountId"])

      # The bill's line items.
      #
      # GET /v2/transactions has no billId filter (v1 had one, but v1 is
      # deprecated with a 2026-12-31 sunset), so this lists the account's
      # transactions over the statement cycle and filters on
      # creditCardMetadata.billId.
      #
      # The billId check is authoritative and always runs, so the date window
      # only affects how many requests are made, never which transactions come
      # back -- a wrong window yields a slower answer, never a wrong one.
      #
      # Pass `strategy: :legacy` for a single server-side-filtered request
      # against the deprecated v1 endpoint.
      #
      # Returns an Enumerator rather than a list object, because the count is
      # only knowable after filtering. Nothing is requested until you iterate,
      # and `.map`/`.select` behave normally (returning Arrays) -- unlike a
      # lazy enumerator, which would surprise callers. Chain `.lazy` yourself
      # if you want lazy semantics downstream.
      #
      # With strategy: :legacy it returns a real list object instead, since the
      # server did the filtering.
      def transactions(strategy: :v2, date_from: nil, date_to: nil, **filters)
        # Validated up front rather than on first iteration: a missing client or
        # accountId is a programming error, and deferring it to somewhere deep in
        # an enumerator makes it much harder to place.
        ensure_client!
        require_account_id!

        if strategy == :legacy
          return @client.transactions.list(
            account_id: require_account_id!, bill_id: self["id"], **filters
          )
        end

        unless block_given?
          return enum_for(:transactions, strategy: strategy, date_from: date_from,
            date_to: date_to, **filters)
        end

        bill_id = self["id"]
        @client.transactions
               .list(account_id: require_account_id!,
                 date_from: date_from || window_start,
                 date_to: date_to || window_end,
                     **filters)
               .auto_paging_each { |t| yield t if t.bill_id == bill_id }
      end

      private

      def require_account_id!
        self["accountId"] || raise(
          Error,
          "bill #{self["id"]} has no accountId, so its transactions cannot be located; " \
          "fetch it via client.bills.list(account_id:)"
        )
      end

      # Exact when BillService#list supplied the previous cycle; otherwise a
      # deliberately generous fallback.
      def window_start
        if previous_closing_date
          date = to_date(previous_closing_date)
          return date + 1 if date
        end

        anchor = to_date(self["billClosingDate"] || self["dueDate"])
        return nil unless anchor

        @client&.config&.log(
          :info,
          "bill #{self["id"]}: previous cycle unknown, widening the transaction window",
          days: FALLBACK_WINDOW_DAYS
        )
        anchor - FALLBACK_WINDOW_DAYS
      end

      # Through the due date rather than the closing date: instalments and
      # late-posted items can land after the cycle closes.
      def window_end
        to_date(self["dueDate"] || self["billClosingDate"])
      end

      def to_date(value)
        case value
        when Date then value
        when Time then value.to_date
        when String then Date.parse(value)
        end
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
