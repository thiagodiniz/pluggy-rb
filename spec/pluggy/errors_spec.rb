# frozen_string_literal: true

RSpec.describe "error handling" do
  let(:client) do
    stub_auth
    test_client
  end

  let(:account_id) { "562b795d-1653-429f-be86-74ead9502813" }

  describe "status to class mapping" do
    {
      400 => Pluggy::InvalidRequestError,
      404 => Pluggy::NotFoundError,
      409 => Pluggy::ConflictError,
      429 => Pluggy::RateLimitError,
      500 => Pluggy::APIError,
      502 => Pluggy::BadGatewayError
    }.each do |status, klass|
      it "maps #{status} to #{klass}" do
        stub_pluggy(:get, "/bills/bill-1", status: status,
          body: { code: status, message: "boom" })

        expect { client.bills.retrieve("bill-1") }.to raise_error(klass)
      end
    end

    it "falls back to APIError for an undocumented 5xx" do
      stub_pluggy(:get, "/bills/bill-1", status: 503, body: { code: 503, message: "unavailable" })

      expect { client.bills.retrieve("bill-1") }.to raise_error(Pluggy::APIError)
    end
  end

  describe "the transcript on the exception" do
    it "carries status, body, json, code and codeDescription" do
      stub_pluggy(:get, "/transactions/t-1", status: 404, fixture: "errors/404_transaction")

      expect { client.transactions.retrieve("t-1") }.to raise_error(Pluggy::NotFoundError) do |e|
        expect(e.http_status).to eq(404)
        expect(e.code).to eq(404)
        expect(e.code_description).to eq("TRANSACTION_NOT_FOUND")
        expect(e.json_body).to include("message")
        expect(e.http_body).to be_a(String)
        # message/to_s append the discriminator, which is what you want in a log...
        expect(e.message).to eq("Transaction not found (TRANSACTION_NOT_FOUND)")
        expect(e.to_s).to eq("Transaction not found (TRANSACTION_NOT_FOUND)")
        # ...and api_message keeps the API's own text undecorated.
        expect(e.api_message).to eq("Transaction not found")
      end
    end

    it "survives a non-JSON error page from a proxy" do
      stub_request(:get, "#{StubAPI::BASE}/bills/bill-1")
        .to_return(status: 502, body: "<html>Bad Gateway</html>",
          headers: { "Content-Type" => "text/html" })

      expect { client.bills.retrieve("bill-1") }.to raise_error(Pluggy::BadGatewayError) do |e|
        expect(e.json_body).to be_nil
        expect(e.http_body).to include("Bad Gateway")
        expect(e.message).to eq("Pluggy API returned HTTP 502")
      end
    end
  end

  # The schema declares `errors`; every example in the spec emits `details`.
  describe "POST /items validation errors" do
    it "reads parameter errors from `details` as well as `errors`" do
      stub_pluggy(:post, "/items", status: 400, fixture: "errors/400_item_validation")

      expect do
        client.items.create(connector_id: 201, parameters: { user: "x" })
      end.to raise_error(Pluggy::InvalidRequestError) do |e|
        expect(e.parameter_errors.map(&:parameter)).to eq(%w[user password])
        expect(e.parameter_errors.first.code).to eq("002")
        expect(e.parameter_errors.first.message).to eq("user is required")
      end
    end

    it "reads them from `errors` when the API follows its own schema" do
      body = { code: 400, message: "Parameters are not valid",
               errors: [{ code: "002", message: "user is required", parameter: "user" }] }
      stub_pluggy(:post, "/items", status: 400, body: body)

      expect do
        client.items.create(connector_id: 201, parameters: { user: "x" })
      end.to raise_error(Pluggy::InvalidRequestError) do |e|
        expect(e.parameter_errors.map(&:parameter)).to eq(["user"])
      end
    end

    it "returns an empty list when neither key is present" do
      stub_pluggy(:post, "/items", status: 400, body: { code: 400, message: "nope" })

      expect do
        client.items.create(connector_id: 201, parameters: { user: "x" })
      end.to raise_error(Pluggy::InvalidRequestError) { |e| expect(e.parameter_errors).to eq([]) }
    end
  end

  describe "ITEM_USER_ALREADY_EXISTS" do
    it "exposes the conflicting item ids, despite the body omitting `code`" do
      stub_pluggy(:post, "/items", status: 409, fixture: "errors/409_duplicate")

      expect do
        client.items.create(connector_id: 201, parameters: { user: "x" })
      end.to raise_error(Pluggy::ConflictError) do |e|
        expect(e.code).to be_nil
        expect(e.code_description).to eq("ITEM_USER_ALREADY_EXISTS")
        expect(e.duplicate_item_ids).to eq(
          %w[a658c848-e475-457b-8565-d1fffba127c4 b769d959-f586-4680-9676-e2000cb238d5]
        )
      end
    end
  end

  describe "invalid cursor" do
    it "is recognisable on the InvalidRequestError" do
      stub_pluggy(:get, "/v2/transactions", status: 400, fixture: "errors/400_invalid_cursor",
        query: { accountId: account_id, after: "garbage" })

      expect do
        client.transactions.list(account_id: account_id, after: "garbage")
      end.to raise_error(Pluggy::InvalidRequestError) { |e| expect(e).to be_invalid_cursor }
    end
  end

  describe "rate limiting" do
    it "exposes retry_after when the response happens to carry it" do
      stub_pluggy(:get, "/accounts/acc-1/balance", status: 429,
        fixture: "errors/429_balance", headers: { "Retry-After" => "30" })

      expect { client.accounts.balance("acc-1") }.to raise_error(Pluggy::RateLimitError) do |e|
        expect(e.retry_after).to eq(30)
        expect(e.code_description).to eq("BALANCE_OPEN_FINANCE_RATE_LIMIT")
      end
    end

    it "is nil when absent, since the spec documents no response headers" do
      stub_pluggy(:get, "/accounts/acc-1/balance", status: 429, fixture: "errors/429_balance")

      expect { client.accounts.balance("acc-1") }
        .to raise_error(Pluggy::RateLimitError) { |e| expect(e.retry_after).to be_nil }
    end
  end

  describe "retries" do
    it "retries a GET on 500 up to max_network_retries, then raises" do
      stub_pluggy(:get, "/bills/bill-1", status: 500, fixture: "errors/500")

      expect { client.bills.retrieve("bill-1") }.to raise_error(Pluggy::APIError)

      # 1 initial + 2 retries
      expect(a_request(:get, "#{StubAPI::BASE}/bills/bill-1")).to have_been_made.times(3)
    end

    it "recovers when a retry succeeds" do
      stub_request(:get, "#{StubAPI::BASE}/bills/bill-1")
        .to_return(status: 500, body: fixture_raw("errors/500"), headers: StubAPI::JSON_HEADERS)
        .then
        .to_return(status: 200, body: fixture_raw("bills/retrieve"), headers: StubAPI::JSON_HEADERS)

      expect(client.bills.retrieve("bill-1")).to be_a(Pluggy::Resources::Bill)
      expect(a_request(:get, "#{StubAPI::BASE}/bills/bill-1")).to have_been_made.twice
    end

    it "honours max_network_retries = 0" do
      stub_auth
      no_retry = test_client(max_network_retries: 0)
      stub_pluggy(:get, "/bills/bill-1", status: 500, fixture: "errors/500")

      expect { no_retry.bills.retrieve("bill-1") }.to raise_error(Pluggy::APIError)
      expect(a_request(:get, "#{StubAPI::BASE}/bills/bill-1")).to have_been_made.once
    end

    # No Idempotency-Key exists in this API, so retrying POST /items could open
    # a duplicate bank connection.
    it "never retries POST /items" do
      stub_pluggy(:post, "/items", status: 500, fixture: "errors/500")

      expect do
        client.items.create(connector_id: 201, parameters: { user: "x" })
      end.to raise_error(Pluggy::APIError)

      expect(a_request(:post, "#{StubAPI::BASE}/items")).to have_been_made.once
    end

    it "does retry POST /auth, which creates nothing" do
      stub_request(:post, "#{StubAPI::BASE}/auth")
        .to_return(status: 500, body: fixture_raw("errors/500"), headers: StubAPI::JSON_HEADERS)
        .then
        .to_return(status: 200, body: { apiKey: test_jwt }.to_json, headers: StubAPI::JSON_HEADERS)
      stub_pluggy(:get, "/bills/bill-1", fixture: "bills/retrieve")

      expect { test_client.bills.retrieve("bill-1") }.not_to raise_error
      expect(auth_requests_made).to have_been_made.twice
    end

    it "does not retry PATCH, which would queue redundant institution work" do
      stub_pluggy(:patch, "/items/item-1", status: 500, fixture: "errors/500")

      expect { client.items.update("item-1") }.to raise_error(Pluggy::APIError)
      expect(a_request(:patch, "#{StubAPI::BASE}/items/item-1")).to have_been_made.once
    end

    it "wraps a connection reset as ConnectionError after retrying" do
      stub_request(:get, "#{StubAPI::BASE}/bills/bill-1").to_raise(Errno::ECONNRESET)

      expect { client.bills.retrieve("bill-1") }
        .to raise_error(Pluggy::ConnectionError, /ECONNRESET/)
      expect(a_request(:get, "#{StubAPI::BASE}/bills/bill-1")).to have_been_made.times(3)
    end

    it "wraps a read timeout as TimeoutError" do
      stub_request(:get, "#{StubAPI::BASE}/bills/bill-1").to_timeout

      expect { client.bills.retrieve("bill-1") }.to raise_error(Pluggy::ConnectionError)
    end
  end

  describe "local validation, before any request" do
    it "requires item_id for accounts.list" do
      expect { client.accounts.list(item_id: nil) }
        .to raise_error(ArgumentError, /item_id is required/)
      expect(a_request(:get, "#{StubAPI::BASE}/accounts")).not_to have_been_made
    end

    it "requires account_id for transactions.list" do
      expect { client.transactions.list(account_id: "") }
        .to raise_error(ArgumentError, /account_id is required/)
    end

    it "rejects date_from combined with created_at_from, which the API 400s" do
      expect do
        client.transactions.list(account_id: account_id, date_from: "2024-01-01",
          created_at_from: "2024-01-01T00:00:00.000Z")
      end.to raise_error(ArgumentError, /cannot be combined/)
      expect(a_request(:get, "#{StubAPI::BASE}/v2/transactions")).not_to have_been_made
    end

    it "rejects more than 500 ids" do
      expect { client.transactions.list(account_id: account_id, ids: Array.new(501) { "x" }) }
        .to raise_error(ArgumentError, /at most 500 ids/)
    end

    it "rejects an unknown filter rather than silently dropping it" do
      expect { client.transactions.list(account_id: account_id, from: "2024-01-01") }
        .to raise_error(ArgumentError, /unknown filter/)
    end

    it "rejects a v1 page_size above the documented maximum" do
      expect { client.transactions.list(account_id: account_id, page_size: 501) }
        .to raise_error(ArgumentError, /cannot exceed 500/)
    end
  end
end
