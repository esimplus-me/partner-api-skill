---
name: partner-api-skill
description: >
  Integrate the eSIM Plus Partner API (`https://api.esimplus.net/api/partner/v1`) — bearer
  auth with a `partner:api` token, browse the virtual-number catalog, buy numbers one at a
  time or in bulk, quote an order before placing it, tag numbers, read inbound SMS, run the
  wallet, and receive/verify signed webhooks (`sms.inbound`, `wallet.topped_up`,
  `numbers.bulk_completed`). Use when the user is writing, reviewing, or debugging client
  code against eSIM Plus / esimplus.net partner endpoints — buying virtual phone numbers,
  polling a bulk order, mapping partner error codes (1301–1329), verifying an
  `X-Esimplus-Signature` header, reconciling wallet amounts, or generating a client from the
  partner OpenAPI spec. Also use for "eSIM Plus API", "partner API token", "esimplus
  webhook", and Russian equivalents ("партнёрский API", "купить виртуальный номер",
  "вебхук esimplus").
license: MIT
---

# eSIM Plus Partner API integration

Build a correct client against the eSIM Plus Partner API. The surface is small, but four
things about it defy the obvious assumption and cause almost every integration bug: there
are **two different error envelopes**, buying is **not idempotent**, bulk purchase is
**asynchronous and partially successful by design**, and money arrives in **two
representations at once** (rounded integers plus exact decimal strings). This skill carries
the as-built contract so you do not have to guess any of it.

## Contents
- The house rule: the host project's architecture wins
- Basics you must assume
- Workflow
- Gotchas
- References

## The house rule: the host project's architecture wins

This skill knows the API. It does **not** know how the surrounding codebase is built — and
that codebase, not this skill, decides the shape of the integration. Before writing code,
read how the project already talks to a third-party HTTP API and follow **that**: its client
layer, its config/secrets mechanism, its error type, its logging, its retry policy, its
folder layout, its naming and its test style. Adapt the examples here to those conventions.

Non-negotiable, in order of precedence: the project's own `CLAUDE.md` / `AGENTS.md` /
contributing docs and lint rules → the patterns already present in its code → this skill's
examples. Never introduce a new HTTP library, a new config pattern, a new error hierarchy or
a new directory just because a snippet here used one. If the project has no such pattern
yet, propose one in its existing idiom and say so explicitly.

Two things are exempt, because they are the API's contract rather than a style choice: the
wire-level facts in this skill (paths, field names, envelopes, `Idempotency-Key`, the
signature algorithm, `perPage <= 50`) and the safety rules in *Gotchas* — those hold in every
architecture. Where a project convention would break one of them (for example a global
"retry every failed request" wrapper against the non-idempotent buy endpoint), do not silently
comply and do not silently override: flag the conflict, and carve out the narrowest possible
exception.

Load `references/host-architecture.md` for the discovery procedure to run before step 1.

## Basics you must assume

- **Base URL:** `https://api.esimplus.net/api/partner/v1`. Every path below is relative to it.
- **Auth:** `Authorization: Bearer <token>` where the token is a long-lived `partner:api`
  integration token created in the partner dashboard (Settings → API tokens; the plaintext
  is shown **once**). The legacy header `X-API-TOKEN: <token>` is still accepted for
  `partner:api` tokens, but never carries the optional upstream-provider add-on ability —
  use `Authorization`.
- **JSON:** requests and responses are `application/json`, response keys are **camelCase**.
  Outbound webhook bodies are the one exception: **snake_case**.
- **Success wrapper:** every success body is `{ "data": <payload> }`. Lists add a sibling
  `pagination`: `{ "page", "perPage", "hasMore" }` — offset paging, **no `total`**.
  `page` default 1, `perPage` default 30, **max 50**. `DELETE` returns `204` with an empty body.
- **Rate limits (per partner, per minute):** 60 general (shared by everything), 10 buy,
  5 bulk-buy, 30 quote, 10 top-up. A `429` is Envelope B — back off and retry; nothing failed.

## Workflow

Follow this order when building or reviewing an integration. Copy the checklist and tick it.

```
- [ ] 0. Map the host project's conventions and place the integration inside them
- [ ] 1. Confirm the token works and which abilities it carries (scripts/probe_api.py)
- [ ] 2. Model both error envelopes before writing any endpoint call
- [ ] 3. Implement the read path (catalog, owned numbers, SMS) with `perPage <= 50` paging
- [ ] 4. Implement the buy path — single buy (never auto-retried) or bulk (quote → accept → poll)
- [ ] 5. Wire webhooks: verify the signature over the RAW body, dedupe by event id
- [ ] 6. Reconcile money off the *Decimal string fields, never the rounded integers
```

0. **Map the host project first.** Find its existing outbound-HTTP integration and mirror
   it: client construction, base-URL/secret handling, error translation, retry/timeout
   policy, serialization, logging, DI/wiring, tests. State in one or two sentences which
   files you are following and where the new code will live *before* writing it — that
   sentence is what keeps the integration from becoming a foreign body. Procedure and a
   per-stack checklist: `references/host-architecture.md`.

1. **Verify the token first.** Run the probe before writing code — it separates "wrong
   token" from "wrong request" once, instead of at every endpoint:

   ```bash
   python3 scripts/probe_api.py --token "$ESIMPLUS_PARTNER_TOKEN"
   ```

   Exit 0 = the token authenticates; the report lists which endpoint groups it can reach.
   Exit 2 = auth failed (see the printed code); exit 3 = the API was unreachable. Pass
   `--base-url` only if the partner was given a non-production host.

2. **Model the errors before the endpoints.** Dispatch on the domain `code`, never on the
   HTTP status — one status carries several codes, and `422` sometimes has no code at all.
   Load `references/errors.md` and build the mapping from its table.

3. **Read paths.** `GET /phone-numbers/countries` → `.../countries/{iso}/catalog` →
   `POST /phone-numbers` (buy) → `GET /phone-numbers` (owned) → `GET /sms`. Shapes and every
   query parameter are in `references/endpoints.md`.

4. **Buy paths.** One number: `POST /phone-numbers` with `{ "msisdn": "…" }`. Many numbers:
   `POST /phone-numbers/quote` to price the draft, `POST /phone-numbers/bulk` with a required
   `Idempotency-Key` header, then poll `GET /phone-numbers/bulk/{orderId}` to a terminal
   status. Load `references/bulk-and-pricing.md` — the caps, the polling ladder, and the
   discount rules there are not derivable from the endpoint shapes.

5. **Webhooks.** Load `references/webhooks.md`. Verify with the bundled script against its
   built-in test vector before pointing it at real traffic:

   ```bash
   python3 scripts/verify_webhook.py --self-test
   ```

6. **Money.** `references/endpoints.md` §Wallet. The rule in one line: render and reconcile
   from the `*Decimal` / `amountDecimal` strings; the integer cent fields are a rounded
   back-compat projection.

Generate a typed client from `assets/partner-api.openapi.yaml` (OpenAPI 3.1) when the
language has a good generator — it covers catalog, numbers, bulk, quote, tags and SMS.
Wallet, profile and discount-levels are **not** in that file; hand-write them from
`references/endpoints.md`.

## Gotchas

These are the traps that have actually broken integrations. None is guessable from the spec.

- **Array query params need PHP bracket notation.** The backend is Laravel:
  `?tags[]=2&tags[]=1` populates the array, while the OpenAPI-standard repeated form
  `?tags=2&tags=1` collapses to the last scalar and 422s with "The tags must be an array."
  Most generated clients emit the wrong form by default — override the query serializer.
- **`POST /phone-numbers` is NOT idempotent.** A retry after a timeout can buy a *second*
  number and charge for it. Never put it behind an automatic retry/backoff wrapper. Only
  `POST /phone-numbers/bulk` has an idempotency key.
- **A `202` from the bulk endpoint means "queued", never "affordable" and never "bought".**
  The funds check at acceptance reserves nothing, so individual slots can still fail with
  `1315` mid-run. Partial success is the normal outcome, not an error state.
- **`202` is also not a promise of quantity.** The upstream catalog sources at most ~100
  distinct numbers per country/type per run, so one line never delivers more than that
  however much is requested — reaching 500 needs five or more country/type lines.
- **A whole amount serialises as an integer.** PHP emits `3`, not `3.0`, so `price.amount`
  is `3` at $3.00 and `2.1` at $2.10. A strictly typed `int` field, or a decoder that
  rejects `2.1`, breaks in production. Decode every `amount` as a float/number.
- **Catalog `price` is the list price; `discountedPrice` is what you are charged.** An
  affordability check must compare `discountedPrice ?? price` against
  `wallet.availableBalance`. Do not recompute the discount client-side — the server
  quantises in integer micros and your arithmetic will disagree at tier boundaries.
- **`discountedPrice`, `discountPercent`, `baseAmount` are `null`, not `0`, when no
  discount applied.** `null` means "no discount information"; `0` means "a rate of zero was
  applied". They are different facts and nothing is backfilled.
- **The `features` filter value is `"SMS"` (uppercase) but responses emit `"sms"`
  (lowercase).** The asymmetry is deliberate; do not "normalise" it away.
- **Owned-number `status` is an integer, and only `1` (active), `3` (pending), `4`
  (released) ever surface.** `gracePeriodEndsAt` is non-null only when `status == 4`.
- **Two unrelated grace periods.** Release grace (`status == 4` + `gracePeriodEndsAt`,
  14 days) is not payment grace (`billingState == "grace"` + `billingGraceEndsAt`, 10 days,
  on a number that keeps `status == 1`).
- **`GET /phone-numbers/bulk/{orderId}` 404s identically for an unknown order and for
  another partner's order** (`1329`) — it is not an existence oracle.
- **Bulk counters are whole-order; `items[]` is one page.** Never sum `items[]` to build
  totals. `requested == succeeded + failed + pending` always holds.
- **The wallet is credited by the payment callback, not by the browser returning to
  `successUrl`.** Credit only when `GET /wallet/topups/{id}` reports `status: "completed"`.
- **`X-Esimplus-Signature` is computed over `{timestamp}.{raw_body}`.** Re-serialising the
  parsed JSON changes bytes and the comparison fails — capture the raw body in your
  framework before any body parser touches it.
- **A `partner:api` token cannot reach `/settings/*` or `DELETE /auth/session`** → `403`
  code `1327`. Those are dashboard-session-only. Token and webhook management is a dashboard
  action, not an API one.

## References

- `references/host-architecture.md` — how to discover and honour the host project's
  architecture, and the conflicts worth escalating. Load it in step 0, before any code.
- `references/endpoints.md` — every endpoint, request/response shape, query parameter and
  enum. Load it when writing or reviewing a specific call.
- `references/errors.md` — the two envelopes, the full `1301–1329` code table, and a
  per-endpoint dispatch matrix. Load it in step 2 and whenever handling a failure.
- `references/bulk-and-pricing.md` — bulk purchase, quoting, the discount ladder, wallet
  money semantics. Load it before implementing multi-number purchase or any pricing display.
- `references/webhooks.md` — delivery, signature verification in JS/Python/PHP, retry
  schedule, idempotency. Load it when receiving webhooks.
- `assets/partner-api.openapi.yaml` — OpenAPI 3.1 spec for the integration surface; feed it
  to a client generator.
