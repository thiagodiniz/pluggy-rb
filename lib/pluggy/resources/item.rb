# frozen_string_literal: true

module Pluggy
  module Resources
    class StatusDetailWarning < APIResource
      fields :code, :message, :providerMessage
    end

    class StatusDetailProduct < APIResource
      fields :lastUpdatedAt, :isUpdated
      nested warnings: StatusDetailWarning

      def updated? = self["isUpdated"] == true
    end

    # Per-product sync state. Useful for answering "are the transactions ready
    # yet?" without polling the whole item.
    class StatusDetail < APIResource
      PRODUCTS = %w[
        accounts creditCards transactions investments identity
        investmentsTransactions paymentData loans accountStatements
      ].freeze

      nested(PRODUCTS.to_h { |p| [p, StatusDetailProduct] })

      def updated?(product)
        self[Util.camel_case(product)]&.updated? || false
      end

      def warnings
        PRODUCTS.flat_map { |p| self[p]&.warnings || [] }
      end
    end

    class ItemError < APIResource
      fields :code, :message, :providerMessage, :attributes
    end

    # What the user must do next: an MFA code, a device authorization, an OAuth
    # redirect.
    class UserAction < APIResource
      fields :instructions, :attributes, :expiresAt
    end

    # A connection to one financial institution.
    #
    # There is no GET /items endpoint -- items cannot be listed. Persist the ids
    # you create, normally keyed by your own clientUserId.
    class Item < APIResource
      fields :id, :status, :executionStatus, :webhookUrl, :createdAt, :updatedAt,
        :lastUpdatedAt, :nextAutoSyncAt, :consecutiveFailedLoginAttempts,
        :consentExpiresAt, :products
      # In the spec's examples but not its schema.
      fields :clientUserId, :oauthRedirectUri
      nested connector: Connector,
        parameter: ConnectorCredential,
        userAction: UserAction,
        statusDetail: StatusDetail,
        error: ItemError

      # `status` and `executionStatus` are unconstrained strings in the spec --
      # no enum is declared anywhere and the documented values appear only in
      # examples. These predicates compare raw strings and never assume the set
      # is closed.
      def updated? = self["status"] == "UPDATED"
      def updating? = self["status"] == "UPDATING"
      def login_error? = self["status"] == "LOGIN_ERROR"
      def outdated? = self["status"] == "OUTDATED"
      def waiting_user_input? = self["status"] == "WAITING_USER_INPUT" || !self["userAction"].nil?
      alias mfa_required? waiting_user_input?

      def failed? = !self["error"].nil? || self["executionStatus"].to_s.include?("ERROR")
      def succeeded? = self["executionStatus"] == "SUCCESS"

      def consent_expired?
        expiry = self[:consentExpiresAt]
        expiry.is_a?(Time) && expiry <= Time.now
      end

      def accounts(type: nil) = ensure_client!.accounts.list(item_id: self["id"], type: type)
      def bank_accounts = accounts(type: "BANK")
      def credit_accounts = accounts(type: "CREDIT")
      def loans = ensure_client!.loans.list(item_id: self["id"])

      # Every transaction on every account of this item, as one lazy stream.
      def transactions(**filters, &block)
        return enum_for(:transactions, **filters) unless block_given?

        accounts.each do |account|
          account.transactions(**filters).auto_paging_each(&block)
        end
      end

      def send_mfa(values) = ensure_client!.items.send_mfa(self["id"], values)
      def disable_auto_sync = ensure_client!.items.disable_auto_sync(self["id"])
      def sync(**body) = ensure_client!.items.update(self["id"], **body)
      def delete = ensure_client!.items.delete(self["id"])
      def refresh = ensure_client!.items.retrieve(self["id"])
    end
  end
end
