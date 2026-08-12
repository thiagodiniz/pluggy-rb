# frozen_string_literal: true

module Pluggy
  module Resources
    class ReservedBalance < APIResource
      fields :name, :identification, :availableAmounts
    end

    # Populated when type == "BANK". Every field is nullable.
    class BankData < APIResource
      fields :transferNumber, :closingBalance, :automaticallyInvestedBalance,
        :overdraftContractedLimit, :overdraftUsedLimit,
        :unarrangedOverdraftAmount, :hasReservedBalance
      nested reservedBalances: ReservedBalance

      # "Cheque especial" -- how much of the arranged overdraft is in use.
      def overdraft_in_use? = self["overdraftUsedLimit"].to_f.positive?
    end

    class AdditionalCard < APIResource
      fields :number
    end

    class DisaggregatedCreditLimit < APIResource
      fields :creditLineLimitType, :consolidationType, :identificationNumber,
        :isLimitFlexible, :lineName, :lineNameAdditionalInfo, :limitAmount,
        :limitAmountCurrencyCode, :limitAmountReason, :customizedLimitAmount,
        :customizedLimitAmountCurrencyCode, :usedAmount,
        :usedAmountCurrencyCode, :availableAmount, :availableAmountCurrencyCode
    end

    # Populated when type == "CREDIT".
    class CreditData < APIResource
      fields :level, :brand, :brandAdditionalInfo, :balanceCloseDate,
        :balanceDueDate, :availableCreditLimit, :balanceForeignCurrency,
        :minimumPayment, :creditLimit, :isLimitFlexible, :status, :holderType
      nested disaggregatedCreditLimits: DisaggregatedCreditLimit,
        additionalCards: AdditionalCard

      def active? = self["status"] == "ACTIVE"
      def blocked? = self["status"] == "BLOCKED"
      def cancelled? = self["status"] == "CANCELLED"
      def main_holder? = self["holderType"] == "MAIN"
    end

    class Account < APIResource
      fields :id, :type, :subtype, :number, :name, :marketingName, :balance,
        :itemId, :taxNumber, :owner, :currencyCode, :createdAt, :updatedAt
      nested bankData: BankData, creditData: CreditData

      def bank? = self["type"] == "BANK"
      def credit? = self["type"] == "CREDIT"
      def credit_card? = self["subtype"] == "CREDIT_CARD"
      def checking? = self["subtype"] == "CHECKING_ACCOUNT"
      def savings? = self["subtype"] == "SAVINGS_ACCOUNT"

      def transactions(**filters)
        ensure_client!.transactions.list(account_id: self["id"], **filters)
      end

      # Credit-card statements. Only CREDIT accounts have them, so say so
      # clearly rather than returning a confusing empty list.
      def bills(**filters)
        unless credit?
          raise Error,
            "account #{self["id"]} has type #{self["type"].inspect}, not \"CREDIT\"; " \
            "bills exist only for credit-card accounts"
        end

        ensure_client!.bills.list(account_id: self["id"], **filters)
      end

      # GET /accounts/{id}/balance -- fetched live from the institution rather
      # than from the last sync, so it is slower and can 429 or 502.
      def live_balance = ensure_client!.accounts.balance(self["id"])

      def statements = ensure_client!.accounts.statements(self["id"])

      def item = ensure_client!.items.retrieve(self["itemId"])

      def refresh = ensure_client!.accounts.retrieve(self["id"])
    end
  end
end
