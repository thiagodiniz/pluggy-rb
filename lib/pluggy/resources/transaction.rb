# frozen_string_literal: true

module Pluggy
  module Resources
    # A CPF or CNPJ, already formatted by Pluggy ("416.799.495-00").
    class Document < APIResource
      fields :type, :value

      def cpf? = self["type"] == "CPF"
      def cnpj? = self["type"] == "CNPJ"
    end

    class PaymentParticipant < APIResource
      fields :name, :accountNumber, :branchNumber, :routingNumber, :routingNumberISPB
      nested documentNumber: Document
    end

    class BoletoMetadata < APIResource
      fields :digitableLine, :barcode, :baseAmount, :interestAmount,
        :penaltyAmount, :discountAmount
    end

    # Present for transfers and bill payments. `paymentMethod` is PIX, TED, DOC,
    # TEV or BOLETO -- described in prose but declared as a free string, so it is
    # never validated here.
    class PaymentData < APIResource
      fields :reason, :referenceNumber, :receiverReferenceId,
        :authenticationCode, :paymentMethod
      nested payer: PaymentParticipant,
        receiver: PaymentParticipant,
        boletoMetadata: BoletoMetadata
    end

    class CreditCardMetadata < APIResource
      fields :installmentNumber, :totalInstallments, :totalAmount, :feeType,
        :feeTypeAdditionalInfo, :otherCreditsType, :otherCreditsAdditionalInfo,
        :purchaseDate, :payeeMCC, :cardNumber, :billId, :billForecastDate

      def fee? = !self["feeType"].nil?
      def installment? = self["totalInstallments"].to_i > 1
    end

    class Transaction < APIResource
      fields :id, :description, :descriptionRaw, :currencyCode, :amount,
        :amountInAccountCurrency, :date, :type, :balance, :providerCode,
        :status, :category, :categoryId, :operationType,
        :operationTypeAdditionalInfo, :providerId, :accountId, :order,
        :createdAt, :updatedAt
      nested paymentData: PaymentData,
        creditCardMetadata: CreditCardMetadata,
        merchant: Merchant

      # Direction, from the account holder's point of view. Pluggy normalizes
      # the credit-card convention, so a card purchase is always DEBIT and a
      # payment towards the statement is always CREDIT.
      def debit? = self["type"] == "DEBIT"
      def credit? = self["type"] == "CREDIT"
      alias outflow? debit?
      alias inflow? credit?

      def posted? = self["status"] == "POSTED"

      # Typical of card purchases not yet on a closed bill.
      def pending? = self["status"] == "PENDING"

      def credit_card? = !self["creditCardMetadata"].nil?

      def installment? = credit_card_metadata&.installment? || false

      def installment_label
        return nil unless installment?

        "#{credit_card_metadata["installmentNumber"]}/#{credit_card_metadata["totalInstallments"]}"
      end

      # The bill this transaction belongs to. Since GET /v2/transactions dropped
      # the billId filter, this is the authoritative way to group card
      # transactions into statements.
      def bill_id = credit_card_metadata&.[]("billId")

      def bill
        id = bill_id
        id && ensure_client!.bills.retrieve(id)
      end

      def payment_method = payment_data&.[]("paymentMethod")
      def pix? = payment_method == "PIX"
      def boleto? = payment_method == "BOLETO"
      def transfer? = %w[TED DOC TEV].include?(payment_method)

      # Whoever was on the other side: the receiver of an outflow, the payer of
      # an inflow.
      def counterparty
        data = payment_data
        return nil unless data

        debit? ? data.receiver : data.payer
      end

      def account = ensure_client!.accounts.retrieve(self["accountId"])

      # PATCH /transactions/{id} -- the only field Pluggy lets you change.
      def recategorize(category_id)
        ensure_client!.transactions.update(self["id"], category_id: category_id)
      end
    end
  end
end
