# The eSIM plane (`/esims/*`)

A second product on the same partner plane: a **full SIM
profile** — a real phone number that can take calls and SMS, plus mobile data — sold funded
with a pre-paid balance package. Shaped deliberately like the phone-number plane (same
catalog → buy → inventory → bulk arc, same throttles, same non-idempotent single buy), but
it is a different product with different money.

## Contents
- Endpoint index
- The two balances
- Destinations and offers
- Buying one
- Owned eSIMs
- Usage
- Credentials (PIN/PUK)
- eSIM top-ups
- Tags
- Bulk eSIM orders
- Error codes
- Gotchas

## Endpoint index

| Method | Path | Scope | Success |
|---|---|---|---|
| GET | `/esims/destinations` | `esim:read` | 200 (not paginated) |
| GET | `/esims/destinations/{code}/catalog` | `esim:read` | 200 paginated |
| GET | `/esims` | `esim:read` | 200 paginated |
| POST | `/esims` | `esim:write` | 201 |
| GET | `/esims/{icc}` | `esim:read` | 200 |
| DELETE | `/esims/{icc}` | `esim:write` | 204 |
| GET | `/esims/{icc}/usage` | `esim:read` | 200 paginated + `summary` |
| POST | `/esims/{icc}/credentials` | `esim:credentials` | 200 |
| GET | `/esims/{icc}/topups` | `esim:read` | 200 paginated |
| POST | `/esims/{icc}/topups` | `esim:topup` | 201 |
| POST | `/esims/tags` | `tags:write` | 200 |
| POST | `/esims/bulk` | `esim:write` | 202 |
| GET | `/esims/bulk` | `esim:read` | 200 paginated |
| GET | `/esims/bulk/{orderId}` | `esim:read` | 200 paginated `items[]` |

`icc` is the ICCID (19–20 digits) and is the resource identity on every sub-route — there is
no second id. The field is spelled **`icc`**, not `iccid`.

## The two balances

A partner on this plane holds **two separate monies that never net against each other**:

| | Partner wallet | eSIM balance |
|---|---|---|
| Scope | one per partner company | one per SIM |
| Pays for | buying profiles and numbers | calls and traffic on that SIM |
| Topped up via | `POST /wallet/topups` | `POST /esims/{icc}/topups` |
| Read from | `GET /wallet` | `Esim.balance` |

- Buying a profile debits the **wallet** by `offer.price + package.price` as **one charge**,
  and delivers the SIM carrying `package.price` on its own balance. The two figures are the
  same number by design — never reconcile "package paid" against "balance credited".
- **Deleting a SIM forfeits its remaining balance.** It does not return to the wallet.
- A SIM running out of balance does **not** draw on the wallet; it simply stops placing calls
  and the provider may move it to `suspended`.
- An eSIM top-up does not pass through the wallet at all — it opens a payment provider
  directly, which is why it is the one admin-only eSIM endpoint.

## Destinations and offers

### `GET /esims/destinations`

Not paginated. A **destination is a coverage bundle, not a country** — `EE-GB` is "Estonia +
United Kingdom", one product.

```json
{ "data": [ {
  "code": "EE-GB",
  "name": "Estonia + United Kingdom",
  "countryCodes": ["EE", "GB"],
  "features": ["voice", "sms", "data"],
  "prepaidPackages": [ { "code": "pp-1", "price": { "amount": 9.99, "currency": "USD" } } ],
  "availableCount": 42,
  "fromPrice": { "amount": 4.5, "currency": "USD" }
} ] }
```

- `code` is an **opaque slug**, safe in a path segment, and is **not an ISO code** even when
  it looks like one. Case-insensitive on input, echoed back canonicalised.
- `countryCodes` is **ordered**: index 0 is the primary number's country, index 1 the extra
  number's. One entry = single-number profile, two = dual-number.
- `availableCount` is a hint, never a reservation — it can be stale by the next read.
- `EsimFeature` is `voice | sms | data` — a **different enum** from the phone-number
  `Feature` (`voice | sms | mms`). Do not merge them.

### `GET /esims/destinations/{code}/catalog`

Query: `page`, `perPage` (max 50). Items are **EsimOffer**:

```json
{
  "offerId": "<opaque>",
  "phoneNumber": "+37256000101",
  "extraPhoneNumber": null,
  "countryCode": "EE",
  "extraCountryCode": null,
  "price": { "amount": 4.5, "currency": "USD" },
  "features": ["voice", "sms", "data"],
  "prepaidPackages": [ { "code": "pp-3", "price": { "amount": 23, "currency": "USD" } } ],
  "dataIncludedMb": null
}
```

- **`offerId` is opaque.** Never construct, parse or infer one. (It is a reversible encoding
  of the ICCID as built; an earlier draft of the contract called it a ULID. Both are
  implementation details, which is why the declared type is a bare string.)
- A catalog row is a **snapshot, never a reservation**, and partner demand shares one profile
  pool with the consumer app — `1342` ("offer no longer available") is a real race.
- `404`/`1341` fires only on an **unknown destination slug**. A known destination with zero
  free profiles returns an **empty page**, not a 404.
- eSIM prices carry **no `discountedPrice` / `discountPercent` anywhere**, bulk included.
  Partner tier discounts apply to phone numbers only. The keys are *absent*, not null — do
  not render an undiscounted figure as though a discount had failed to load.

### The prepaid ladder

Six fixed tiers, destination-scoped, and **resolved against the offer, never a global
table**:

| Tier | Single-number profile | Profile with a second number |
|---|---|---|
| `pp-1` | $7.99 | $9.99 |
| `pp-2` | $11.50 | $13.50 |
| `pp-3` | $23.00 | $25.00 |
| `pp-4` | $57.50 | $59.50 |
| `pp-5` | $115.00 | $117.00 |
| `pp-6` | $230.00 | $232.00 |

The dual-number surcharge is **+$2.00 flat on every tier, added rather than multiplied**, and
the tier codes are identical across both columns. Tier codes are stable across destinations;
**prices are not**. **Render `price`, send `code`, compute neither** — deriving the dual
ladder from the single one is one config change away from charging the wrong amount.

## Buying one

### `POST /esims` (buy one)

Throttled 10/min, shares the buy bucket with `POST /phone-numbers`. Requires a verified email.

```json
// request
{ "offerId": "<from the destination catalog>", "prepaidPackage": "pp-3" }
// 201 → { "data": <Esim> }
```

- **Not idempotent**, exactly like `POST /phone-numbers` — and an `Idempotency-Key` header is
  **ignored**, not honoured, so sending one buys a second profile while looking like it did
  not. Never put this behind an automatic retry.
- `prepaidPackage` is **never optional**: every destination sells funded, and a zero-balance
  profile cannot call. A code outside that offer's own ladder is a plain `422` (Envelope B),
  not a domain code — it is a malformed request, not a reachable state.
- The returned `status` is **`pending`**, and `activation` is `null`. Claiming a profile and
  provisioning it upstream are not one transaction (not even one database). There is **no
  `esim.activated` webhook** — re-read `GET /esims/{icc}` to watch it become `active`.
- Errors: `402`/`1315` (wallet short), `403`/`1332` (unverified email), `404`/`1341` or
  `1342` (destination gone / offer taken), `502`/`1345` (provisioning failed — the **whole**
  debit is refunded, profile half included), `429`.

## Owned eSIMs

### `GET /esims`

Query (all optional): `country[]` (ISO alpha-2, repeatable, **match-ANY**, matched against the
primary **or** the extra country), `phoneNumber` (≤20), `extraPhoneNumber` (≤20), `status`,
`tags[]` (integer ids, match-ANY), `sort` (`icc` | `phoneNumber` | `extraPhoneNumber` |
`createdAt` | `balance`), `order` (`asc` | `desc`, default `desc`), `page`, `perPage`.

Array params need **PHP bracket notation** (`country[]=EE&country[]=GB`) — the same trap the
phone-number plane has.

Item — **Esim**:

```json
{
  "icc": "8937201234567890123",
  "phoneNumber": "+37256000101",
  "extraPhoneNumber": null,
  "countryCode": "EE",
  "extraCountryCode": null,
  "status": "active",
  "balance": { "amount": 22.4, "currency": "USD" },
  "tagIds": [12],
  "price": { "amount": 4.5, "currency": "USD" },
  "createdAt": "2026-10-06T12:00:00+00:00",
  "activatedAt": null
}
```

- `EsimStatus` is a **string** enum — `pending` | `active` | `suspended` | `deleted` — unlike
  the owned-number `status`, which is an integer.
- `extraPhoneNumber` / `extraCountryCode` are `null` **together**. Null and "same as primary"
  are different facts; never fall back to the primary for display.
- Rows with a null `extraPhoneNumber` sort **last in both directions**.
- `activatedAt` is null while `status` is `pending`.

### `GET /esims/{icc}` — **EsimDetail**

`Esim` plus `activation` and `lastUsedAt`. `activation` is `null` while `status` is `pending`.

```json
{ "activation": { "activationCode": "LPA:1$consumer.rsp.global$ABC…", "qrCodeUrl": null },
  "lastUsedAt": null }
```

The SM-DP+ address is **not** a separate field: it is already the middle segment of
`activationCode`. `provider` and `imsi` are deliberately **not published** on the detail.
Error `404`/`1343`.

### `DELETE /esims/{icc}` (terminate)

`204`. Errors `404`/`1343`, `409`/`1344` (not deletable in its current status).
**The SIM's remaining balance is forfeited** — warn before calling it.

## Usage

### `GET /esims/{icc}/usage`

Query: `kind` (`voice` | `data` | `sms`), `from` / `to` (ISO-8601 date-times), `page`,
`perPage`. Response adds a sibling **`summary`** beside `data` and `pagination`.

- **`from` defaults to 30 days ago and `to` to now.** The provider requires a bounded range,
  so omitting them does **not** mean "all time" — a UI offering an all-time window while
  omitting the bounds shows 30 days under the wrong label.
- **The feed is voice-only, and that is a provider limit.** The upstream supplier exposes exactly one
  call-detail-record feed, and it returns call records. `data` and `sms` buckets report **zero with their
  correct units** rather than a fabricated number, and `kind=data` / `kind=sms` short-circuit
  without calling the provider at all. Zeros there are a true statement, not a bug to retry.
- The CDR is **account-wide for a date range** with no per-ICC endpoint, so every usage page
  costs one account-wide provider call. It is slower than every other read — **do not poll
  it**.
- A record `id` is **deterministic** (provider uniqueid + event time), so de-duplicating by
  id across pages is safe.
- `kind` narrows the **summary** as well as the page; only pagination is page-shaped.
- Record `cost` carries **4 decimals**, not 2 — per-call charges are genuinely sub-cent.
  **Render `summary`, never the sum of `data[]`**: `summary.totalCost` is summed at full
  precision and rounded once.
- `EsimUsageUnit` is bound to `kind`: `voice` → `seconds`, `data` → `megabytes`,
  `sms` → `messages`. `direction` (`inbound` | `outbound`) is `null` for `data`.
- Error `404`/`1343`.

## Credentials (PIN/PUK)

### `POST /esims/{icc}/credentials`

A **POST although it reads**: a reveal is an audited, rate-limited event, and a `GET` would be
replayed by caches, prefetch and history. **There is no `GET` alias — a `GET` answers 405.**

- Throttled **5/min** per partner on its own bucket — the lowest limit in the partner plane.
- Served `Cache-Control: no-store`. `200` → `{ "data": { "pin1", "pin2", "puk1", "puk2" } }`.
  Never cache, never log, never persist these client-side.
- The reveal is audited server-side (partner, acting user, icc, time — never the values). For
  a `partner:api` token the acting user is null, which is itself the audited fact.
- Both dashboard roles may reveal; the only eSIM capability a member lacks is topping up.
- Errors: `403`/`1327` (wrong token kind) or `403`/`1362` (token lacks `esim:credentials`),
  `404`/`1343`, `409`/`1346` (provider could not answer right now — **retryable**), `429`.

## eSIM top-ups

### `POST /esims/{icc}/topups`

Deliberately mirrors `POST /wallet/topups`: `{ amount, provider, successUrl, failureUrl }` →
`payUrl` → asynchronous completion. Throttled 10/min, **admin-only**, verified email required.

- `amount` is **integer cents** — the one place on the eSIM surface where money is not a
  `Price` object.
- **The documented minimum of 100 is unreachable.** Every configured provider's band starts at
  **500**, so 100–499 is contract-valid and always answers `409`/`1347`. Read the band from
  `GET /wallet/topups/providers` and floor the control at 500.
- `provider` is a slug from the **wallet's** `GET /wallet/topups/providers` list — there is no
  eSIM-specific provider list. **`EsimTopup.provider` is a *payment* provider, not the eSIM
  supplier.**
- `successUrl` / `failureUrl` are SSRF-validated exactly as on the wallet (https only, no
  credentials, host must resolve, no private or reserved address) → `422` Envelope B.
- An amount outside the chosen provider's band, **or an unknown provider slug**, is
  `409`/`1347` — the request is well formed and another provider would accept it, so what
  failed is the pairing, not a field.
- A member gets `403`/`1335`; an unverified admin gets `403`/`1332`. A `partner:api` token is
  **not role-gated** at all (it has no person behind it), so it passes the admin gate.

### `GET /esims/{icc}/topups`

Paginated history. Item — **EsimTopup**: `id` (ULID), `icc`, `status`, `amount` (cents),
`provider`, `payUrl`, `expiresAt`, `createdAt`, `completedAt`. Same `TopupStatus` enum as the
wallet.

**The SIM is credited only when `status` reaches `completed`** — never when the browser lands
on `successUrl`, which anyone can type into an address bar. Polling this endpoint is the
guaranteed channel; `esim.topped_up` is the accelerator.

## Tags

### `POST /esims/tags`

The twin of `POST /phone-numbers/tags` over the same `/tags` plane — only the identifier list
differs (`iccs` rather than `sids`). A tag id may sit on a number **and** on an eSIM, and
deleting the tag detaches it from both.

```json
{ "iccs": ["8937201234567890123"], "add": [12, 34], "remove": [56] }
// 200 → { "data": { "updated": 1 } }
```

**`updated` means something narrower here than on the phone-number twin.** On `/esims/tags` it
counts the eSIMs that **actually changed** — a redundant add or an absent remove returns `0`.
On `/phone-numbers/tags` it returns the number of sids you handed it regardless. The
divergence is known and deliberate; do not assume one from the other. Error `422`/`1326`.

## Bulk eSIM orders

The same asynchronous, partially-successful shape as bulk numbers, on **its own queue** — a
large eSIM order does not queue behind a large number order.

### `POST /esims/bulk`

`202`, `Idempotency-Key` required, throttled 5/min (shares the bulk bucket), verified email.

```json
{ "items": [ { "destination": "EE-GB", "quantity": 10, "prepaidPackage": "pp-3" } ] }
// 202
{ "data": { "orderId": "01JC…", "status": "pending", "requested": 10,
            "statusUrl": "https://api.esimplus.net/api/partner/v1/esims/bulk/01JC…" } }
```

**Three independent caps**, none implying another: at most **10 lines**, at most **50 per
line**, and `Σ quantity` at most **100**. Two lines of 50 is valid; one line of 51 is not.

- `prepaidPackage` is **per line, not per order** — the ladder is destination-scoped, so two
  lines may fund differently, and it is required on **every** line for the same reason the
  single buy requires it.
- `prepaidPackage` is part of the **idempotency fingerprint**: the same key with a different
  package is a *different order*, not a replay. Same key plus a byte-identical body replays.
- Duplicate identical lines are legal and allocated independently.
- There is **no `discountPercent`** on the accept receipt or anywhere else on this plane.

### `GET /esims/bulk` and `GET /esims/bulk/{orderId}`

`GET /esims/bulk` — your orders, paginated, optional `status` filter; rows are
`EsimBulkOrderSummary` (the counters **without** `items[]`).

`GET /esims/bulk/{orderId}` — whole-order counters plus **one page** of slots. Poll until
`finishedAt` is non-null. `requested == succeeded + failed + pending` holds at every poll, and
`pending` is `0` once `finishedAt` is set. **Never sum `items[]` to build the counters.**

Slot shape: `destination` (canonical), `status` (`pending` | `success` | `failed`), `esim`
only on `success`, `error` only on `failed`.

Per-slot `error.code` inside a `200`:

| code | Meaning on a slot |
|---|---|
| 1341 | The destination is no longer available. |
| 1342 | The profile this slot tried to take was bought first — the destination ran out. |
| 1345 | **Not delivered**: the provider could not issue a profile, *or* the run never attempted this slot. Nothing was charged. |
| 1315 | The wallet ran short while this slot was being bought. |

Order-level error: `404`/`1348` for an unknown id **or another partner's order** — identical
answers, so it is not an existence oracle. (Note the number plane uses `1329` for the same
situation; the two codes are not interchangeable.)

## Error codes

| code | HTTP | Meaning |
|---|---|---|
| 1341 | 404 | eSIM destination is unknown or no longer available |
| 1342 | 404 | eSIM offer is no longer available (someone bought that profile first) |
| 1343 | 404 | eSIM not found |
| 1344 | 409 | eSIM cannot be deleted in its current status |
| 1345 | 502 | eSIM profile could not be issued — **nothing was charged** |
| 1346 | 409 | eSIM credentials temporarily unavailable — retryable |
| 1347 | 409 | Payment provider rejected this amount (or the slug is unknown) |
| 1348 | 404 | Bulk eSIM order not found |

`1345` is deliberately **kept separate from `1309`**. Its "nothing charged" is an explicit
compensating refund, not a transaction rollback — a purchase crosses two databases.

## Gotchas

- **`EE` is a single-number destination even though some `EE` profiles physically carry a
  second number.** The partner surface declares one `countryCode`, prices on the single-number
  ladder, and a purchased `EE` eSIM reports `extraPhoneNumber: null`. This is the one place
  the partner and consumer views of the same row disagree, intentionally.
- **`pending` is reachable and normal** — not a transient you can code away. There is no
  activation webhook; re-read the detail.
- **`1342` is a real race, not a theoretical one.** Treat "offer taken" as an ordinary outcome
  of a catalog that reserves nothing, and re-fetch the page.
- **Do not look for discounts here.** No `discountedPrice`, no `discountPercent`, no
  `baseAmount` — the keys are absent, by test.
- **The bulk order id namespace is distinct from the number plane's.** `GET /esims/bulk/{id}`
  404s with `1348`; `GET /phone-numbers/bulk/{id}` 404s with `1329`.
