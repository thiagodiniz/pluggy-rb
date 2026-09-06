# frozen_string_literal: true

module Pluggy
  module Services
    class AccountService < BaseService
      # GET /accounts. `type` filters between "BANK" and "CREDIT".
      #
      # paginated: false -- the endpoint returns a page envelope but documents no
      # page/pageSize parameters, so there is no way to request page 2.
      def list(item_id:, type: nil)
        require_args!(item_id: item_id)
        list_request("/accounts", klass: Resources::Account, itemId: item_id, type: type)
      end

      def retrieve(id)
        require_args!(id: id)
        object_request(:get, "/accounts/#{id}", klass: Resources::Account)
      end

      # Live balance, read from the institution rather than the last sync. Slower
      # than Account#balance and the one endpoint in scope that documents a 429
      # (institution rate limit) and a 502 (institution unavailable).
      def balance(id)
        require_args!(id: id)
        object_request(:get, "/accounts/#{id}/balance", klass: Resources::Balance)
      end

      # Monthly statement documents. Each url is signed and valid 30 minutes.
      def statements(id)
        require_args!(id: id)
        list_request("/accounts/#{id}/statements", klass: Resources::Statement)
      end
    end

    class BillService < BaseService
      # GET /bills. Scoped to one credit-card account.
      def list(account_id:)
        require_args!(account_id: account_id)
        result = list_request("/bills", klass: Resources::Bill, accountId: account_id)
        annotate_cycles!(result)
        result
      end

      def retrieve(id)
        require_args!(id: id)
        object_request(:get, "/bills/#{id}", klass: Resources::Bill)
      end

      # Convenience mirroring Bill#transactions.
      def transactions(bill, **options)
        bill = retrieve(bill) unless bill.is_a?(Resources::Bill)
        bill.transactions(**options)
      end

      private

      # Chain each bill to its predecessor's closing date so Bill#transactions
      # can window on exactly one statement cycle instead of guessing.
      def annotate_cycles!(list)
        list.results
            .select { |b| b["billClosingDate"] }
            .sort_by { |b| b["billClosingDate"].to_s }
            .each_cons(2) { |prev, cur| cur.previous_closing_date = prev["billClosingDate"] }
      end
    end

    class LoanService < BaseService
      # GET /loans. Note loans are scoped by ITEM, not by account.
      def list(item_id:)
        require_args!(item_id: item_id)
        list_request("/loans", klass: Resources::Loan, itemId: item_id)
      end

      def retrieve(id)
        require_args!(id: id)
        object_request(:get, "/loans/#{id}", klass: Resources::Loan)
      end
    end

    class ItemService < BaseService
      # There is deliberately no #list: GET /items does not exist in the API.
      # Persist the ids you create, normally keyed by your own clientUserId.

      # POST /items.
      #
      # `parameters` is a connector-defined {String => String} credential map
      # (or an encrypted string). Its keys are passed through untouched -- see
      # Util.encode_body's `opaque` handling -- because camelizing a credential
      # named "cpf_cnpj" would break item creation.
      #
      # Never retried on failure: the API has no idempotency key, so a retry
      # could open a duplicate connection.
      def create(connector_id:, parameters:, **options)
        require_args!(connector_id: connector_id, parameters: parameters)
        object_request(:post, "/items",
          klass: Resources::Item,
          opaque: %w[parameters],
          body: { connector_id: connector_id, parameters: parameters, **options })
      end

      def retrieve(id)
        require_args!(id: id)
        object_request(:get, "/items/#{id}", klass: Resources::Item)
      end

      # PATCH /items/{id} triggers a fresh sync, optionally updating credentials.
      def update(id, **body)
        require_args!(id: id)
        object_request(:patch, "/items/#{id}",
          klass: Resources::Item, opaque: %w[parameters], body: body)
      end

      def delete(id)
        require_args!(id: id)
        object_request(:delete, "/items/#{id}", klass: Resources::Count)
      end

      # POST /items/{id}/mfa. The body is a bare {name => value} map, not a
      # wrapped object, e.g. send_mfa(id, token: "123456").
      def send_mfa(id, values)
        require_args!(id: id, values: values)
        object_request(:post, "/items/#{id}/mfa",
          klass: Resources::Item,
          body: Util.stringify_keys(values.to_h))
      end

      # PATCH, and it takes no body.
      def disable_auto_sync(id)
        require_args!(id: id)
        object_request(:patch, "/items/#{id}/disable-auto-sync", klass: Resources::Item)
      end
    end

    class ConnectorService < BaseService
      # GET /connectors. `countries` and `types` are comma-joined by the encoder.
      #
      # The endpoint accepts page/pageSize, so the result always knows how to
      # fetch its successor -- auto_paging_each walks the whole catalogue even
      # when the first page was requested without paging parameters.
      def list(countries: nil, types: nil, name: nil, sandbox: nil, health_details: nil,
        is_open_finance: nil, supports_payment_initiation: nil,
        supports_smart_transfers: nil, supports_automatic_pix: nil,
        page: nil, page_size: nil)
        list_request("/connectors",
          klass: Resources::Connector,
          paginated: true,
          countries: countries,
          types: types,
          name: name,
          sandbox: sandbox,
          healthDetails: health_details,
          isOpenFinance: is_open_finance,
          supportsPaymentInitiation: supports_payment_initiation,
          supportsSmartTransfers: supports_smart_transfers,
          supportsAutomaticPix: supports_automatic_pix,
          page: page,
          pageSize: page_size)
      end

      # NOTE: a connector id is a NUMBER, not a UUID.
      def retrieve(id, health_details: nil)
        require_args!(id: id)
        object_request(:get, "/connectors/#{id}",
          klass: Resources::Connector, healthDetails: health_details)
      end
    end

    class CategoryService < BaseService
      # GET /categories. The spec declares a bare array but its own example is a
      # page envelope, so the shape is sniffed at runtime; either way you get a
      # list that answers #each.
      def list(parent_id: nil)
        list_request("/categories", klass: Resources::Category, parentId: parent_id)
      end

      def retrieve(id)
        require_args!(id: id)
        object_request(:get, "/categories/#{id}", klass: Resources::Category)
      end
    end

    class MerchantService < BaseService
      # GET /merchants. Returns three buckets (found, not found, invalid) rather
      # than a list, so it maps to MerchantSearch rather than a list object.
      def search(cnpjs)
        list = Array(cnpjs)
        require_args!(cnpjs: list)
        object_request(:get, "/merchants", klass: Resources::MerchantSearch, cnpjs: list)
      end

      # Resolve a single CNPJ, or nil when it is unknown or invalid.
      def retrieve(cnpj)
        search([cnpj]).found_merchants&.first
      end
    end

    class ConnectTokenService < BaseService
      # POST /connect_token.
      #
      # Returns a 30-minute token for the Connect Widget in your frontend. It is
      # not an apiKey and cannot authenticate API calls.
      #
      # Pass item_id: to let the widget update an existing item instead of
      # creating a new one.
      def create(item_id: nil, options: nil)
        body = {}
        body[:item_id] = item_id if item_id
        body[:options] = options if options

        object_request(:post, "/connect_token",
          klass: Resources::ConnectToken,
          body: body.empty? ? nil : body)
      end
    end
  end
end
