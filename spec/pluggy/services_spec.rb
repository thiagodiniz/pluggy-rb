# frozen_string_literal: true

RSpec.describe "services" do
  let(:client) do
    stub_auth
    test_client
  end

  let(:item_id) { "a658c848-e475-457b-8565-d1fffba127c4" }
  let(:account_id) { "562b795d-1653-429f-be86-74ead9502813" }

  describe Pluggy::Services::ConnectTokenService do
    it "posts an empty body when given no options" do
      stub_pluggy(:post, "/connect_token", fixture: "auth/connect_token")

      token = client.create_connect_token

      expect(token).to be_a(Pluggy::Resources::ConnectToken)
      expect(token.access_token).to be_a(String)
    end

    it "camelizes nested options" do
      stub_pluggy(:post, "/connect_token", fixture: "auth/connect_token")

      client.connect_tokens.create(
        item_id: item_id,
        options: { client_user_id: "user-42", webhook_url: "https://example.com/hook",
                   avoid_duplicates: true }
      )

      expect(
        a_request(:post, "#{StubAPI::BASE}/connect_token").with(
          body: { itemId: item_id,
                  options: { clientUserId: "user-42", webhookUrl: "https://example.com/hook",
                             avoidDuplicates: true } }
        )
      ).to have_been_made
    end
  end

  describe Pluggy::Services::AccountService do
    it "requires itemId and passes the type filter through" do
      stub_pluggy(:get, "/accounts", fixture: "accounts/list",
        query: { itemId: item_id, type: "CREDIT" })

      list = client.accounts.list(item_id: item_id, type: "CREDIT")

      expect(list.first).to be_a(Pluggy::Resources::Account)
    end

    it "parses a BANK account and its bankData" do
      stub_pluggy(:get, "/accounts/acc-1", fixture: "accounts/retrieve_bank")

      account = client.accounts.retrieve("acc-1")

      expect(account).to be_bank
      expect(account).not_to be_credit
      expect(account.bank_data).to be_a(Pluggy::Resources::BankData)
      # This fixture's balances are JSON integers (120950), so they stay
      # Integers -- decimal_class only promotes values written with a decimal
      # point. Both are exact, which is the property that matters; see the
      # "fetches a live balance" example for the BigDecimal case.
      expect(account.balance).to be_a(Integer)
      expect(account.bank_data.closing_balance).to be_a(Numeric)
      expect(account.bank_data.transfer_number).to be_a(String)
    end

    it "parses a CREDIT account and its creditData" do
      stub_pluggy(:get, "/accounts/acc-2", fixture: "accounts/retrieve_credit")

      account = client.accounts.retrieve("acc-2")

      expect(account).to be_credit
      expect(account).to be_credit_card
      expect(account.credit_data).to be_a(Pluggy::Resources::CreditData)
      expect(account.credit_data.brand).to be_a(String)
    end

    it "fetches a live balance" do
      stub_pluggy(:get, "/accounts/acc-1/balance", fixture: "accounts/balance")

      balance = client.accounts.balance("acc-1")

      expect(balance).to be_a(Pluggy::Resources::Balance)
      expect(balance.balance).to be_a(BigDecimal)
      expect(balance.currency_code).to eq("BRL")
    end

    it "lists statements" do
      stub_pluggy(:get, "/accounts/acc-1/statements", fixture: "accounts/statements")

      statements = client.accounts.statements("acc-1")

      expect(statements.first).to be_a(Pluggy::Resources::Statement)
      expect(statements.first.url).to be_a(String)
      # "01-2025" is MM-YYYY, which is why month_year is never coerced.
      expect(statements.first.month_year).to eq("01-2025")
    end

    it "refuses to list bills for a non-credit account" do
      stub_pluggy(:get, "/accounts/acc-1", fixture: "accounts/retrieve_bank")

      account = client.accounts.retrieve("acc-1")

      expect { account.bills }.to raise_error(Pluggy::Error, /only for credit-card accounts/)
      expect(a_request(:get, "#{StubAPI::BASE}/bills")).not_to have_been_made
    end
  end

  describe Pluggy::Services::TransactionService do
    it "defaults to the cursor-paginated v2 endpoint" do
      stub_pluggy(:get, "/v2/transactions", fixture: "transactions/v2_list_last_page",
        query: { accountId: account_id })

      list = client.transactions.list(account_id: account_id)

      expect(list).to be_a(Pluggy::Lists::CursorList)
      expect(a_request(:get, "#{StubAPI::BASE}/transactions")).not_to have_been_made
    end

    it "maps v2 filters onto their wire names" do
      query = { accountId: account_id, dateFrom: "2024-01-01", dateTo: "2024-03-31" }
      stub_pluggy(:get, "/v2/transactions", fixture: "transactions/v2_list_last_page", query: query)

      client.transactions.list(account_id: account_id,
        date_from: Date.new(2024, 1, 1),
        date_to: Date.new(2024, 3, 31))

      expect(a_request(:get, "#{StubAPI::BASE}/v2/transactions").with(query: query))
        .to have_been_made
    end

    # billId only exists on v1, so asking for it must route there.
    it "routes to the deprecated v1 endpoint when bill_id is given" do
      query = { accountId: account_id, billId: "bill-1", page: "1", pageSize: "500" }
      stub_pluggy(:get, "/transactions", fixture: "transactions/v1_list", query: query)

      list = client.transactions.list(account_id: account_id, bill_id: "bill-1")

      expect(list).to be_a(Pluggy::Lists::OffsetList)
      expect(list.paginated?).to be(true)
      expect(a_request(:get, "#{StubAPI::BASE}/v2/transactions")).not_to have_been_made
    end

    it "routes to v1 when page or page_size is given" do
      stub_pluggy(:get, "/transactions", fixture: "transactions/v1_list",
        query: { accountId: account_id, page: "2", pageSize: "100" })

      client.transactions.list(account_id: account_id, page: 2, page_size: 100)

      expect(a_request(:get, "#{StubAPI::BASE}/transactions")
               .with(query: { accountId: account_id, page: "2", pageSize: "100" }))
        .to have_been_made
    end

    it "honours an explicit version and the global default" do
      stub_pluggy(:get, "/transactions", fixture: "transactions/v1_list",
        query: { accountId: account_id, page: "1", pageSize: "500" })

      client.transactions.list(account_id: account_id, version: :v1)

      expect(a_request(:get, "#{StubAPI::BASE}/transactions")
               .with(query: { accountId: account_id, page: "1", pageSize: "500" }))
        .to have_been_made
    end

    it "logs a deprecation notice when it uses v1" do
      logger = instance_spy(Logger)
      stub_auth
      logged = test_client(logger: logger, log_level: :info)
      stub_pluggy(:get, "/transactions", fixture: "transactions/v1_list",
        query: { accountId: account_id, billId: "b1", page: "1", pageSize: "500" })

      logged.transactions.list(account_id: account_id, bill_id: "b1")

      expect(logger).to have_received(:info).with(%r{deprecated GET /transactions.*2026-12-31})
    end

    it "accepts v2 spellings on v1 and translates them" do
      query = { accountId: account_id, billId: "b1", from: "2024-01-01", page: "1", pageSize: "500" }
      stub_pluggy(:get, "/transactions", fixture: "transactions/v1_list", query: query)

      client.transactions.list(account_id: account_id, bill_id: "b1", date_from: "2024-01-01")

      expect(a_request(:get, "#{StubAPI::BASE}/transactions").with(query: query)).to have_been_made
    end

    it "recategorizes a transaction" do
      stub_pluggy(:patch, "/transactions/t-1", fixture: "transactions/retrieve")

      client.transactions.update("t-1", category_id: "07010000")

      expect(a_request(:patch, "#{StubAPI::BASE}/transactions/t-1")
               .with(body: { categoryId: "07010000" })).to have_been_made
    end
  end

  describe Pluggy::Services::ItemService do
    # GET /items simply does not exist in the API.
    it "offers no list method" do
      expect(client.items).not_to respond_to(:list)
    end

    it "creates an item without camelizing connector credentials" do
      stub_pluggy(:post, "/items", fixture: "items/retrieve")

      client.items.create(
        connector_id: 201,
        parameters: { "cpf_cnpj" => "12345678901", "password" => "secret" },
        client_user_id: "user-42",
        products: %w[ACCOUNTS TRANSACTIONS]
      )

      expect(
        a_request(:post, "#{StubAPI::BASE}/items").with(
          body: { connectorId: 201,
                  parameters: { "cpf_cnpj" => "12345678901", "password" => "secret" },
                  clientUserId: "user-42",
                  products: %w[ACCOUNTS TRANSACTIONS] }
        )
      ).to have_been_made
    end

    it "parses statusDetail per product" do
      stub_pluggy(:get, "/items/#{item_id}", fixture: "items/retrieve")

      item = client.items.retrieve(item_id)

      expect(item).to be_updated
      expect(item).to be_succeeded
      expect(item.status_detail.updated?(:transactions)).to be(true)
      expect(item.status_detail.updated?(:loans)).to be(false)
      expect(item.status_detail.warnings.first.message).to include("Loans not available")
      expect(item.client_user_id).to eq("user-42")
    end

    it "recognises an item waiting for MFA" do
      stub_pluggy(:get, "/items/#{item_id}", fixture: "items/waiting_mfa")

      item = client.items.retrieve(item_id)

      expect(item).to be_waiting_user_input
      expect(item).to be_mfa_required
      expect(item.user_action.instructions).to include("6-digit code")
      expect(item.parameter).to be_mfa
    end

    it "sends MFA as a bare map, not a wrapped object" do
      stub_pluggy(:post, "/items/#{item_id}/mfa", fixture: "items/retrieve")

      client.items.send_mfa(item_id, token: "123456")

      expect(a_request(:post, "#{StubAPI::BASE}/items/#{item_id}/mfa")
               .with(body: { "token" => "123456" })).to have_been_made
    end

    it "disables auto-sync with a PATCH and no body" do
      stub_pluggy(:patch, "/items/#{item_id}/disable-auto-sync", fixture: "items/retrieve")

      client.items.disable_auto_sync(item_id)

      expect(
        a_request(:patch, "#{StubAPI::BASE}/items/#{item_id}/disable-auto-sync") do |req|
          req.body.nil? || req.body.empty?
        end
      ).to have_been_made
    end

    it "returns a count from delete" do
      stub_pluggy(:delete, "/items/#{item_id}", fixture: "items/deleted")

      expect(client.items.delete(item_id).count).to eq(1)
    end
  end

  describe Pluggy::Services::ConnectorService do
    it "comma-joins countries and types" do
      query = { countries: "BR", types: "PERSONAL_BANK,BUSINESS_BANK", sandbox: "true" }
      stub_pluggy(:get, "/connectors", fixture: "connectors/list", query: query)

      list = client.connectors.list(countries: %w[BR], types: %w[PERSONAL_BANK BUSINESS_BANK],
        sandbox: true)

      expect(list.first).to be_a(Pluggy::Resources::Connector)
      expect(a_request(:get, "#{StubAPI::BASE}/connectors").with(query: query)).to have_been_made
    end

    it "reads health, credentials and the undeclared isSandbox flag" do
      stub_pluggy(:get, "/connectors", fixture: "connectors/list")

      unstable = client.connectors.list.find { |c| c.name.include?("MFA") }

      expect(unstable).to be_mfa
      expect(unstable).to be_sandbox
      expect(unstable).to be_open_finance
      expect(unstable.health).to be_unstable
      expect(unstable.health.details.connection_rate_last6_hours).to eq(72.5)
      expect(unstable.credential_names).to eq(%w[user token])
      expect(unstable.supports?(:loans)).to be(true)
    end

    it "takes a numeric id, unlike every other resource" do
      stub_pluggy(:get, "/connectors/201", fixture: "connectors/retrieve")

      connector = client.connectors.retrieve(201)

      expect(connector.id).to eq(201)
      expect(connector.credentials.first.valid?("12345678901")).to be(true)
      expect(connector.credentials.first.valid?("nope")).to be(false)
    end
  end

  describe Pluggy::Services::LoanService do
    it "lists loans by item, not by account" do
      stub_pluggy(:get, "/loans", fixture: "loans/list", query: { itemId: item_id })

      list = client.loans.list(item_id: item_id)

      expect(list.first).to be_a(Pluggy::Resources::Loan)
    end

    it "exposes outstanding balance and overdue state" do
      stub_pluggy(:get, "/loans/loan-1", fixture: "loans/retrieve")

      loan = client.loans.retrieve("loan-1")

      expect(loan.cet).to be_a(Numeric)
      expect(loan.installments).to be_a(Pluggy::Resources::LoanInstallments)
      expect(loan.outstanding_balance).to be_a(Numeric)
    end
  end

  describe Pluggy::Services::MerchantService do
    it "comma-joins cnpjs and buckets the response" do
      stub_pluggy(:get, "/merchants", fixture: "merchants/search",
        query: { cnpjs: "00000000000191,60701190000104" })

      result = client.merchants.search(%w[00000000000191 60701190000104])

      expect(result).to be_a(Pluggy::Resources::MerchantSearch)
      expect(result.found).to all(be_a(Pluggy::Resources::Merchant))
      expect(result.not_found).to be_a(Array)
      expect(result.invalid).to be_a(Array)
    end
  end

  describe Pluggy::Services::CategoryService do
    it "passes parent_id as parentId" do
      stub_pluggy(:get, "/categories", fixture: "categories/list_array",
        query: { parentId: "01000000" })

      list = client.categories.list(parent_id: "01000000")

      expect(list.first).to be_a(Pluggy::Resources::Category)
    end

    it "identifies roots" do
      stub_pluggy(:get, "/categories/01010000", fixture: "categories/retrieve")

      category = client.categories.retrieve("01010000")

      expect(category).not_to be_root
      expect(category.parent_description).to eq("Income")
    end
  end

  describe "escape hatches for out-of-scope endpoints" do
    it "exposes a raw authenticated GET" do
      stub_pluggy(:get, "/investments", body: { "results" => [], "page" => 1 },
        query: { itemId: item_id })

      expect(client.get("/investments", item_id: item_id)).to include("results")
    end
  end
end
