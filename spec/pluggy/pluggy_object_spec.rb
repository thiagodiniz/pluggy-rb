# frozen_string_literal: true

RSpec.describe Pluggy::PluggyObject do
  describe Pluggy::Util do
    describe ".snake_case" do
      {
        "createdAt" => "created_at",
        "descriptionRaw" => "description_raw",
        "totalAmountCurrencyCode" => "total_amount_currency_code",
        "itemId" => "item_id",
        # Acronyms are the interesting cases.
        "CET" => "cet",
        "hasMFA" => "has_mfa",
        "payeeMCC" => "payee_mcc",
        "issuerCNPJ" => "issuer_cnpj",
        "routingNumberISPB" => "routing_number_ispb",
        "isOpenFinance" => "is_open_finance",
        "ipocCode" => "ipoc_code",
        "id" => "id"
      }.each do |wire, expected|
        it "converts #{wire.inspect} to #{expected.inspect}" do
          expect(described_class.snake_case(wire)).to eq(expected)
        end
      end
    end

    describe ".camel_case" do
      {
        "item_id" => "itemId",
        "account_id" => "accountId",
        "date_from" => "dateFrom",
        "created_at_from" => "createdAtFrom",
        "oauth_redirect_uri" => "oauthRedirectUri",
        "page_size" => "pageSize",
        "id" => "id"
      }.each do |ruby, expected|
        it "converts #{ruby.inspect} to #{expected.inspect}" do
          expect(described_class.camel_case(ruby)).to eq(expected)
        end
      end
    end

    describe ".encode_query" do
      it "camelizes symbol keys and drops nils" do
        query = described_class.encode_query(item_id: "i1", type: nil, account_id: "a1")
        expect(query).to eq("itemId=i1&accountId=a1")
      end

      it "passes string keys through verbatim, as the escape hatch" do
        expect(described_class.encode_query("weird_KEY" => "v")).to eq("weird_KEY=v")
      end

      it "comma-joins countries and types (style=form, explode=false)" do
        query = described_class.encode_query(countries: %w[BR], types: %w[PERSONAL_BANK BUSINESS_BANK])
        expect(query).to eq("countries=BR&types=PERSONAL_BANK%2CBUSINESS_BANK")
      end

      it "repeats ids rather than joining them" do
        expect(described_class.encode_query(ids: %w[a b])).to eq("ids=a&ids=b")
      end

      it "renders date-only params as yyyy-mm-dd even when given a Time" do
        query = described_class.encode_query(date_from: Time.utc(2024, 3, 15, 10, 30))
        expect(query).to eq("dateFrom=2024-03-15")
      end

      it "truncates a full timestamp passed to a date-only param" do
        expect(described_class.encode_query(date_to: "2024-03-15T10:30:00.000Z"))
          .to eq("dateTo=2024-03-15")
      end

      it "renders createdAtFrom with milliseconds" do
        query = described_class.encode_query(created_at_from: Time.utc(2024, 3, 15, 10, 30, 5))
        expect(query).to eq("createdAtFrom=2024-03-15T10%3A30%3A05.000Z")
      end

      it "skips empty arrays" do
        expect(described_class.encode_query(ids: [], item_id: "i1")).to eq("itemId=i1")
      end
    end

    describe ".encode_body" do
      it "camelizes nested symbol keys" do
        body = described_class.encode_body(
          { connector_id: 201, options: { client_user_id: "u1", webhook_url: "https://x" } }
        )
        expect(body).to eq(
          "connectorId" => 201,
          "options" => { "clientUserId" => "u1", "webhookUrl" => "https://x" }
        )
      end

      it "drops nil values" do
        expect(described_class.encode_body({ item_id: "i1", options: nil })).to eq("itemId" => "i1")
      end

      # Connector credential keys are institution-defined. Camelizing a
      # credential named "cpf_cnpj" into "cpfCnpj" would break item creation.
      it "leaves opaque maps' keys untouched" do
        body = described_class.encode_body(
          { connector_id: 201, parameters: { "cpf_cnpj" => "123", user: "u" } },
          opaque: %w[parameters]
        )
        expect(body["connectorId"]).to eq(201)
        expect(body["parameters"]).to eq("cpf_cnpj" => "123", "user" => "u")
      end

      it "accepts an encrypted string for parameters" do
        body = described_class.encode_body({ parameters: "encrypted-blob" }, opaque: %w[parameters])
        expect(body["parameters"]).to eq("encrypted-blob")
      end
    end
  end

  describe "the key-access convention" do
    subject(:txn) do
      Pluggy::Resources::Transaction.new(
        "id" => "t1",
        "date" => "2024-03-15T00:00:00.000Z",
        "createdAt" => "2024-03-16T02:00:00.000Z",
        "amount" => BigDecimal("-212.45"),
        "type" => "DEBIT"
      )
    end

    it "gives coerced values through readers" do
      expect(txn.date).to be_a(Time)
      expect(txn.created_at).to be_a(Time)
      expect(txn.amount).to be_a(BigDecimal)
    end

    it "gives coerced values through symbol keys" do
      expect(txn[:date]).to be_a(Time)
      expect(txn[:created_at]).to be_a(Time)
    end

    it "gives verbatim wire values through string keys" do
      expect(txn["date"]).to eq("2024-03-15T00:00:00.000Z")
      expect(txn["createdAt"]).to eq("2024-03-16T02:00:00.000Z")
    end

    it "accepts the snake_case spelling with a string key too" do
      expect(txn["created_at"]).to eq("2024-03-16T02:00:00.000Z")
    end

    it "returns nil for absent fields rather than raising" do
      expect(txn.description).to be_nil
      expect(txn.merchant).to be_nil
      expect(txn["nope"]).to be_nil
    end
  end

  describe "time coercion" do
    it "turns a date-only value into a Date, not a Time" do
      bill = Pluggy::Resources::Bill.new("dueDate" => "2024-04-10")
      expect(bill.due_date).to be_a(Date)
      expect(bill.due_date.to_s).to eq("2024-04-10")
    end

    # The traps: values that look date-ish but are not full dates.
    it "leaves billForecastDate ('2024-03') as a String" do
      meta = Pluggy::Resources::CreditCardMetadata.new("billForecastDate" => "2024-03")
      expect(meta.bill_forecast_date).to eq("2024-03")
    end

    it "leaves a statement's monthYear as a String" do
      expect(Pluggy::Resources::Statement.new("monthYear" => "2024-03").month_year).to eq("2024-03")
    end

    it "does not coerce a non-temporal field that happens to hold a date" do
      txn = Pluggy::Resources::Transaction.new("descriptionRaw" => "2024-03-15")
      expect(txn.description_raw).to eq("2024-03-15")
    end

    it "leaves a malformed date alone instead of raising" do
      txn = Pluggy::Resources::Transaction.new("date" => "not-a-date")
      expect(txn.date).to eq("not-a-date")
    end

    it "can be switched off" do
      Pluggy.coerce_times = false
      txn = Pluggy::Resources::Transaction.new("date" => "2024-03-15T00:00:00.000Z")
      expect(txn.date).to eq("2024-03-15T00:00:00.000Z")
    end

    it "can be switched off for one client without touching the globals" do
      stub_auth
      stub_pluggy(:get, "/transactions/t1", body: { "id" => "t1",
                                                    "date" => "2024-03-15T00:00:00.000Z" })

      raw = test_client(coerce_times: false).transactions.retrieve("t1")
      global = test_client.transactions.retrieve("t1")

      expect(raw.date).to eq("2024-03-15T00:00:00.000Z")
      expect(global.date).to be_a(Time)
    end
  end

  describe "nested conversion" do
    subject(:txn) { Pluggy::Resources::Transaction.new(fixture("transactions/retrieve")) }

    it "wraps nested hashes in their declared class" do
      rich = Pluggy::Resources::Transaction.new(
        "paymentData" => { "paymentMethod" => "PIX",
                           "receiver" => { "name" => "ACME",
                                           "documentNumber" => { "type" => "CNPJ", "value" => "1" } } }
      )
      expect(rich.payment_data).to be_a(Pluggy::Resources::PaymentData)
      expect(rich.payment_data.receiver).to be_a(Pluggy::Resources::PaymentParticipant)
      expect(rich.payment_data.receiver.document_number).to be_a(Pluggy::Resources::Document)
      expect(rich.payment_data.receiver.document_number).to be_cnpj
    end

    it "wraps arrays of hashes element by element" do
      bill = Pluggy::Resources::Bill.new(fixture("bills/retrieve"))
      expect(bill.finance_charges).to all(be_a(Pluggy::Resources::BillFinanceCharge))
      expect(bill.finance_charges.first.credit_card_bill_id).to be_a(String)
    end

    # Pluggy's own /bills/{id} example omits `payments` even though the schema
    # lists it as required -- one more reason absent fields must return nil
    # rather than raise.
    it "returns nil for a required field the API omits" do
      bill = Pluggy::Resources::Bill.new(fixture("bills/retrieve"))
      expect(bill.payments).to be_nil
      expect(bill.paid?).to be(false)
    end

    it "wraps payments when they are present" do
      bill = Pluggy::Resources::Bill.new(
        "totalAmount" => 100.0,
        "payments" => [{ "valueType" => "FULL_PAYMENT", "amount" => 100.0 }]
      )
      expect(bill.payments).to all(be_a(Pluggy::Resources::BillPayment))
      expect(bill.payments.first).to be_full
      expect(bill.paid?).to be(true)
    end

    it "leaves arrays of scalars alone" do
      item = Pluggy::Resources::Item.new("products" => %w[ACCOUNTS TRANSACTIONS])
      expect(item.products).to eq(%w[ACCOUNTS TRANSACTIONS])
    end

    it "falls back to a plain PluggyObject for undeclared nested hashes" do
      obj = Pluggy::PluggyObject.new("whatever" => { "deep" => { "value" => 1 } })
      expect(obj.whatever.deep.value).to eq(1)
    end

    it "parses the real fixture" do
      expect(txn.id).to eq("6ec156fe-e8ac-4d9a-a4b3-7770529ab01c")
      expect(txn).to be_debit
      expect(txn).to be_posted
    end
  end

  describe "the CET field" do
    subject(:loan) { Pluggy::Resources::Loan.new(fixture("loans/retrieve")) }

    # CET is the only non-lowercase-first property in the whole spec. snake_case
    # turns it into a plain reader, so there is nothing to apologise for.
    it "is reachable as #cet" do
      expect(loan.cet).to eq(0.29)
    end

    it "is reachable as #CET, matching Pluggy's own docs" do
      expect(loan.CET).to eq(0.29)
    end

    it 'is reachable as ["CET"]' do
      expect(loan["CET"]).to eq(0.29)
    end
  end

  # The spec declares these enums in English; the live API returns Portuguese.
  # Modelling them as closed constants would reject real data.
  describe "enum drift on Loan" do
    subject(:loan) { Pluggy::Resources::Loan.new(fixture("loans/retrieve")) }

    it "keeps Portuguese interest-rate values verbatim" do
      rate = loan.interest_rates.first
      expect(rate.tax_type).to eq("EFETIVA")
      expect(rate.interest_rate_type).to eq("SIMPLES")
      expect(rate.tax_periodicity).to eq("AA")
    end

    it "keeps Portuguese fee values verbatim" do
      fee = loan.contracted_fees.first
      expect(fee.charge_type).to eq("UNICA")
      expect(fee.charge).to eq("MINIMO")
    end

    it "keeps Portuguese installment periodicity verbatim" do
      expect(loan.installments.type_number_of_installments).to eq("MES")
    end

    # The schema says additionalInfo/rate; the API sends chargeAdditionalInfo/chargeRate.
    it "reads finance charges under either spelling" do
      charge = loan.contracted_finance_charges.first
      expect(charge.charge_rate).to eq(0.07)
      expect(charge.info).to eq("")
    end
  end

  describe "#to_h and #to_json" do
    subject(:txn) { Pluggy::Resources::Transaction.new(payload) }

    let(:payload) { fixture("transactions/retrieve") }

    it "flattens nested objects back to plain hashes" do
      rich = Pluggy::Resources::Transaction.new("merchant" => { "name" => "ACME" })
      expect(rich.to_h).to eq("merchant" => { "name" => "ACME" })
    end

    # JSON.generate renders a BigDecimal as a quoted string, which would break
    # round-tripping. RawNumber fixes that.
    it "renders BigDecimal amounts as unquoted JSON numbers" do
      expect(txn.to_json).to include('"amount":-212.45')
      expect(txn.to_json).not_to include('"amount":"')
    end

    it "round-trips the fixture" do
      expect(JSON.parse(txn.to_json)).to eq(payload)
    end

    it "round-trips through another PluggyObject" do
      again = Pluggy::Resources::Transaction.new(JSON.parse(txn.to_json))
      expect(again.amount.to_f).to eq(txn.amount.to_f)
      expect(again.date).to eq(txn.date)
    end
  end

  describe "unknown and reserved fields" do
    it "keeps fields the spec never declared" do
      # Bill#accountId is required-but-undeclared in the schema.
      bill = Pluggy::Resources::Bill.new("accountId" => "acc-1")
      expect(bill.account_id).to eq("acc-1")
    end

    it "reaches brand-new fields through method_missing" do
      obj = Pluggy::PluggyObject.new("somethingPluggyAddedLater" => 42)
      expect(obj.something_pluggy_added_later).to eq(42)
      expect(obj).to respond_to(:something_pluggy_added_later)
    end

    it "raises NoMethodError for a field that is genuinely absent" do
      expect { Pluggy::PluggyObject.new({}).nope }.to raise_error(NoMethodError)
    end

    # This is why PluggyObject does not include Enumerable.
    it "does not let Enumerable#count shadow ICountResponse#count" do
      expect(Pluggy::Resources::Count.new("count" => 3).count).to eq(3)
    end

    it "does not clobber to_h with an API field named to_h" do
      obj = Pluggy::PluggyObject.new("to_h" => "nope")
      expect(obj.to_h).to be_a(Hash)
      expect(obj["to_h"]).to eq("nope")
    end
  end

  describe "equality and inspect" do
    it "compares by class and wire payload" do
      a = Pluggy::Resources::Transaction.new("id" => "t1")
      b = Pluggy::Resources::Transaction.new("id" => "t1")
      c = Pluggy::Resources::Transaction.new("id" => "t2")

      expect(a).to eq(b)
      expect(a).not_to eq(c)
      expect(a.hash).to eq(b.hash)
    end

    it "does not equate different resource types with the same payload" do
      expect(Pluggy::Resources::Transaction.new("id" => "x"))
        .not_to eq(Pluggy::Resources::Account.new("id" => "x"))
    end

    it "shows the id and the field names" do
      expect(Pluggy::Resources::Transaction.new("id" => "t1", "amount" => 1).inspect)
        .to eq("#<Pluggy::Resources::Transaction:t1 id amount>")
    end
  end

  describe "navigation without a client" do
    it "explains itself instead of raising NoMethodError on nil" do
      account = Pluggy::Resources::Account.new("id" => "a1", "itemId" => "i1")

      expect { account.transactions }.to raise_error(Pluggy::Error, /needs a client/)
    end
  end
end
