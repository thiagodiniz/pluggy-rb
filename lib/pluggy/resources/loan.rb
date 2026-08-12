# frozen_string_literal: true

module Pluggy
  module Resources
    # Every enum below is left as a raw String on purpose.
    #
    # The spec declares these in English (EFFECTIVE, SIMPLE, MONTHLY, UNIQUE,
    # MINIMUM) but the live API returns the Open Finance Brasil Portuguese
    # values (EFETIVA, SIMPLES, AA, UNICA, MINIMO). Modelling them as closed
    # constants would reject real data.
    class LoanInterestRate < APIResource
      fields :taxType, :interestRateType, :taxPeriodicity, :calculation,
        :referentialRateIndexerType, :referentialRateIndexerSubType,
        :referentialRateIndexerAdditionalInfo, :preFixedRate,
        :postFixedRate, :additionalInfo
    end

    class LoanContractedFee < APIResource
      fields :name, :code, :chargeType, :charge, :amount, :rate
    end

    class LoanContractedFinanceCharge < APIResource
      # The schema declares `additionalInfo`/`rate`, but the spec's own examples
      # emit `chargeAdditionalInfo`/`chargeRate`. Declare both spellings and let
      # whichever the API omits return nil.
      fields :type, :additionalInfo, :rate, :chargeAdditionalInfo, :chargeRate

      def info = self["additionalInfo"] || self["chargeAdditionalInfo"]
      def charge_rate = self["rate"] || self["chargeRate"]
    end

    class LoanWarranty < APIResource
      fields :currencyCode, :type, :subtype, :amount
    end

    class LoanBalloonPayment < APIResource
      fields :dueDate, :amount
    end

    class LoanInstallments < APIResource
      fields :typeNumberOfInstallments, :totalNumberOfInstallments,
        :typeContractRemaining, :contractRemainingNumber,
        :paidInstallments, :dueInstallments, :pastDueInstallments
      nested balloonPayments: LoanBalloonPayment

      def overdue? = self["pastDueInstallments"].to_i.positive?
    end

    class LoanPaymentRelease < APIResource
      fields :isOverParcelPayment, :installmentId, :paidDate, :currencyCode,
        :paidAmount, :overParcel
    end

    class LoanPayments < APIResource
      fields :contractOutstandingBalance
      nested releases: LoanPaymentRelease
    end

    class Loan < APIResource
      # `CET` (Custo Efetivo Total) is the only non-lowercase-first property in
      # the whole spec. It is passed as a String literal here, and the snake_case
      # conversion turns it into a plain `#cet` reader -- `loan.CET` and
      # `loan["CET"]` work too.
      fields :id, :itemId, :contractNumber, :ipocCode, :productName, :type, :kind,
        :date, :contractDate, :disbursementDates, :settlementDate,
        :contractAmount, :currencyCode, :dueDate, :installmentPeriodicity,
        :installmentPeriodicityAdditionalInfo, :firstInstallmentDueDate,
        "CET", :amortizationScheduled, :amortizationScheduledAdditionalInfo,
        :cnpjConsignee
      nested interestRates: LoanInterestRate,
        contractedFees: LoanContractedFee,
        contractedFinanceCharges: LoanContractedFinanceCharge,
        warranties: LoanWarranty,
        installments: LoanInstallments,
        payments: LoanPayments

      def loan? = self["kind"] == "LOAN"
      def financing? = self["kind"] == "FINANCING"
      def overdraft? = self["kind"] == "UNARRANGED_ACCOUNT_OVERDRAFT"

      def outstanding_balance = payments&.[]("contractOutstandingBalance")
      def overdue? = installments&.overdue? || false

      # Loans hang off an item, not an account.
      def item = ensure_client!.items.retrieve(self["itemId"])
    end
  end
end
