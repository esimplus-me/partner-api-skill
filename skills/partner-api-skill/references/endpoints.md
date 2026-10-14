# Endpoint reference

Every path is relative to `https://api.esimplus.net/api/partner/v1`. All calls need
`Authorization: Bearer <partner:api token>` unless marked otherwise. Success bodies are
`{ "data": … }`; lists add `pagination: { page, perPage, hasMore }` (no `total`;
`perPage` max 50).

**Every integration route also requires a scope on the token** — a missing one is
`403`/`1362` and the message names it. The scope per route, and the token lifecycle, are in
`auth-and-scopes.md`. The eSIM plane (`/esims/*`) is in `esim.md`; outbound SMS
(`POST /sms`, `POST /sms/quote`) is in `outbound-sms.md`.

## Contents
- Endpoint index
- Catalog
- Owned numbers
- Tags
- SMS
- Stats
- Wallet
- Profile and discount levels
- Dashboard-only endpoints (not reachable with an API token)
- Enum reference

## Endpoint index

| Method | Path | Success |
|---|---|---|
| GET | `/phone-numbers/countries` | 200 |
| GET | `/phone-numbers/countries/{iso_name2}/catalog` | 200 paginated |
| GET | `/phone-numbers` | 200 paginated |
| POST | `/phone-numbers` | 201 |
| POST | `/phone-numbers/quote` | 200 |
| POST | `/phone-numbers/bulk` | 202 |
| GET | `/phone-numbers/bulk` | 200 paginated |
| GET | `/phone-numbers/bulk/{orderId}` | 200 paginated `items[]` |
| GET | `/phone-numbers/{sid}` | 200 |
| DELETE | `/phone-numbers/{sid}` | 204 |
| GET | `/tags` | 200 |
| POST | `/tags` | 201 |
| DELETE | `/tags/{id}` | 204 |
| POST | `/phone-numbers/tags` | 200 |
| GET | `/sms` | 200 paginated (**both directions**) |
| POST | `/sms` | 202 (`200` on an idempotent replay) |
| POST | `/sms/quote` | 200 |
| GET | `/stats/sms-received` | 200 |
| GET | `/wallet` | 200 |
| GET | `/wallet/transactions` | 200 paginated |
| GET | `/wallet/topups/providers` | 200 |
| POST | `/wallet/topups` | 201 |
| GET | `/wallet/topups` | 200 paginated |
| GET | `/wallet/topups/{topupId}` | 200 |
| GET | `/partner/profile` | 200 |
| GET | `/discount-levels` | 200 |

The eSIM plane adds fourteen more paths under `/esims/*` — see `esim.md` for the index.
The `/mobile-data/*` catalogue (`countries`, `regions`, `regions/{code}/countries`,
`countries/{iso}/catalog`, `regions/{code}/catalog`, scope `esim:read`, codes `1313`/`1314`)
is a separate data-bundle product and is out of scope here.

The bulk and quote endpoints are documented in `bulk-and-pricing.md`, outbound SMS in
`outbound-sms.md`, eSIMs in `esim.md`.

## Catalog

### `GET /phone-numbers/countries`

```json
{ "data": [ { "country": "United States", "isoName2": "US", "prefix": "1" } ] }
```

The ISO field is `isoName2` — there is no `iso` and no `countryCode` on this shape.

### `GET /phone-numbers/countries/{iso_name2}/catalog`

Query (all optional): `type` (`local` | `mobile`), `features[]` (only `"SMS"`, uppercase —
send as `features[]=SMS`), `region` (string ≤32, e.g. a US state code `DC`), `reserved`
(bool), `page`, `perPage`.

Item — **CatalogNumber**:

```json
{
  "msisdn": "15551234567",
  "displayNumber": "+1 555 123 4567",
  "countryCode": "US",
  "region": "California",
  "locality": "Los Angeles",
  "type": "local",
  "features": ["sms"],
  "isKycRequired": false,
  "price": { "amount": 1.5, "currency": "USD" },
  "discountedPrice": { "amount": 1.35, "currency": "USD" },
  "discountPercent": 10
}
```

- `price` is the **list** price in **major units** (dollars, not cents) and is never
  discounted. `discountedPrice` is what buying this one number would actually charge —
  priced at `activeNumbers + 1`, because a number counts toward its own tier.
- `discountedPrice` and `discountPercent` are nullable and are `null` **together**, meaning
  "no discount involved" — not "a discount of zero".
- `region` and `locality` are nullable.
- An extra **upstream-provider** field (a short string slug) appears **only** for a token
  carrying an internally-granted add-on ability; without it the key is **absent**, not
  `null`, and legacy `X-API-TOKEN` requests never see it. It is a field-level gate only — it
  never changes a status code or hides an endpoint. If your token has it, read the slug
  values off live responses; there is no fixed client-side list to hard-code.
- Errors: `422`/`1304` invalid ISO, `403`/`1305` country not available to this partner.

## Owned numbers

### `GET /phone-numbers`

Query (all optional): `country` (free-text, case-insensitive substring against the country
name; a 2-letter ISO code also matches; **min 1 char** — empty is `422`/`1306`), `type`,
`msisdn` (≤20), `sort` (`createdAt` | `msisdn` | `paidUntil`), `order` (`asc` | `desc`,
default `desc`), `tags[]` (integer tag ids, **match-ANY**), `page`, `perPage`.

Sorting by `paidUntil` puts numbers with no active billing (`null`) at the empty end: they
trail on `desc` and lead on `asc`.

Item — **OwnedNumber**:

```json
{
  "msisdn": "15551234567",
  "sid": "01J9Z...",
  "countryCode": "US",
  "region": "California",
  "locality": "Los Angeles",
  "type": "local",
  "features": ["sms", "voice"],
  "tagIds": [12, 34],
  "status": 1,
  "releasedAt": null,
  "gracePeriodEndsAt": null,
  "price": { "amount": 1.5, "currency": "USD" },
  "createdAt": "2026-07-01T12:00:00+00:00",
  "paidFrom": "2026-08-01T00:00:00.000Z",
  "paidUntil": "2026-09-01T00:00:00.000Z",
  "billingState": "active",
  "billingGraceEndsAt": null,
  "billingPrice": { "amount": 4, "currency": "USD", "baseAmount": 5, "discountPercent": 20 }
}
```

- `sid` is a ULID and is the number's public id — use it in every per-number path.
- **`msisdn` is bare digits, with no leading `+`** — while every SMS surface emits
  `from`/`to` as E.164 **with** `+`. The two endpoints genuinely disagree; compare by
  digits. `POST /sms` accepts either spelling, so a value taken straight from here can be
  sent unchanged.
- `status`: `1` active, `3` pending, `4` released. Only these three ever surface.
  `gracePeriodEndsAt` is non-null only when `status == 4` (release grace, 14 days).
- `features` are lowercase and may include `voice` / `mms` — tolerate them.
- Billing fields exist only for wallet-enforced partners and are all `null` for a pending,
  released or wallet-disabled number. `billingState` is `active` | `grace`;
  `billingGraceEndsAt` is non-null only while `grace` (payment grace, 10 days — the number
  keeps `status == 1`).
- `price` is the number's stored **base** price, frozen at purchase.
  `billingPrice.amount` is what the **next monthly renewal** will debit, carrying the
  partner's *current* tier — so the two legitimately differ and move independently.
  `billingPrice.baseAmount` / `discountPercent` are `null`, not `0`, when no discount applied.

### `POST /phone-numbers` (buy one)

Throttled 10/min. Request: `{ "msisdn": "15551234567" }` (required, 5..20 chars).
`201` → `{ "data": <OwnedNumber> }` (never includes the upstream-provider field).

**Not idempotent.** A retry can buy a second number. Handle a timeout by reading
`GET /phone-numbers` to see whether the purchase landed — never by resending.

Errors: `403`/`1305`, `409`/`1308`, `402`/`1315` (wallet-enforced only), `422`/`1306`,
`404`/`1307`, `502`/`1309` (nothing charged), `422`/`1310`, `429`.

### `GET /phone-numbers/{sid}`

`200` → `{ "data": <OwnedNumber> }`. Error `404`/`1311`.

### `DELETE /phone-numbers/{sid}` (release)

`204`. The number enters release grace. Errors `404`/`1311`, `409`/`1312`.

## Tags

- `GET /tags` → `{ "data": [ { "id": 12, "name": "VIP", "color": "blue" } ] }`
- `POST /tags` — `{ "name": "VIP", "color": "blue" }` (`name` ≤64; `color` from the TagColor
  enum, a preset key — **no raw hex**) → `201`. Error `422`/`1326` (duplicate name or bad color).
- `DELETE /tags/{id}` — `204`. Deletes the tag and cascade-detaches it from every number.
  **Idempotent:** deleting an unknown or already-deleted tag also returns `204`.
- `POST /phone-numbers/tags` — bulk apply/remove:

  ```json
  { "sids": ["01J9Z...", "01JA0..."], "add": [12, 34], "remove": [56] }
  ```

  `200` → `{ "data": { "updated": 2 } }` (`updated` = numbers matched). Idempotent: adding a
  tag a number already has, or removing one it lacks, is a no-op. Error `422`/`1326` if any
  sid or tag id is not yours.

## SMS

### `GET /sms`

SMS on **your own** numbers, newest first. Scope is taken from the token; there is no
parameter that widens it. It lists **both directions**, interleaved
chronologically — outbound rows carry `direction: "sent"` plus optional lifecycle and price
fields. All filters AND together and are optional.

Query: `sender` (case-insensitive substring on the stored E.164 value — normalise your input
by stripping spaces, parens and dashes, keeping an optional leading `+`; min 1 char),
`recipient` (same matching, 1..20 — a number you do not own yields an empty page, never
someone else's data), `from` / `to` (UTC calendar days `YYYY-MM-DD`, inclusive:
`from` → `>= fromT00:00:00Z`, `to` → `<= toT23:59:59.999Z`; `from > to` is `422`),
`direction` (`received` | `sent`), `sort` (`receivedAt` only), `order` (default `desc`),
`page`, `perPage`.

Invalid params → `422` **Envelope B** (no code) — dispatch on `message`.

Item — **Sms**. Required on every row: `id` (ULID), `receivedAt`, `from`, `to`, `text`,
`direction`. Outbound rows add `status`, `segments`, `encoding`, `priceMinor`, `currency`,
`sentAt`, `deliveredAt`, `failedAt`, and (when blocked) `blockedReason` / `blockedDetail`.

- **Optional fields are absent, not `null`, when they do not apply.** Test for presence.
- **`receivedAt` is the single sortable/filterable time field for both directions** — "when
  the platform recorded this message": arrival for inbound, acceptance for outbound. The name
  is inherited, not descriptive; it is what lets the two interleave.
- `from` / `to` are canonical **E.164 with `+`**, while `OwnedNumber.msisdn` has none.
  Compare by digits, never as strings.

### `POST /sms` and `POST /sms/quote`

Sending and pricing an outbound message — scopes `sms:send` and `sms:read`, an **`202`** on
accept, a **required `Idempotency-Key`**, two independent ceilings on `text`, and a total that
must not be recomputed from the unit price. All of it is in `outbound-sms.md`.

## Stats

### `GET /stats/sms-received`

Query `days` (1..90, default 30).

```json
{ "data": { "total": 42, "series": [ { "date": "2026-07-01", "count": 3 } ] } }
```

Zero-filled contiguous days, inbound only, `total == Σ series`.

## Wallet

Money here is **integer minor units (cents)** *plus* an exact 4-decimal string sibling. The
wallet is stored internally in micros (1e-6 USD), so genuinely sub-cent charges are exact:
the integer fields are a **rounded** back-compat projection, the `*Decimal` strings are the
truth. **Sum the `*Decimal` fields to reconcile a ledger against the balance.**

### `GET /wallet`

```json
{ "data": {
  "balance": 5000, "frozenBalance": 1000, "availableBalance": 4000,
  "balanceDecimal": "0.5000", "frozenBalanceDecimal": "0.1000",
  "availableBalanceDecimal": "0.4000", "currency": "USD"
} }
```

`availableBalance = balance − frozenBalance`. Affordability checks read
**`availableBalance`**, never `balance`. A partner who never topped up reads all zeros.

### `GET /wallet/transactions`

Query: `type`, `from`, `to` (dates, inclusive), `page`, `perPage`. Item:

```json
{
  "id": 1001, "type": "debit",
  "amount": 210, "amountDecimal": "0.0210",
  "baseAmount": 300, "baseAmountDecimal": "0.0300", "discountPercent": 30,
  "reference": "01J9Z...", "description": null,
  "createdAt": "2026-07-01T12:00:00+00:00"
}
```

- `amount` is the rounded whole-cent magnitude of what actually moved; `amountDecimal` is
  exact (a sub-cent SMS debit reads `"amount": 0, "amountDecimal": "0.0051"`).
- `baseAmount` / `baseAmountDecimal` / `discountPercent` are the pre-discount figures and are
  **all three `null` together** on top-ups, inbound-SMS charges, undiscounted charges,
  `unfreeze`/`refund` rows, and every historical row (no backfill). `null` ≠ `0 %`.
- `amountDecimal` is not exactly `baseAmountDecimal × (100 − discountPercent)/100`: the
  charge is quantised to 4 decimals. Display the stored figures; never re-derive and assert.

### Top-ups

- `GET /wallet/topups/providers` → `[ { "id": "<slug>", "name": "Card", "minAmount": 500,
  "maxAmount": 1000000, "currency": "USD" }, … ]`. **Always read the list from this
  endpoint** and use an `id` from it as `provider` — the set of enabled payment methods is
  configuration and differs per environment, so never hard-code a slug.
- `POST /wallet/topups` (10/min) — `{ "amount": 5000, "provider": "<slug from providers>",
  "successUrl": "https://…", "failureUrl": "https://…" }`. `amount` is **cents**,
  500..1000000. URLs are SSRF-validated (https, public host, no credentials) → `422`
  Envelope B on rejection. `201` → `{ "data": { "id": "01JB…", "payUrl": "…",
  "expiresAt": null } }`. Send the user to `payUrl`.
- `GET /wallet/topups` / `GET /wallet/topups/{topupId}` — `{topupId}` is the ULID `id` from
  create. Error `404`/`1321`. Shape:

  ```json
  { "id": "01JB...", "status": "pending", "amount": 5000, "provider": "<slug>",
    "payUrl": "…", "expiresAt": null, "createdAt": "…", "paymentId": null,
    "completedAt": null }
  ```

**Never credit balance because the browser came back to `successUrl`.** Poll
`GET /wallet/topups/{id}` until `status` is `completed` (then re-read `GET /wallet`) or
`failed` / `expired`. The wallet is credited server-side by the payment callback.

## Profile and discount levels

### `GET /partner/profile`

```json
{ "data": { "id": 42, "name": "Acme Communications", "email": "op@acme.com",
            "agreementsAccepted": true, "agreementsAcceptedAt": "…",
            "level": "business", "discountPercent": 20,
            "activeNumbers": 34, "numbersToNextLevel": 16 } }
```

- `level` is derived live from `activeNumbers` (numbers with `status == 1`; payment-grace
  numbers still count, released ones do not) — not an attribute an admin sets.
- `discountPercent` is the rate charged **today**, and is `0` whenever the global discount
  feature is switched off. It is the only honest signal for "is this partner discounted".
- `numbersToNextLevel` is floored at `0` and is `null` on `vip`.

### `GET /discount-levels`

Static reference data, reachable with **any** partner token (never `403`/`1327`):

```json
{ "data": [
  { "level": "basic",    "from": 0,   "to": 5,    "discountPercent": 0,  "displayName": "Basic",    "badgeColorHex": "#FFFFFF" },
  { "level": "startup",  "from": 6,   "to": 20,   "discountPercent": 10, "displayName": "Startup",  "badgeColorHex": "#30D158" },
  { "level": "business", "from": 21,  "to": 49,   "discountPercent": 20, "displayName": "Business", "badgeColorHex": "#64D2FF" },
  { "level": "pro",      "from": 50,  "to": 99,   "discountPercent": 25, "displayName": "Pro",      "badgeColorHex": "#FF9F0A" },
  { "level": "vip",      "from": 100, "to": null, "discountPercent": 30, "displayName": "Vip",      "badgeColorHex": "#FFD60A" }
] }
```

`to` is `null` on `vip` (unbounded). The percentages are live configuration — render what the
endpoint returns, never a hard-coded copy. They **ignore the kill switch**, so gate any "you
save X%" copy on `profile.discountPercent > 0`.

## Dashboard-only endpoints (not reachable with an API token)

These require a short-lived `partner:dashboard` session token from `POST /auth/login`. A
`partner:api` token gets `403`/`1327`. Listed so you know where they live, not to call them
from an integration:

- **API tokens** — `GET /settings/api-token-scopes`, `GET|POST /settings/api-tokens`,
  `PATCH|DELETE /settings/api-tokens/{id}`, `POST /settings/api-tokens/{id}/rotate`.
- **Webhook endpoints** — `GET /settings/webhook-events`, `GET|POST /settings/webhooks`,
  `PATCH|DELETE /settings/webhooks/{id}`, `POST /settings/webhooks/{id}/secret`,
  `POST /settings/webhooks/{id}/test`. The V1 `GET|PUT|DELETE /settings/webhook` routes were
  **removed**, not deprecated.
- **Session and account** — `DELETE /auth/session`, `POST /partner/agreements/accept`, the
  public auth routes and `/partner/users*` / `/partner/me*`.

All `/settings/*` routes are **administrator-only in their entirety, the reads included**;
minting a credential (token create/rotate, endpoint create/secret-rotate) and deleting a
token additionally require a verified email (`1332`).

**Consequence for integrators:** provisioning tokens and configuring callback endpoints —
each of which returns its secret **once** — are human dashboard actions. Do not design a
self-provisioning flow around them. Details in `auth-and-scopes.md`.

## Enum reference

- number `type`: `local`, `mobile` (lower-cased server-side, so `"Local"` is accepted).
- capabilities: request filter accepts only `"SMS"`; responses emit `sms` / `voice` / `mms`.
- `TagColor`: `blue`, `green`, `amber`, `red`, `violet`, `teal`, `pink`, `slate`.
- transaction `type`: `credit`, `debit`, `freeze`, `unfreeze`, `consume_frozen`, `refund`.
- top-up `status`: `pending`, `completed`, `failed`, `expired`.
- owned-number `status` (int): `1` active, `3` pending, `4` released (only these are returned).
- bulk order `status`: `pending`, `processing`, `completed`, `completed_with_errors`, `failed`.
- bulk slot `status`: `pending`, `success`, `failed`.
- `PartnerAccountLevel`: `basic`, `startup`, `business`, `pro`, `vip` (ladder order).
- SMS `direction`: `received`, `sent`.
- `SmsStatus` (outbound only): `queued`, `under_review`, `sent`, `delivered`, `failed`,
  `blocked` — published in full; only `queued`, `sent`, `delivered` and `failed` occur today.
- `SmsBlockedReason`: `content_policy`, `sending_pattern`, `recipient_opted_out`,
  `recipient_blocked`, `destination_not_permitted`, `manual_review` — no producer today.
- `SmsEncoding`: `GSM7`, `UCS2`.
- `EsimStatus` (**string**, unlike the owned-number integer `status`): `pending`, `active`,
  `suspended`, `deleted`.
- `EsimFeature`: `voice`, `sms`, `data` — a separate enum from the phone-number `Feature`
  (`voice`, `sms`, `mms`). Not merged.
- `EsimUsageKind`: `voice`, `data`, `sms`; `EsimUsageUnit`: `seconds`, `megabytes`, `messages`
  (bound to the kind).
- API-token scopes: see the thirteen keys in `auth-and-scopes.md`.
- Webhook events: `sms.inbound`, `sms.outbound.sent`, `sms.outbound.delivered`,
  `sms.outbound.failed`, `wallet.topped_up`, `numbers.bulk_completed`, `esims.bulk_completed`,
  `esim.topped_up` (subscribable) and `webhook.test` (not subscribable).
