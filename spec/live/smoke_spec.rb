# frozen_string_literal: true

# Live smoke test against the real Pluggy API.
#
#   PLUGGY_CLIENT_ID=... PLUGGY_CLIENT_SECRET=... bundle exec rspec --tag live
#
# Excluded from the default suite unless both env vars are set, so
# `bundle exec rspec` stays hermetic.
#
# Read-only: it never creates or mutates an item unless PLUGGY_LIVE_ITEM_ID is
# also supplied, and even then it only reads. It asserts shapes and invariants
# rather than values, because this is the only place the gap between the
# published spec and the live API actually shows up.
RSpec.describe "live API", :live do
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  let(:client) do
    Pluggy::Client.new(
      client_id: ENV.fetch("PLUGGY_CLIENT_ID"),
      client_secret: ENV.fetch("PLUGGY_CLIENT_SECRET")
    )
  end

  describe "authentication" do
    it "returns a JWT whose expiry is about two hours out" do
      key = Pluggy::ApiKey.new(client.api_key)

      # If this drifts, the documented 2h TTL changed -- worth knowing.
      expect(key.expires_at).to be_within(20 * 60).of(Time.now + (2 * 3600))
    end

    it "caches the key rather than re-authenticating per call" do
      first = client.api_key
      second = client.api_key

      expect(second).to eq(first)
    end
  end

  describe "connect tokens" do
    it "issues one" do
      token = client.create_connect_token(options: { client_user_id: "pluggy-rb-smoke" })

      expect(token.access_token).to be_a(String)
      expect(token.access_token).not_to be_empty
    end
  end

  describe "connectors" do
    it "lists sandbox connectors with numeric ids" do
      connectors = client.connectors.list(sandbox: true)

      expect(connectors).not_to be_empty
      expect(connectors.first.id).to be_a(Integer)
      expect(connectors.first.name).to be_a(String)
    end

    it "reports health when asked" do
      connector = client.connectors.list(sandbox: true, health_details: true).first
      # health may legitimately be nil; only the shape is asserted.
      expect(connector.health&.status).to(satisfy { |s| s.nil? || s.is_a?(String) })
    end
  end

  describe "categories" do
    # The spec declares a bare array; its example shows a page envelope. This
    # records which one production actually sends.
    it "returns one of the two documented shapes" do
      list = client.categories.list

      warn "[smoke] GET /categories returned #{list.class.name.split("::").last}"
      expect(list.first.description).to be_a(String)
      expect(list).to respond_to(:auto_paging_each)
    end
  end

  describe "merchants" do
    it "buckets known, unknown and invalid CNPJs" do
      # Banco do Brasil's CNPJ, plus a deliberately invalid one.
      result = client.merchants.search(%w[00000000000191 1])

      expect(result.invalid).to include("1")
      expect(result.found + result.not_found).not_to be_empty
    end
  end

  describe "with PLUGGY_LIVE_ITEM_ID" do
    let(:item_id) { ENV.fetch("PLUGGY_LIVE_ITEM_ID", nil) }

    before { skip "set PLUGGY_LIVE_ITEM_ID to exercise a real connection" unless item_id }

    it "reads the item and its per-product sync state" do
      item = client.items.retrieve(item_id)

      warn "[smoke] item status=#{item["status"]} executionStatus=#{item["executionStatus"]}"
      expect(item.id).to eq(item_id)
      expect(item.connector.id).to be_a(Integer)
    end

    it "walks accounts, transactions and bills" do
      accounts = client.accounts.list(item_id: item_id)
      expect(accounts).not_to be_empty

      accounts.each do |account|
        expect(account.balance).to be_a(Numeric)

        sample = account.transactions.auto_paging_each.first(5)
        sample.each do |t|
          expect(t.amount).to be_a(Numeric)
          expect(t.date).to be_a(Time).or be_a(Date)
        end

        next unless account.credit?

        client.bills.list(account_id: account.id).each do |bill|
          # The property the whole bill.transactions design rests on.
          expect(bill.transactions.to_a).to all(satisfy { |t| t.bill_id == bill.id })
        end
      end
    end

    it "fetches a live balance, tolerating an unavailable institution" do
      account = client.accounts.list(item_id: item_id).first
      expect(client.accounts.balance(account.id).balance).to be_a(Numeric)
    rescue Pluggy::PermissionError, Pluggy::RateLimitError, Pluggy::BadGatewayError => e
      # All three are documented outcomes for this endpoint and belong to the
      # institution, not to us.
      skip "institution declined the live balance: #{e.message}"
    end

    # Records the drift documented in the README, from real data.
    it "reports Loan enum and field drift" do
      loans = client.loans.list(item_id: item_id)
      skip "no loans on this item" if loans.empty?

      loans.each do |loan|
        warn "[smoke] loan #{loan.id} CET=#{loan.cet.inspect} " \
             "periodicity=#{loan["installmentPeriodicity"].inspect} " \
             "taxType=#{loan.interest_rates&.first&.[]("taxType").inspect}"
        expect(loan.product_name).to be_a(String)
      end
    end
  end
end
