# frozen_string_literal: true

# Listing one credit-card bill's line items.
#
# GET /v2/transactions dropped the billId filter that v1 had, and v1 is
# deprecated with a 2026-12-31 sunset. So the default path lists the account's
# transactions over the statement cycle and filters on
# creditCardMetadata.billId.
#
# The invariant that makes this safe: the billId check is authoritative and
# always runs, so the date window only affects HOW MANY requests are made,
# never WHICH transactions come back.
RSpec.describe "a credit card's bills and their line items" do
  let(:client) do
    stub_auth
    test_client
  end

  let(:account_id) { "acc-card-1" }

  # Three consecutive statement cycles.
  let(:bills_payload) do
    {
      "page" => 1, "total" => 3, "totalPages" => 1,
      "results" => [
        { "id" => "bill-jan", "accountId" => account_id, "billClosingDate" => "2024-01-25",
          "dueDate" => "2024-02-05", "totalAmount" => 100.50 },
        { "id" => "bill-feb", "accountId" => account_id, "billClosingDate" => "2024-02-25",
          "dueDate" => "2024-03-05", "totalAmount" => 210.75 },
        { "id" => "bill-mar", "accountId" => account_id, "billClosingDate" => "2024-03-25",
          "dueDate" => "2024-04-05", "totalAmount" => 55.20 }
      ]
    }
  end

  # A page deliberately mixing two bills' transactions, plus one with no card
  # metadata at all, so the filter has something real to do.
  let(:mixed_transactions) do
    {
      "results" => [
        { "id" => "t-feb-1", "amount" => -10.5, "date" => "2024-02-01T00:00:00.000Z",
          "type" => "DEBIT", "accountId" => account_id,
          "creditCardMetadata" => { "billId" => "bill-feb" } },
        { "id" => "t-mar-1", "amount" => -20.0, "date" => "2024-03-01T00:00:00.000Z",
          "type" => "DEBIT", "accountId" => account_id,
          "creditCardMetadata" => { "billId" => "bill-mar" } },
        { "id" => "t-feb-2", "amount" => -30.25, "date" => "2024-02-10T00:00:00.000Z",
          "type" => "DEBIT", "accountId" => account_id,
          "creditCardMetadata" => { "billId" => "bill-feb", "totalInstallments" => 3,
                                    "installmentNumber" => 1 } },
        { "id" => "t-payment", "amount" => 100.5, "date" => "2024-02-05T00:00:00.000Z",
          "type" => "CREDIT", "accountId" => account_id }
      ],
      "next" => nil
    }
  end

  describe "when bills came from bills.list" do
    it "derives an exact one-cycle window from the previous bill's closing date" do
      stub_pluggy(:get, "/bills", body: bills_payload, query: { accountId: account_id })
      # bill-feb's cycle: the day after bill-jan closed, through bill-feb's due date.
      window = stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id, dateFrom: "2024-01-26",
                 dateTo: "2024-03-05" })

      bill = client.bills.list(account_id: account_id).find { |b| b.id == "bill-feb" }
      bill.transactions.to_a

      expect(window).to have_been_requested
    end

    it "returns only the transactions tagged with that bill" do
      stub_pluggy(:get, "/bills", body: bills_payload, query: { accountId: account_id })
      stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id, dateFrom: "2024-01-26", dateTo: "2024-03-05" })

      bill = client.bills.list(account_id: account_id).find { |b| b.id == "bill-feb" }

      expect(bill.transactions.map(&:id)).to eq(%w[t-feb-1 t-feb-2])
    end

    it "excludes transactions with no card metadata, such as the statement payment" do
      stub_pluggy(:get, "/bills", body: bills_payload, query: { accountId: account_id })
      stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id, dateFrom: "2024-01-26", dateTo: "2024-03-05" })

      bill = client.bills.list(account_id: account_id).find { |b| b.id == "bill-feb" }

      expect(bill.transactions.map(&:id)).not_to include("t-payment")
    end

    it "leaves the oldest bill without a predecessor, falling back to a wide window" do
      stub_pluggy(:get, "/bills", body: bills_payload, query: { accountId: account_id })
      fallback = stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id,
                 dateFrom: (Date.new(2024, 1, 25) - 62).to_s,
                 dateTo: "2024-02-05" })

      bill = client.bills.list(account_id: account_id).find { |b| b.id == "bill-jan" }
      bill.transactions.to_a

      expect(fallback).to have_been_requested
    end

    it "is lazy, so it does not fetch until iterated" do
      stub_pluggy(:get, "/bills", body: bills_payload, query: { accountId: account_id })
      txns = stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id, dateFrom: "2024-01-26",
                 dateTo: "2024-03-05" })

      bill = client.bills.list(account_id: account_id).find { |b| b.id == "bill-feb" }
      enumerator = bill.transactions

      expect(txns).not_to have_been_requested
      enumerator.first
      expect(txns).to have_been_requested
    end
  end

  describe "when the bill was fetched on its own" do
    it "widens the window and says so in the log" do
      logger = instance_spy(Logger)
      stub_auth
      logged = test_client(logger: logger, log_level: :info)

      stub_pluggy(:get, "/bills/bill-feb",
        body: { "id" => "bill-feb", "accountId" => account_id,
                "billClosingDate" => "2024-02-25", "dueDate" => "2024-03-05" })
      wide = stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id,
                 dateFrom: (Date.new(2024, 2, 25) - 62).to_s,
                 dateTo: "2024-03-05" })

      logged.bills.retrieve("bill-feb").transactions.to_a

      expect(wide).to have_been_requested
      expect(logger).to have_received(:info).with(/previous cycle unknown/)
    end

    it "still returns exactly the right transactions despite the wider window" do
      stub_pluggy(:get, "/bills/bill-feb",
        body: { "id" => "bill-feb", "accountId" => account_id,
                "billClosingDate" => "2024-02-25", "dueDate" => "2024-03-05" })
      stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id, dateFrom: (Date.new(2024, 2, 25) - 62).to_s,
                 dateTo: "2024-03-05" })

      bill = client.bills.retrieve("bill-feb")

      expect(bill.transactions.map(&:id)).to eq(%w[t-feb-1 t-feb-2])
    end
  end

  describe "explicit overrides" do
    it "accepts a caller-supplied window" do
      stub_pluggy(:get, "/bills/bill-feb",
        body: { "id" => "bill-feb", "accountId" => account_id,
                "billClosingDate" => "2024-02-25", "dueDate" => "2024-03-05" })
      custom = stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id, dateFrom: "2023-01-01",
                 dateTo: "2024-12-31" })

      client.bills.retrieve("bill-feb")
            .transactions(date_from: "2023-01-01", date_to: "2024-12-31").to_a

      expect(custom).to have_been_requested
    end

    it "uses v1's server-side billId filter under strategy: :legacy" do
      stub_pluggy(:get, "/bills/bill-feb",
        body: { "id" => "bill-feb", "accountId" => account_id,
                "dueDate" => "2024-03-05" })
      legacy = stub_pluggy(:get, "/transactions", fixture: "transactions/v1_list",
        query: { accountId: account_id, billId: "bill-feb",
                 page: "1", pageSize: "500" })

      result = client.bills.retrieve("bill-feb").transactions(strategy: :legacy)

      expect(legacy).to have_been_requested
      # A real list object this time, since the server did the filtering.
      expect(result).to be_a(Pluggy::Lists::OffsetList)
      expect(a_request(:get, "#{StubAPI::BASE}/v2/transactions")).not_to have_been_made
    end
  end

  describe "bill conveniences" do
    it "reports installment metadata on line items" do
      stub_pluggy(:get, "/bills", body: bills_payload, query: { accountId: account_id })
      stub_pluggy(:get, "/v2/transactions", body: mixed_transactions,
        query: { accountId: account_id, dateFrom: "2024-01-26", dateTo: "2024-03-05" })

      bill = client.bills.list(account_id: account_id).find { |b| b.id == "bill-feb" }
      installment = bill.transactions.find(&:installment?)

      expect(installment.id).to eq("t-feb-2")
      expect(installment.installment_label).to eq("1/3")
      expect(installment.bill_id).to eq("bill-feb")
    end

    it "sums finance charges" do
      bill = Pluggy::Resources::Bill.new(fixture("bills/retrieve"))
      expect(bill.finance_charges_total).to be_a(Numeric)
    end

    it "raises a clear error when accountId is missing" do
      bare = Pluggy::Resources::Bill.new({ "id" => "bill-x" }, client: client)

      expect { bare.transactions }.to raise_error(Pluggy::Error, /has no accountId/)
    end
  end

  describe "walking a whole item" do
    it "streams every transaction across every account" do
      # The fixture carries its own id, which is what item.accounts will use.
      fixture_item_id = fixture("items/retrieve").fetch("id")
      stub_pluggy(:get, "/items/item-1", fixture: "items/retrieve")
      stub_pluggy(:get, "/accounts",
        body: { "results" => [{ "id" => "acc-1", "type" => "BANK",
                                "subtype" => "CHECKING_ACCOUNT" },
                              { "id" => "acc-2", "type" => "CREDIT",
                                "subtype" => "CREDIT_CARD" }],
                "page" => 1, "total" => 2, "totalPages" => 1 },
        query: { itemId: fixture_item_id })
      stub_pluggy(:get, "/v2/transactions",
        body: { "results" => [{ "id" => "t-a" }], "next" => nil },
        query: { accountId: "acc-1" })
      stub_pluggy(:get, "/v2/transactions",
        body: { "results" => [{ "id" => "t-b" }], "next" => nil },
        query: { accountId: "acc-2" })

      item = client.items.retrieve("item-1")

      expect(item.transactions.map(&:id)).to eq(%w[t-a t-b])
    end
  end
end
