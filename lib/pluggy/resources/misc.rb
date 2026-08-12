# frozen_string_literal: true

module Pluggy
  module Resources
    # POST /connect_token. Valid for 30 minutes and meant for the Connect
    # Widget in your frontend -- it is NOT an apiKey and cannot authenticate
    # API calls.
    class ConnectToken < APIResource
      fields :accessToken
    end

    # GET /accounts/{id}/balance -- read live from the institution rather than
    # from the last sync.
    class Balance < APIResource
      fields :balance, :currencyCode, :updateDateTime
    end

    # GET /accounts/{id}/statements. The url is a signed link valid for 30
    # minutes. `monthYear` is "2024-03", which is why it is deliberately not
    # coerced to a Date.
    class Statement < APIResource
      fields :id, :monthYear, :url
    end

    # DELETE /items/{id} returns {count}. This is why PluggyObject does not
    # include Enumerable: #count would otherwise be shadowed.
    class Count < APIResource
      fields :count
    end

    # A transaction category. Two-level hierarchy: a category with no parentId
    # is a root.
    class Category < APIResource
      fields :id, :description, :descriptionTranslated, :parentId, :parentDescription

      def root? = self["parentId"].nil?

      def children
        ensure_client!.categories.list(parent_id: self["id"])
      end

      def parent
        parent_id = self["parentId"]
        parent_id && ensure_client!.categories.retrieve(parent_id)
      end
    end
  end
end
