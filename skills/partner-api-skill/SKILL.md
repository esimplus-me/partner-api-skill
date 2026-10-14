---
name: partner-api-skill
description: >
  Integrate the eSIM Plus Partner API (`https://api.esimplus.net/api/partner/v1`) — bearer
  auth with a scoped `esp_live_…` token, the virtual-number catalog, single and bulk purchase,
  quoting, outbound and inbound SMS, the eSIM plane (offers, bulk, usage, PIN/PUK,
  balance top-ups), tags, the wallet, and signed webhooks (`sms.inbound`, `sms.outbound.*`,
  `wallet.topped_up`, `esim.topped_up`, `numbers.bulk_completed`, `esims.bulk_completed`). Use
  when writing or debugging client code against eSIM Plus / esimplus.net partner endpoints —
  buying numbers or eSIMs, sending an SMS, polling a bulk order, mapping error codes
  1301–1363, resolving a missing-scope 403 (1362) or an expired/paused token (1360/1361),
  verifying `X-Esimplus-Signature`, or generating a client from the OpenAPI spec. Also for
  "eSIM Plus API", "partner API token", "partner API scopes", "esimplus webhook", and Russian
  equivalents ("партнёрский API", "купить виртуальный номер", "вебхук esimplus").
license: MIT
---

# eSIM Plus Partner API integration

Build a correct client against the eSIM Plus Partner API. The surface covers three products —
virtual numbers, outbound/inbound SMS, and eSIM profiles — on one wallet and one
tag plane. Six things about it defy the obvious assumption and cause almost every integration
bug: there are **two different error envelopes**, every route now demands a **scope on the
token**, buying is **not idempotent** (on either product), bulk purchase is **asynchronous and
partially successful by design**, money arrives in **two representations at once** (rounded
integers plus exact decimal strings), and a partner keeps a **list** of webhook endpoints that
each subscribe explicitly — so a new event reaches nobody until it is ticked. This skill
carries the as-built contract so you do not have to guess any of it.

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
wire-level facts in this skill (paths, field names, envelopes, scopes, `Idempotency-Key`, the
signature algorithm, `perPage <= 50`) and the safety rules in *Gotchas* — those hold in every
architecture. Where a project convention would break one of them (for example a global
"retry every failed request" wrapper against the non-idempotent buy endpoints), do not silently
comply and do not silently override: flag the conflict, and carve out the narrowest possible
exception.

Load `references/host-architecture.md` for the discovery procedure to run before step 1.

## Basics you must assume

- **Base URL:** `https://api.esimplus.net/api/partner/v1`. Every path below is relative to it.
- **Auth:** `Authorization: Bearer <token>`. An integration token is the literal `esp_live_`
  plus 40 random characters (49 in all); its first 13 characters are the non-secret `prefix`
  that identifies it in a log. The plaintext is shown **once**, at creation or rotation, in
  the partner dashboard (Settings → API tokens). Pre-V2 tokens (`{id}|…`) still work. The
  legacy header `X-API-TOKEN: <token>` is still accepted but is **not scope-enforced** and
  never carries the optional upstream-provider add-on — use `Authorization`.
- **Scopes:** every integration route declares one (`numbers:read`, `sms:send`, `esim:write`,
  …). A token missing it gets `403`/`1362`, and the message names the scope. A token can also
  be **expired** (`401`/`1360`) or **paused** (`401`/`1361`). All three are permanent until a
  human acts in the dashboard — never retry them. Full map: `references/auth-and-scopes.md`.
- **JSON:** requests and responses are `application/json`, response keys are **camelCase**.
  Outbound webhook bodies are the one exception: **snake_case**.
- **Success wrapper:** every success body is `{ "data": <payload> }`. Lists add a sibling
  `pagination`: `{ "page", "perPage", "hasMore" }` — offset paging, **no `total`**.
  `page` default 1, `perPage` default 30, **max 50**. `DELETE` returns `204` with an empty body.
- **Rate limits (per partner, per minute):** 60 general (shared by everything), 10 buy
  (shared by `POST /phone-numbers` **and** `POST /esims`), 5 bulk-buy (shared by both bulk
  endpoints), 30 number-quote, 60 SMS send, 120 SMS quote, 5 eSIM credential reveals, 10
  top-up (wallet **and** eSIM). A `429` is Envelope B — back off and retry; nothing failed.
  It carries **no `Retry-After` and no `X-RateLimit-*`**, so the backoff schedule is yours.

## Workflow

Follow this order when building or reviewing an integration. Copy the checklist and tick it.

```
- [ ] 0. Map the host project's conventions and place the integration inside them
- [ ] 1. Confirm the token works and which scopes it carries (scripts/probe_api.py)
- [ ] 2. Model both error envelopes before writing any endpoint call
- [ ] 3. Implement the read path (catalog, owned numbers/eSIMs, SMS) with `perPage <= 50` paging
- [ ] 4. Implement the buy paths — single buy (never auto-retried) or bulk (quote → accept → poll)
- [ ] 5. Implement outbound SMS if needed: quote → send with a REQUIRED Idempotency-Key
- [ ] 6. Wire webhooks: verify against the RIGHT endpoint's secret, dedupe by (id, event)
- [ ] 7. Reconcile money off the *Decimal string fields, never the rounded integers
```

0. **Map the host project first.** Find its existing outbound-HTTP integration and mirror
   it: client construction, base-URL/secret handling, error translation, retry/timeout
   policy, serialization, logging, DI/wiring, tests. State in one or two sentences which
   files you are following and where the new code will live *before* writing it — that
   sentence is what keeps the integration from becoming a foreign body. Procedure and a
   per-stack checklist: `references/host-architecture.md`.

1. **Verify the token and its scopes first.** Run the probe before writing code — it
   separates "wrong token", "missing scope" and "wrong request" once, instead of at every
   endpoint:

   ```bash
   python3 scripts/probe_api.py --token "$ESIMPLUS_PARTNER_TOKEN"
   ```

   Exit 0 = the token authenticates; the report lists which endpoint groups it can reach and
   which answered `1362` (scope missing). Exit 2 = auth failed, including an expired (`1360`)
   or paused (`1361`) token; exit 3 = the API was unreachable. Pass `--base-url` only if the
   partner was given a non-production host.

2. **Model the errors before the endpoints.** Dispatch on the domain `code`, never on the
   HTTP status — one status carries several codes, and `422` sometimes has no code at all.
   Load `references/errors.md` and build the mapping from its table.

3. **Read paths.** Numbers: `GET /phone-numbers/countries` → `.../countries/{iso}/catalog` →
   `GET /phone-numbers` (owned) → `GET /phone-numbers/{sid}` → `GET /sms`. eSIMs:
   `GET /esims/destinations` → `.../destinations/{code}/catalog` → `GET /esims` →
   `GET /esims/{icc}`. Shapes and every query parameter are in `references/endpoints.md` and
   `references/esim.md`.

4. **Buy paths.** One number: `POST /phone-numbers` with `{ "msisdn": "…" }`. One eSIM:
   `POST /esims` with `{ "offerId", "prepaidPackage" }` — the package is **mandatory**. Many:
   `POST /phone-numbers/quote` to price the draft, then `POST /phone-numbers/bulk` or
   `POST /esims/bulk` with a required `Idempotency-Key`, then poll the matching
   `GET …/bulk/{orderId}` to a terminal status. Load `references/bulk-and-pricing.md` for
   numbers and `references/esim.md` for eSIMs — the caps, the polling ladder and the discount
   rules there are not derivable from the endpoint shapes.

5. **Outbound SMS.** `POST /sms/quote` to price, `POST /sms` to send with a **required**
   `Idempotency-Key`; `202` means queued, not delivered. Load `references/outbound-sms.md`
   before writing a segment counter or a price display — both have traps that only show up on
   non-Latin text and sub-cent rates.

6. **Webhooks.** Load `references/webhooks.md`. A partner now has a **list** of endpoints,
   each with its own secret and its own explicit event subscription. Verify with the bundled
   script against its built-in test vector before pointing it at real traffic:

   ```bash
   python3 scripts/verify_webhook.py --self-test
   ```

7. **Money.** `references/endpoints.md` §Wallet, plus §Money in `references/outbound-sms.md`
   and §The two balances in `references/esim.md`. The rule in one line: render and reconcile
   from the `*Decimal` / `amountDecimal` strings; the integer cent and `*Minor` fields are a
   rounded projection.

Generate a typed client from `assets/partner-api.openapi.yaml` (OpenAPI 3.1) when the
language has a good generator — it covers catalog, numbers, bulk, quote, tags, SMS (both
directions) and the eSIM plane. Wallet, profile, discount-levels and the dashboard-only
`/settings/*` routes are **not** in that file; hand-write them from `references/endpoints.md`
and `references/auth-and-scopes.md`.

## Gotchas

These are the traps that have actually broken integrations. None is guessable from the spec.

### Requests and auth

- **Array query params need PHP bracket notation.** The backend is Laravel:
  `?tags[]=2&tags[]=1` populates the array, while the OpenAPI-standard repeated form
  `?tags=2&tags=1` collapses to the last scalar and 422s with "The tags must be an array."
  Most generated clients emit the wrong form by default — override the query serializer.
  Same for `country[]` on `GET /esims`.
- **`1360` / `1361` / `1362` are not transient.** An expired token, a paused token and a
  missing scope are permanent until someone acts in the dashboard. A generic backoff wrapper
  loops forever on them. Alert an operator instead.
- **A new scope or a new event reaches no existing token or endpoint.** Both are stored as
  explicit lists with no wildcard, so adding a capability server-side changes nothing for an
  existing integration until a human ticks it.

### Buying

- **`POST /phone-numbers` and `POST /esims` are NOT idempotent.** A retry after a timeout can
  buy a *second* item and charge for it. Never put either behind an automatic retry/backoff
  wrapper. `POST /esims` additionally **ignores** an `Idempotency-Key` rather than honouring
  it — sending one buys a second profile while looking like it did not.
- **A `202` from a bulk endpoint means "queued", never "affordable" and never "bought".**
  The funds check at acceptance reserves nothing, so individual slots can still fail with
  `1315` mid-run. Partial success is the normal outcome, not an error state.
- **`202` is also not a promise of quantity.** For numbers, the upstream catalog sources at
  most ~100 distinct numbers per country/type per run, so one line never delivers more than
  that however much is requested.
- **The two bulk planes have different caps and different 404 codes.** Numbers: Σ ≤ 500, ≤ 100
  per line, unknown order → `1329`. eSIMs: ≤ 10 lines, ≤ 50 per line, Σ ≤ 100, unknown order →
  `1348`.
- **An eSIM is always sold funded.** `prepaidPackage` is required on `POST /esims` and on
  **every** bulk line, the wallet is debited `offer.price + package.price` as one charge, and
  the SIM is delivered carrying `package.price`. The package ladder is resolved **against the
  offer** — `pp-3` is $23.00 single-number and $25.00 dual-number. Render `price`, send
  `code`, compute neither.
- **A fresh eSIM is `pending` with `activation: null`.** There is no activation webhook;
  re-read `GET /esims/{icc}`.

### Money and pricing

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
- **There are no discounts on the eSIM plane at all** — the keys are *absent*, not null. Do
  not render an undiscounted figure as a failed-to-load discount.
- **`totalPriceMinor` is not `unitPriceMinor × segments`.** Both are roundings of exact
  values and the total is projected from the exact decimal. Multiplying overstates a sub-cent
  SMS invoice by up to 100 %. Likewise `priceMinor` on a sent message is a rounding of what
  was charged, not the charge.
- **A partner holds two separate monies on the eSIM plane.** The wallet buys inventory; each
  SIM's own balance pays for calls and traffic. They never net, and **deleting a SIM forfeits
  its balance** — it does not return to the wallet.

### Reading

- **The `features` filter value is `"SMS"` (uppercase) but responses emit `"sms"`
  (lowercase).** The asymmetry is deliberate; do not "normalise" it away.
- **Owned-number `status` is an integer** (`1` active, `3` pending, `4` released) **while
  `EsimStatus` is a string** (`pending`/`active`/`suspended`/`deleted`). Two products, two
  conventions.
- **Two unrelated grace periods on a number.** Release grace (`status == 4` +
  `gracePeriodEndsAt`, 14 days) is not payment grace (`billingState == "grace"` +
  `billingGraceEndsAt`, 10 days, on a number that keeps `status == 1`).
- **`GET /phone-numbers` emits `msisdn` as bare digits; every SMS surface emits `from`/`to`
  as E.164 with `+`.** Compare by digits — a `===` on the two strings rejects every number
  the partner owns. `POST /sms` accepts either spelling.
- **`GET /sms` lists both directions now.** Outbound-only fields are **absent, not `null`**,
  when they do not apply — test for presence. `receivedAt` is the one sortable time field for
  both directions and means "when the platform recorded this message".
- **`SmsStatus` and `SmsBlockedReason` are published wider than they are produced.** Build
  for all six statuses; expect `queued`, `sent`, `delivered`, `failed`. Nothing is blocked
  today.
- **Bulk counters are whole-order; `items[]` is one page.** Never sum `items[]` to build
  totals. `requested == succeeded + failed + pending` always holds. The same rule applies to
  eSIM usage: render `summary`, never the sum of `data[]`.
- **`GET /esims/{icc}/usage` is voice-only and account-wide upstream.** `data` and `sms`
  buckets report real zeros, and every page costs one account-wide provider call — do not
  poll it. `from` defaults to 30 days ago, so omitting it is not "all time".
- **`GET …/bulk/{orderId}` 404s identically for an unknown order and for another partner's
  order** — it is not an existence oracle. So does an unowned `from` on `POST /sms` (`1311`).

### Webhooks

- **The wallet is credited by the payment callback, not by the browser returning to
  `successUrl`.** Credit only when `GET /wallet/topups/{id}` (or `GET /esims/{icc}/topups`)
  reports `status: "completed"`.
- **`X-Esimplus-Signature` is computed over `{timestamp}.{raw_body}`** with the secret of
  **the endpoint that received the request** — a partner may have several. Re-serialising the
  parsed JSON changes bytes and the comparison fails; capture the raw body in your framework
  before any body parser touches it.
- **Dedupe `sms.outbound.*` on `(id, event)`, never on `id` alone.** All three lifecycle
  events carry the same message id, so an `id`-only dedupe discards `delivered` as a repeat
  of `sent` and never learns the message arrived.
- **A missing `sms.outbound.delivered` is not a failure.** Some providers send no receipt at
  all, there is no DLR timeout, and a message with no receipt stays `sent` forever. Never
  invent a client-side timeout that reports delivery failure.
- **A post-hand-off `failed` is charged**, unlike a pre-hand-off one which is released.

### Dashboard-only surface

- **A `partner:api` token cannot reach the dashboard-session routes** → `403` code `1327`.
  Three families: `/settings/*` (API tokens and webhook endpoints) and `DELETE /auth/session`;
  the public auth routes (`/auth/register`, `/auth/email/verify`, `/auth/email/verify/resend`,
  `/auth/password/forgot`, `/auth/password/reset`, `/auth/invites/*`); and the account routes
  (`/partner/users*`, `/partner/me*`). Token/webhook management, sign-up, invitations and user
  administration are all dashboard actions, not API ones — their codes `1330`–`1340`,
  `1349`–`1351`, `1359` and `1363` are in `references/errors.md` for completeness and an
  integration never sees them. Account actions never revoke a `partner:api` token: a password
  change logs out the person, not the integration.
- **An edit never rotates a secret.** `PATCH` on a token or a webhook endpoint returns no
  secret; rotation is its own route and is a **hard cutover** with no overlap window.

## References

- `references/host-architecture.md` — how to discover and honour the host project's
  architecture, and the conflicts worth escalating. Load it in step 0, before any code.
- `references/auth-and-scopes.md` — the token value and lifecycle, the thirteen scopes, the
  scope each route needs, and the four ways a request is refused. Load it in step 1.
- `references/endpoints.md` — every number/SMS/wallet/profile endpoint, request/response
  shape, query parameter and enum. Load it when writing or reviewing a specific call.
- `references/errors.md` — the two envelopes, the full `1301–1363` code table, and a
  per-endpoint dispatch matrix. Load it in step 2 and whenever handling a failure.
- `references/bulk-and-pricing.md` — bulk phone-number purchase, quoting, the discount ladder,
  wallet money semantics. Load it before multi-number purchase or any pricing display.
- `references/outbound-sms.md` — sending and pricing SMS, segments, idempotency, the
  lifecycle and its reserved states. Load it before touching `POST /sms`.
- `references/esim.md` — the whole eSIM plane: destinations, offers, the prepaid ladder,
  purchase, inventory, usage, credentials, top-ups and bulk orders.
- `references/webhooks.md` — the endpoint collection, all nine events, signature verification
  in JS/Python/PHP, retry schedule, idempotency. Load it when receiving webhooks.
- `assets/partner-api.openapi.yaml` — OpenAPI 3.1 spec for the integration surface; feed it
  to a client generator.
