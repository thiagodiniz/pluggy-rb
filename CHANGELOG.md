# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

Initial release.

### Added
- `Pluggy::Client` with transparent apiKey lifecycle: lazy first authentication, caching against the
  expiry in the key's own JWT, and one automatic renewal when Pluggy rejects a key mid-session.
- Resources: Account (+ live balance, statements), Transaction, Bill, Loan, Item, Connector, Category,
  Merchant, ConnectToken.
- One pagination interface (`each` / `auto_paging_each`) over the API's three envelope shapes, including
  cursor pagination for `GET /v2/transactions` and a runtime payload sniffer for `GET /categories`, whose
  schema and example disagree.
- `Bill#transactions`, which reconstructs a statement's line items from `creditCardMetadata.billId` using
  a window derived from the surrounding billing cycles, since `GET /v2/transactions` has no `billId`
  filter. `strategy: :legacy` uses the deprecated v1 filter instead.
- Exact money: JSON numbers are parsed with `decimal_class: BigDecimal` straight off the wire, and
  `to_json` renders them back as unquoted numbers.
- Navigation helpers (`item.accounts`, `account.transactions`, `item.transactions`, `bill.transactions`)
  and predicates (`account.credit_card?`, `transaction.pix?`, `item.waiting_user_input?`).
- Typed error hierarchy carrying the full HTTP transcript, distinguishing an expired apiKey (403 with no
  `codeDescription`) from a genuine denial (403 with one).

### Notes
- Payments, smart transfers, boletos, consents, webhooks, investments and identity are out of scope;
  `client.get`/`post`/`patch`/`delete` reach them directly.
- The API has no `GET /items`, so item ids must be persisted by the caller.
