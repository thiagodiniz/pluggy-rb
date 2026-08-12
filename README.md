# pluggy-rb

An unofficial Ruby client for the [Pluggy](https://pluggy.ai) open-finance API, written by hand in the
style of [stripe-ruby](https://github.com/stripe/stripe-ruby).

It covers the read paths needed to **identify every transaction reachable from a connected item** —
accounts, transactions, credit-card bills, loans, connectors, items, categories and merchants — with
transparent API-key renewal, one uniform pagination interface over Pluggy's three different paging
shapes, and exact decimal money.

```ruby
client = Pluggy::Client.new(
  client_id: ENV["PLUGGY_CLIENT_ID"],
  client_secret: ENV["PLUGGY_CLIENT_SECRET"]
)

client.accounts.list(item_id: item_id).each do |account|
  puts "#{account.name}: #{account.balance} #{account.currency_code}"
end
```

## Installation

```ruby
gem "pluggy-rb"
```

Requires Ruby >= 3.1. The only runtime dependency is `bigdecimal` (see [Money](#money)).

## Authentication

Pluggy authentication is two steps, and the first one expires.

1. `POST /auth` with your client keys returns an **apiKey that lasts 2 hours**.
2. Every other endpoint takes that key as an `X-API-KEY` header.

**The SDK does all of this for you.** It authenticates lazily on your first request, caches the key until
the expiry inside the key's own JWT, and if Pluggy ever rejects it mid-session it renews and retries once —
so a long-running process never sees an expiry.

```ruby
client = Pluggy::Client.new(client_id: "...", client_secret: "...")
```

You can also set defaults that every new client inherits:

```ruby
Pluggy.configure do |c|
  c.client_id     = ENV["PLUGGY_CLIENT_ID"]
  c.client_secret = ENV["PLUGGY_CLIENT_SECRET"]
  c.logger        = Rails.logger
end

Pluggy::Client.new
```

### Bringing your own key

If you manage the apiKey yourself, pass it instead of credentials. There is then nothing to renew with, so
an expiry raises `Pluggy::AuthenticationError` telling you to supply credentials:

```ruby
Pluggy::Client.new(api_key: existing_key)
```

### Connect tokens are not API keys

`POST /connect_token` returns a **30-minute** token for the Connect Widget in your frontend. It cannot
authenticate API calls, and issuing one requires an apiKey — so it happens server-side.

```ruby
token = client.create_connect_token(
  options: { client_user_id: "user-42", webhook_url: "https://example.com/hooks/pluggy" }
)
render json: { accessToken: token.access_token }
```

Pass `item_id:` to let the widget update an existing connection instead of creating a new one.

## The four headline flows

### 1. Accounts for an item

```ruby
accounts = client.accounts.list(item_id: item_id)

accounts.each do |a|
  puts "#{a.type}/#{a.subtype} #{a.name} #{a.number} — #{a.balance} #{a.currency_code}"
end

checking = accounts.find(&:checking?)
card     = accounts.find(&:credit_card?)
```

`bank?`, `credit?`, `credit_card?`, `checking?` and `savings?` are all available. `type: "BANK"` or
`type: "CREDIT"` filters server-side.

### 2. Every transaction in a checking account

```ruby
checking.transactions(date_from: Date.new(2024, 1, 1)).auto_paging_each do |t|
  puts format("%s %10s  %s", t.date.strftime("%F"), t.amount, t.description)
end
```

`auto_paging_each` walks every page. Without a block it returns an `Enumerator`, so it stays lazy:

```ruby
checking.transactions.auto_paging_each.lazy.select(&:pending?).first(10)
```

### 3. A credit card's bills and each bill's line items

```ruby
client.bills.list(account_id: card.id).each do |bill|
  puts "closing #{bill.bill_closing_date} due #{bill.due_date}: " \
       "#{bill.total_amount} #{bill.total_amount_currency_code}#{' (paid)' if bill.paid?}"

  bill.transactions.each do |t|
    puts format("   %s %10s  %-40s %s",
                t.date.strftime("%F"), t.amount, t.description, t.installment_label)
  end
end
```

Bills carry no line items of their own — see [Bill line items](#bill-line-items) for how this works and
what it costs.

### 4. Loans

Loans hang off the **item**, not an account:

```ruby
client.loans.list(item_id: item_id).each do |loan|
  puts "#{loan.product_name} #{loan.contract_amount} CET=#{loan.cet}"
  puts "  #{loan.installments.paid_installments} paid, #{loan.installments.due_installments} due"
end
```

## Concepts

Items are connections to an institution. Accounts belong to items. Transactions belong to accounts. Bills
belong to `CREDIT` accounts. **Loans belong to items, not accounts.**

```ruby
item = client.items.retrieve(item_id)
item.accounts            # all of them
item.credit_accounts     # type: "CREDIT"
item.loans
item.transactions        # every transaction on every account, as one stream
```

## Gotchas

Most of these are Pluggy's, not the gem's, and the gem cannot paper over them.

### There is no `GET /items`

The API has no endpoint to list items, so **you must persist item ids yourself**, normally keyed by your
own `clientUserId`. `client.items` deliberately has no `list` method. This is the most common surprise for
people arriving from Plaid.

### Money

Amounts are parsed straight off the wire with `JSON.parse(body, decimal_class: BigDecimal)`, so a value
written `-212.45` becomes an exact `BigDecimal` and never passes through a Float. Whole numbers stay
`Integer`. Both are exact, which is the property that matters for reconciliation:

```ruby
bill.total_amount - bill.minimum_payment_amount   # exact, no float drift
```

This is why `bigdecimal` is a declared dependency: it became a *bundled* rather than *default* gem in
Ruby 3.4, so it has to be requested even though it ships with every Ruby. Set
`Pluggy.decimal_amounts = false` for plain Floats and a dependency-free install.

`to_json` round-trips correctly — BigDecimals are rendered as unquoted JSON numbers, not strings.

### Methods give you Ruby values; `[]` gives you the wire value

```ruby
t.date         # => 2024-03-15 00:00:00 UTC  (Time)
t[:date]       # => same
t["date"]      # => "2024-03-15T00:00:00.000Z"  (verbatim)
t["createdAt"] # => camelCase keys work too
t.to_h         # => wire-shaped hash
```

Date-only values like `bill.due_date` become `Date`. Values that only *look* temporal are left alone:
`bill_forecast_date` and `month_year` are `"2024-03"` and `"01-2025"`, so they stay Strings.

### Enum-ish fields are raw Strings, on purpose

The published spec and the live API disagree. Pluggy's own examples return `EFETIVA` where the schema says
`EFFECTIVE`, `MES` where it says `MONTH`, `UNICA` where it says `UNIQUE`. Modelling these as closed
constants would reject real data, so the gem never validates them — it only offers predicates
(`loan.financing?`, `t.pix?`, `item.updated?`) that compare strings.

Related: `LoanContractedFinanceCharge` is documented with `rate`/`additionalInfo` but sends
`chargeRate`/`chargeAdditionalInfo`; both spellings are readable, and `#charge_rate`/`#info` pick whichever
arrived. `Bill#accountId` and `BillFinanceCharge#creditCardBillId` are required by the schema yet missing
from its `properties` — they are present at runtime and readable.

### `loan.cet`

`CET` (Custo Efetivo Total) is the only uppercase field name in the API. All three of `loan.cet`,
`loan.CET` and `loan["CET"]` work.

## Pagination

Three shapes in the API, one interface in the gem: everything answers `each` and `auto_paging_each`.

| endpoint | shape | notes |
|---|---|---|
| `/v2/transactions` | cursor `{results, next}` | the only cursor-paginated endpoint |
| `/transactions` (v1) | offset `{results, page, total, totalPages}` | deprecated, accepts `page`/`pageSize` |
| `/connectors` | offset | accepts `page`/`pageSize` |
| `/accounts`, `/bills`, `/loans`, statements | offset | **single page** — no page parameter exists |
| `/categories` | array *or* offset | the spec contradicts itself; the gem sniffs the payload |

For `/accounts`, `/bills` and `/loans` the API returns a page envelope but documents no way to request
page 2, so `auto_paging_each` yields the one page and stops rather than re-requesting it.

### Resuming a cursor

Persist `next_token` — the whole query string Pluggy handed back, filters included — not a bare cursor:

```ruby
page = client.transactions.list(account_id: id)
redis.set("cursor:#{id}", page.next_token)

# later, in another process
page = client.transactions.resume(redis.get("cursor:#{id}"))
```

## Transactions: v2 vs v1

`GET /v2/transactions` is the default. `GET /transactions` is deprecated with a **2026-12-31 sunset**, and
is the only place `billId`, `page` and `pageSize` exist — passing any of them routes there automatically
and logs a deprecation notice.

```ruby
client.transactions.list(account_id: id, date_from: "2024-01-01")  # v2
client.transactions.list(account_id: id, bill_id: bill.id)         # v1, logged
client.transactions.list(account_id: id, version: :v1)             # v1, explicit
Pluggy.transactions_api_version = :v1                              # global default
```

v2 renamed `from`/`to` to `date_from`/`date_to`, and rejects `date_from` combined with `created_at_from`
(the gem catches that locally rather than spending a round-trip on a 400).

### Bill line items

v2 dropped the `billId` filter that v1 had, so there is no supported server-side way to list one bill's
transactions. `bill.transactions` lists the account's transactions over the statement cycle and filters on
`credit_card_metadata.bill_id`.

The window is derived, not guessed: `bills.list` sees every bill with its closing date, so each bill knows
its predecessor's, and the window is exactly one cycle. **The `billId` check is authoritative and always
runs, so the window only affects how many requests happen, never which transactions come back** — a wrong
window costs time, never correctness. A bill fetched alone via `bills.retrieve` has no predecessor and
falls back to a 62-day window, logging that fact.

```ruby
bill.transactions                                     # Enumerator; nothing fetched until iterated
bill.transactions.to_a
bill.transactions(date_from: "2024-01-01")            # override the window
bill.transactions(strategy: :legacy)                  # v1's server-side billId filter, one request
```

`transaction.bill_id` is public if you would rather group them yourself.

## Errors

All inherit from `Pluggy::Error` and carry the whole transcript: `http_status`, `http_body`, `json_body`,
`http_headers`, plus Pluggy's `code` and `code_description`. `message` appends the `code_description`
because that is what you want in a log; `api_message` is the undecorated text.

| class | when |
|---|---|
| `AuthenticationError` | bad client keys, or an apiKey that could not be renewed |
| `PermissionError` | a 403 **with** a `codeDescription`, e.g. `BALANCE_CONSENT_ERROR` |
| `InvalidRequestError` | 400 — `#parameter_errors`, `#invalid_cursor?` |
| `NotFoundError` | 404 |
| `ConflictError` | 409 — `#duplicate_item_ids` |
| `RateLimitError` | 429 — `#retry_after` |
| `APIError` / `BadGatewayError` | 500 / 502 (institution unavailable) |
| `ConnectionError` / `TimeoutError` | transport level |

Pluggy signals an expired apiKey with a **403 that has no `codeDescription`**, and a genuine denial with a
403 that has one. The gem renews only on the former; the latter raises `PermissionError` immediately,
un-retried.

GETs and DELETEs are retried on connection errors and 429/500/502/503/504 with exponential backoff and
jitter. **`POST /items` is never retried** — the API has no idempotency key, so a retry could open a
duplicate bank connection.

## Configuration

```ruby
Pluggy::Client.new(
  client_id: "...", client_secret: "...",
  read_timeout: 80,             # /accounts/{id}/balance queries the institution live
  max_network_retries: 2,
  logger: Rails.logger,         # secrets are redacted
  log_level: :info,             # :debug logs every request
  decimal_amounts: true,
  coerce_times: true,
  transactions_api_version: :v2
)
```

Connections are pooled per thread. After forking (Puma, Unicorn, Sidekiq), clear the inherited sockets:

```ruby
on_worker_boot { Pluggy::ConnectionManager.current.clear! }
```

## Out of scope

Payments, smart transfers, boletos, consents, webhooks, investments and identity are not modelled. Reach
them with the raw escape hatches, which handle auth and retries but return parsed JSON rather than
resource objects:

```ruby
client.get("/investments", item_id: item_id)
client.post("/payments/customers", name: "...")
```

## Development

```bash
mise install
bundle install
bundle exec rake                  # rubocop + rspec
bundle exec rake fixtures:extract # regenerate fixtures from the vendored OpenAPI spec
bundle exec rake "schema:fields[Transaction]"
```

The suite is hermetic (WebMock, no network). Fixtures are generated from Pluggy's own OpenAPI examples
where they exist and hand-written where they do not. To run the live smoke test against the real API:

```bash
PLUGGY_CLIENT_ID=... PLUGGY_CLIENT_SECRET=... bundle exec rspec --tag live
```

## License

MIT.
