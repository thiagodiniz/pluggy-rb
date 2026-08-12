# Fixtures

Two kinds of file live here, and CI treats them differently.

## Generated

Produced by `bundle exec rake fixtures:extract`, which reads the vendored spec at
`spec/support/openapi/pluggy-oas3.json` and writes out each operation's own `example` block. Generating
rather than hand-writing keeps them honest and makes a payload change visible in review. They are
committed so the suite never has to parse the 525KB spec, and CI re-runs the generator and fails on a
diff.

Do not edit these by hand — change the generator, or the vendored spec, instead.

```
accounts/{list,retrieve_bank,retrieve_credit,balance,statements}.json
transactions/{v1_list,v2_list}.json
bills/{list,retrieve}.json
loans/{list,retrieve}.json
categories/list_envelope.json
merchants/search.json
```

`accounts/retrieve_bank` and `retrieve_credit` come from the two named examples the spec ships for
`GET /accounts/{id}` — the `bankData` and `creditData` shapes.

## Hand-written

Eight endpoints in scope ship no example at all (`/auth`, `/connect_token`, `/connectors`,
`/connectors/{id}`, `/items`, `/items/{id}`, `/transactions/{id}`, `/categories/{id}`), and the error
bodies are only shown inline in the spec's prose. Those are written by hand.

Several of them exist specifically to pin down places where the spec and the live API disagree — they are
the regression suite for the trickiest behaviour in the gem:

| fixture | what it pins |
|---|---|
| `errors/403_expired.json` | 403 with **no** `codeDescription` → an expired apiKey → renew and retry |
| `errors/403_balance_consent.json` | 403 **with** `codeDescription` → a real denial → never renew, never retry |
| `errors/400_item_validation.json` | uses `details`, which is what the spec's examples emit, not the `errors` its schema declares |
| `errors/409_duplicate.json` | carries `items` and omits `code` entirely |
| `transactions/v2_list_plus_cursor.json` | a `+` inside the cursor, which must survive to the wire un-decoded |
| `transactions/v2_list_last_page.json` | `next: null`, terminating cursor pagination |
| `categories/list_array.json` | the bare-array shape the schema declares (derived from `list_envelope`) |
| `loans/retrieve.json` *(generated)* | `CET`, and Portuguese enums (`EFETIVA`, `MES`, `UNICA`) where the schema says English |
