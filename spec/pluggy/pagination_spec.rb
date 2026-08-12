# frozen_string_literal: true

RSpec.describe "pagination" do
  let(:client) do
    stub_auth
    test_client
  end

  let(:account_id) { "562b795d-1653-429f-be86-74ead9502813" }

  describe "cursor pagination (GET /v2/transactions)" do
    it "appends the server's `next` query string verbatim" do
      first = { "results" => [{ "id" => "t1" }],
                "next" => "?accountId=#{account_id}&after=CURSOR+WITH+PLUS==" }

      stub_pluggy(:get, "/v2/transactions", body: first, query: { accountId: account_id })
      # The whole point: the outbound URL is the path plus `next`, untouched --
      # no decode, no re-encode. A `+` in the cursor must survive as a `+`.
      terminal = stub_request(
        :get,
        "#{StubAPI::BASE}/v2/transactions?accountId=#{account_id}&after=CURSOR+WITH+PLUS=="
      ).to_return(status: 200,
        body: { "results" => [{ "id" => "t2" }], "next" => nil }.to_json,
        headers: StubAPI::JSON_HEADERS)

      ids = client.transactions.list(account_id: account_id).auto_paging_each.map(&:id)

      expect(ids).to eq(%w[t1 t2])
      expect(terminal).to have_been_requested
    end

    it "stops when `next` is null" do
      stub_pluggy(:get, "/v2/transactions", fixture: "transactions/v2_list_last_page",
        query: { accountId: account_id })

      page = client.transactions.list(account_id: account_id)

      expect(page).to be_a(Pluggy::Lists::CursorList)
      expect(page.more?).to be(false)
      expect(page.next_page).to be_nil
      expect(page.auto_paging_each.to_a.length).to eq(page.results.length)
    end

    it "exposes the whole query string as the resume token" do
      stub_pluggy(:get, "/v2/transactions", fixture: "transactions/v2_list_plus_cursor",
        query: { accountId: account_id })

      page = client.transactions.list(account_id: account_id)

      expect(page.next_token).to start_with("?accountId=")
      expect(page.next_token).to include("after=")
      # next_cursor is for humans; it is never used to build a request.
      expect(page.next_cursor).to be_a(String)
    end

    it "resumes from a persisted token" do
      token = "?accountId=#{account_id}&after=SAVED=="
      stub_request(:get, "#{StubAPI::BASE}/v2/transactions?accountId=#{account_id}&after=SAVED==")
        .to_return(status: 200, body: { "results" => [{ "id" => "t9" }], "next" => nil }.to_json,
          headers: StubAPI::JSON_HEADERS)

      expect(client.transactions.resume(token).map(&:id)).to eq(["t9"])
    end

    it "rejects a token that is not a query string" do
      expect { client.transactions.resume("after=SAVED==") }
        .to raise_error(ArgumentError, /starting with '\?'/)
    end

    it "raises on a malformed cursor from the server rather than guessing" do
      stub_pluggy(:get, "/v2/transactions",
        body: { "results" => [{ "id" => "t1" }], "next" => "accountId=x&after=y" },
        query: { accountId: account_id })

      page = client.transactions.list(account_id: account_id)

      expect { page.next_page }.to raise_error(Pluggy::Error, /malformed pagination cursor/)
    end

    it "is lazy: .first(1) fetches only the first page" do
      stub_pluggy(:get, "/v2/transactions",
        body: { "results" => [{ "id" => "t1" }, { "id" => "t2" }],
                "next" => "?accountId=#{account_id}&after=NEXT==" },
        query: { accountId: account_id })
      second = stub_request(:get, "#{StubAPI::BASE}/v2/transactions?accountId=#{account_id}&after=NEXT==")

      result = client.transactions.list(account_id: account_id).auto_paging_each.first(1)

      expect(result.map(&:id)).to eq(["t1"])
      expect(second).not_to have_been_requested
    end
  end

  describe "offset pagination (GET /transactions, v1)" do
    let(:v1_query) do
      { accountId: account_id, page: "1", pageSize: "500" }
    end

    it "walks pages using page + totalPages" do
      stub_request(:get, "#{StubAPI::BASE}/transactions")
        .with(query: v1_query)
        .to_return(status: 200,
          body: { "results" => [{ "id" => "t1" }], "page" => 1, "total" => 2,
                  "totalPages" => 2 }.to_json,
          headers: StubAPI::JSON_HEADERS)
      stub_request(:get, "#{StubAPI::BASE}/transactions")
        .with(query: v1_query.merge(page: "2"))
        .to_return(status: 200,
          body: { "results" => [{ "id" => "t2" }], "page" => 2, "total" => 2,
                  "totalPages" => 2 }.to_json,
          headers: StubAPI::JSON_HEADERS)

      ids = client.transactions.list(account_id: account_id, page: 1).auto_paging_each.map(&:id)

      expect(ids).to eq(%w[t1 t2])
    end

    it "carries filters across pages" do
      query = v1_query.merge(from: "2024-01-01")
      stub_request(:get, "#{StubAPI::BASE}/transactions")
        .with(query: query)
        .to_return(status: 200,
          body: { "results" => [{ "id" => "t1" }], "page" => 1, "total" => 2,
                  "totalPages" => 2 }.to_json,
          headers: StubAPI::JSON_HEADERS)
      page2 = stub_request(:get, "#{StubAPI::BASE}/transactions")
              .with(query: query.merge(page: "2"))
              .to_return(status: 200,
                body: { "results" => [], "page" => 2, "total" => 2,
                        "totalPages" => 2 }.to_json,
                headers: StubAPI::JSON_HEADERS)

      client.transactions.list(account_id: account_id, page: 1, from: "2024-01-01")
            .auto_paging_each.to_a

      expect(page2).to have_been_requested
    end
  end

  # /accounts, /bills and /loans return a page envelope but document no page or
  # pageSize parameter, so there is no way to ask for page 2. auto_paging_each
  # must yield the one page and stop rather than re-requesting it forever.
  describe "endpoints with a page envelope but no page parameter" do
    it "treats /accounts as a single page" do
      stub_pluggy(:get, "/accounts", body: { "results" => [{ "id" => "a1" }], "page" => 1,
                                             "total" => 1, "totalPages" => 1 },
        query: { itemId: "item-1" })

      list = client.accounts.list(item_id: "item-1")

      expect(list).to be_a(Pluggy::Lists::OffsetList)
      expect(list.paginated?).to be(false)
      expect(list.more?).to be(false)
      expect(list.auto_paging_each.to_a.map(&:id)).to eq(["a1"])
      expect(a_request(:get, "#{StubAPI::BASE}/accounts").with(query: { itemId: "item-1" }))
        .to have_been_made.once
    end

    it "does not loop even when the server claims more pages than it can serve" do
      stub_pluggy(:get, "/bills", body: { "results" => [{ "id" => "b1" }], "page" => 1,
                                          "total" => 40, "totalPages" => 4 },
        query: { accountId: account_id })

      list = client.bills.list(account_id: account_id)

      expect(list.total_pages).to eq(4)
      expect(list.more?).to be(false)
      expect(list.auto_paging_each.to_a.length).to eq(1)
      expect(a_request(:get, "#{StubAPI::BASE}/bills").with(query: { accountId: account_id }))
        .to have_been_made.once
    end
  end

  # The spec declares GET /categories as a bare array but its own example is a
  # page envelope. The sniffer resolves it at runtime so callers never care.
  describe "shape sniffing on GET /categories" do
    it "handles the bare array the schema declares" do
      stub_pluggy(:get, "/categories", fixture: "categories/list_array")

      list = client.categories.list

      expect(list).to be_a(Pluggy::Lists::ArrayList)
      expect(list.map(&:description)).to include("Income")
      expect(list.auto_paging_each.to_a.length).to eq(list.length)
    end

    it "handles the page envelope the example shows" do
      stub_pluggy(:get, "/categories", fixture: "categories/list_envelope")

      list = client.categories.list

      expect(list).to be_a(Pluggy::Lists::OffsetList)
      expect(list.map(&:description)).to include("Income")
    end

    it "raises a clear error on an envelope it does not recognise" do
      stub_pluggy(:get, "/categories", body: { "unexpected" => true })

      expect { client.categories.list }
        .to raise_error(Pluggy::Error, /unrecognized list envelope/)
    end
  end
end
