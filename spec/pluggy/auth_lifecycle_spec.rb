# frozen_string_literal: true

RSpec.describe "apiKey lifecycle" do
  let(:accounts_query) { { itemId: "item-1" } }

  def list_accounts(client)
    client.accounts.list(item_id: "item-1")
  end

  describe "lazy authentication" do
    it "does not authenticate until the first request" do
      stub_auth
      test_client

      expect(auth_requests_made).not_to have_been_made
    end

    it "authenticates once and reuses the key across requests" do
      stub_auth
      stub_pluggy(:get, "/accounts", fixture: "accounts/list", query: accounts_query)

      client = test_client
      3.times { list_accounts(client) }

      expect(auth_requests_made).to have_been_made.once
    end

    it "sends the apiKey as X-API-KEY" do
      key = test_jwt
      stub_auth(api_key: key)
      stub_pluggy(:get, "/accounts", fixture: "accounts/list", query: accounts_query)

      list_accounts(test_client)

      expect(
        a_request(:get, "#{StubAPI::BASE}/accounts")
          .with(query: accounts_query, headers: { "X-API-KEY" => key })
      ).to have_been_made
    end

    it "does not send X-API-KEY on POST /auth itself" do
      stub_auth
      stub_pluggy(:get, "/accounts", fixture: "accounts/list", query: accounts_query)

      list_accounts(test_client)

      expect(
        a_request(:post, "#{StubAPI::BASE}/auth") { |req| !req.headers.key?("X-Api-Key") }
      ).to have_been_made
    end

    it "re-authenticates when the cached key is already past its exp" do
      stub_auth(api_key: test_jwt(exp: Time.now - 60))
      stub_pluggy(:get, "/accounts", fixture: "accounts/list", query: accounts_query)

      client = test_client
      2.times { list_accounts(client) }

      # Expired on arrival, so every request refreshes it first.
      expect(auth_requests_made).to have_been_made.twice
    end
  end

  # The load-bearing distinction. Pluggy signals an expired key with a 403
  # carrying NO codeDescription, and a domain denial with a 403 that HAS one.
  # Treating them alike would silently mask consent errors and double the
  # request count on every balance call.
  describe "the 403 fork" do
    let(:balance_path) { "/accounts/acc-1/balance" }

    it "renews and retries once on a 403 with no codeDescription" do
      stub_auth
      stub_request(:get, "#{StubAPI::BASE}/accounts")
        .with(query: accounts_query)
        .to_return(status: 403, body: fixture_raw("errors/403_expired"),
          headers: StubAPI::JSON_HEADERS)
        .then
        .to_return(status: 200, body: fixture_raw("accounts/list"),
          headers: StubAPI::JSON_HEADERS)

      result = list_accounts(test_client)

      expect(result).not_to be_empty
      expect(auth_requests_made).to have_been_made.twice
      expect(a_request(:get, "#{StubAPI::BASE}/accounts").with(query: accounts_query))
        .to have_been_made.twice
    end

    it "raises PermissionError without renewing on a 403 that has a codeDescription" do
      stub_auth
      stub_pluggy(:get, balance_path, status: 403, fixture: "errors/403_balance_consent")

      client = test_client

      expect { client.accounts.balance("acc-1") }.to raise_error(Pluggy::PermissionError) do |error|
        expect(error.code_description).to eq("BALANCE_CONSENT_ERROR")
        expect(error.http_status).to eq(403)
        expect(error.message).to include("denied access to the account balance")
      end

      # The key was never the problem, so it must not have been renewed...
      expect(auth_requests_made).to have_been_made.once
      # ...and the call must not have been repeated against the institution.
      expect(a_request(:get, "#{StubAPI::BASE}#{balance_path}")).to have_been_made.once
    end

    it "gives up after exactly one renewal when the 403 persists" do
      stub_auth
      stub_pluggy(:get, "/accounts", status: 403, fixture: "errors/403_expired",
        query: accounts_query)

      expect { list_accounts(test_client) }.to raise_error(Pluggy::AuthenticationError)

      expect(auth_requests_made).to have_been_made.twice
      expect(a_request(:get, "#{StubAPI::BASE}/accounts").with(query: accounts_query))
        .to have_been_made.twice
    end
  end

  describe "with a caller-supplied api_key and no credentials" do
    it "never calls POST /auth" do
      stub_pluggy(:get, "/accounts", fixture: "accounts/list", query: accounts_query)

      list_accounts(Pluggy::Client.new(api_key: test_jwt))

      expect(auth_requests_made).not_to have_been_made
    end

    it "raises an actionable AuthenticationError instead of trying to renew" do
      stub_pluggy(:get, "/accounts", status: 403, fixture: "errors/403_expired",
        query: accounts_query)

      client = Pluggy::Client.new(api_key: test_jwt)

      expect { list_accounts(client) }.to raise_error(Pluggy::AuthenticationError, /client_id/)
      expect(auth_requests_made).not_to have_been_made
    end
  end

  describe "concurrent expiry" do
    it "authenticates only once when many threads start together" do
      stub_auth
      stub_pluggy(:get, "/accounts", fixture: "accounts/list", query: accounts_query)

      client = test_client
      Array.new(10) { Thread.new { list_accounts(client) } }.each(&:join)

      expect(auth_requests_made).to have_been_made.once
    end
  end

  describe "POST /auth failures" do
    it "maps invalid client keys to AuthenticationError" do
      stub_request(:post, "#{StubAPI::BASE}/auth")
        .to_return(status: 401, body: fixture_raw("errors/401_client_keys"),
          headers: StubAPI::JSON_HEADERS)

      expect { list_accounts(test_client) }.to raise_error(Pluggy::AuthenticationError) do |error|
        expect(error.code_description).to eq("CLIENT_KEYS_UNAUTHORIZED")
      end
    end
  end

  describe "configuration validation" do
    it "refuses to build a client with no credentials at all" do
      expect { Pluggy::Client.new }.to raise_error(Pluggy::ConfigurationError, /client_id/)
    end

    it "accepts credentials from the module-level config" do
      Pluggy.client_id = "test-client-id"
      Pluggy.client_secret = "test-client-secret"
      stub_auth
      stub_pluggy(:get, "/accounts", fixture: "accounts/list", query: accounts_query)

      expect { list_accounts(Pluggy::Client.new) }.not_to raise_error
    end
  end
end
