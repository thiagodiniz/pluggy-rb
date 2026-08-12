# frozen_string_literal: true

module Pluggy
  module Resources
    class CredentialOption < APIResource
      fields :value, :label
    end

    # One input the Connect Widget (or POST /items) must supply. `name` is the
    # key to send in the `parameters` map.
    class ConnectorCredential < APIResource
      fields :name, :label, :type, :assistiveText, :data, :placeholder,
        :validation, :validationMessage, :mfa
      nested options: CredentialOption

      def mfa? = self["mfa"] == true
      def select? = self["type"] == "select"
      def image? = self["type"] == "image"
      def password? = self["type"] == "password"

      def valid?(value)
        pattern = self["validation"]
        return true if pattern.nil? || pattern.empty?

        Regexp.new(pattern).match?(value.to_s)
      rescue RegexpError
        true
      end
    end

    class ConnectorHealthDetails < APIResource
      fields :connectionRateLast6Hours, :connectionsLast6Hours
    end

    # Only populated when the request passed healthDetails: true, and may itself
    # be null. `status` is documented in prose as ONLINE/OFFLINE/UNSTABLE but
    # declared as a free string.
    class ConnectorHealth < APIResource
      fields :status, :stage
      nested details: ConnectorHealthDetails

      def online? = self["status"] == "ONLINE"
      def offline? = self["status"] == "OFFLINE"
      def unstable? = self["status"] == "UNSTABLE"
    end

    class Connector < APIResource
      # Note `id` is a NUMBER here, not a UUID like every other resource.
      fields :id, :name, :institutionUrl, :imageUrl, :primaryColor, :type,
        :country, :hasMFA, :products, :oauth, :oauthUrl, :resetPasswordUrl,
        :isOpenFinance, :supportsPaymentInitiation, :supportsScheduledPayments,
        :supportsSmartTransfers, :supportsBoletoManagement,
        :supportsAutomaticPix, :createdAt, :updatedAt
      # In the spec's examples but not its schema.
      fields :isSandbox
      nested credentials: ConnectorCredential, health: ConnectorHealth

      def mfa? = self["hasMFA"] == true
      def oauth? = self["oauth"] == true
      def sandbox? = self["isSandbox"] == true
      def open_finance? = self["isOpenFinance"] == true

      def supports?(product)
        (self["products"] || []).include?(product.to_s.upcase)
      end

      def credential_names = (credentials || []).map { |c| c["name"] }
    end
  end
end
