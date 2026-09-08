# Bulk purchase, quoting and pricing

## Contents
- The flow in one picture
- `POST /phone-numbers/quote`
- `POST /phone-numbers/bulk`
- Idempotency
- `GET /phone-numbers/bulk/{orderId}` and polling
- `GET /phone-numbers/bulk`
- Per-slot error codes
- The discount ladder
- Affordability checks

## The flow in one picture

```
quote (optional, 30/min)  ->  POST /phone-numbers/bulk  ->  202 { orderId }
                                  (5/min, Idempotency-Key required)
                                          |
                        poll GET /phone-numbers/bulk/{orderId} until finishedAt != null
                                          |
                     (numbers.bulk_completed webhook may nudge you sooner — an
                      accelerator, never the channel)
```

Processing runs on **one sequential shared worker**, so a large order can take **tens of
minutes**. Never block a request or a screen on completion.

## `POST /phone-numbers/quote`

Prices a prospective order without placing it. Same body as the bulk endpoint, **minus the
`Idempotency-Key` header** — nothing is created, reserved, frozen or provisioned. Throttled
30/min per partner: debounce a draft, do not quote per keystroke.

```json
// request
{ "items": [ { "country": "US", "type": "local", "quantity": 10, "features": ["SMS"], "region": "CA" } ] }

// 200
{ "data": {
  "baseTotal":       { "amount": 30,   "amountDecimal": "30.0000", "currency": "USD" },
  "discountedTotal": { "amount": 22.5, "amountDecimal": "22.5000", "currency": "USD" },
  "discountPercent": 25,
  "items": [ {
    "country": "US", "type": "local",
    "quantity": 10, "pricedQuantity": 10,
    "unitBase":           { "amount": 3,    "amountDecimal": "3.0000",  "currency": "USD" },
    "unitDiscounted":     { "amount": 2.25, "amountDecimal": "2.2500",  "currency": "USD" },
    "subtotalBase":       { "amount": 30,   "amountDecimal": "30.0000", "currency": "USD" },
    "subtotalDiscounted": { "amount": 22.5, "amountDecimal": "22.5000", "currency": "USD" }
  } ]
} }
```

Render from **`amountDecimal`** — partner prices are genuinely sub-cent and a 500-number
order accumulates float error. `amount` is the convenient projection, not the truth.

Three figures that surprise people:

1. **`pricedQuantity` can be below `quantity`.** A line names no specific numbers, so it is
   priced over the distinct candidates that country/type can actually source. Surface it
   ("priced 3 of 10 — the rest depend on availability at purchase") and **never scale the
   subtotal up to `quantity`**. Unpriced slots are not free: they either fail as unavailable
   (costing nothing) or are charged by the per-number check at purchase time.
2. **`unitBase` / `unitDiscounted` are means over a mix of catalog prices**, not any one
   number's price. `unit × quantity ≠ subtotal` by construction — render each where it
   belongs and derive neither from the other.
3. **The same draft quoted twice can differ.** The upstream catalog shuffles results, so a
   second quote may price a different selection. The variance is bounded by the price spread
   for that country/type.

`discountedTotal` is **always present**, equal to `baseTotal` when nothing was discounted;
only `discountPercent` goes `null`. (Deliberately unlike a catalog row's `discountedPrice`,
where `null` carries a distinct meaning.)

**It never answers `402` and reserves nothing** — do not gate the submit button on this
figure. It *can* answer `403`/`1305` for a country you cannot buy, and this check is
**stricter than the accept path**: a draft can quote `403` and still submit successfully.

## `POST /phone-numbers/bulk`

Queues an async order and answers **`202` immediately** — nothing is provisioned inside the
request. Same auth as a single buy, no extra ability. Throttled 5/min per partner *on top of*
the general 60/min limit.

```json
// request; header: Idempotency-Key: <1..128 chars>
{ "items": [
  { "country": "US", "type": "local",  "quantity": 50 },
  { "country": "CA", "type": "mobile", "quantity": 10, "features": ["SMS"], "region": "ON" }
] }

// 202
{ "data": {
  "orderId": "01JB…",
  "status": "pending",
  "requested": 60,
  "discountPercent": 25,
  "statusUrl": "https://api.esimplus.net/api/partner/v1/phone-numbers/bulk/01JB…"
} }
```

Field rules: `items` 1..100 entries; `country` exactly 2 chars (upper-cased server-side, so
`"us"` == `"US"`); `type` `local` | `mobile` (lower-cased server-side); `quantity` integer
1..100; `features` optional, only `"SMS"` (uppercase); `region` optional, ≤100 chars,
forwarded upstream with your casing and **not** echoed back on a slot. Duplicate
identical lines are legal and allocated independently.

**Two independent caps, neither implying the other:**

| Cap | Value | Violation message (422, Envelope B) |
|---|---|---|
| `Σ items[].quantity` | 500 | `The total requested quantity may not be greater than 500.` |
| per line `quantity` | 100 | `A single line may not request more than 100 numbers.` |

Five lines of 100 is valid; one line of 101 is rejected even though 101 < 500.

**The practical ceiling is lower than the cap.** Upstream serves at most ~100 *distinct*
numbers per country/type per run (and often far fewer in a small country), so one line will
not deliver more than that however much you request. 500 delivered numbers needs five or
more different country/type lines. Design for partial success.

**The funds check is a pre-check, not a reservation.** For a `wallet_enforced` partner,
acceptance prices the visible candidates and rejects with `402`/`1315` if the available
balance is short — before any row is written, so no order is created and the same key retries
cleanly. It freezes nothing at order level: each number is charged individually as it is
issued, so a concurrent renewal, SMS charge or second order can drain the wallet mid-run and
starve later slots into a per-slot `1315`. **A `202` means "queued", never "affordable".**
For a partner without `wallet_enforced` there is no estimate and no wallet activity at all.

Errors: `422` Envelope B for any shape violation, a **missing** `Idempotency-Key`, or a key
replayed with a different body; `402`/`1315` Envelope A (no order created); `429`;
`500` if the upstream catalog is unavailable during the estimate (no order row).

## Idempotency

The key is unique per `(partner, key)`.

- **Same key + same request → the same `orderId`, `202` again, nothing re-queued.** Sameness
  is judged on a canonical fingerprint, so all of these replay rather than duplicate:
  different JSON key order, `country` case, `region` case, `features` order or duplicates,
  and `"quantity": "5"` vs `5`.
- **Same key + a materially different body → `422`**, message `This Idempotency-Key was
  already used with a different request body.` A changed `quantity`, a changed line **order**,
  or added/removed lines all count as different — **generate a new key when the draft
  changes**.
- Two simultaneous identical POSTs both get the same order.

## `GET /phone-numbers/bulk/{orderId}` and polling

`{orderId}` is the ULID from the accept response. **This is the guaranteed result channel.**
Query: `page`, `perPage` (max 50).

```json
{ "data": {
    "orderId": "01JB…", "status": "completed_with_errors",
    "requested": 60, "discountPercent": 25,
    "succeeded": 55, "failed": 5, "pending": 0,
    "createdAt": "…", "finishedAt": "2026-08-13T10:05:00+00:00",
    "items": [
      { "country": "US", "type": "local",  "status": "success",
        "number": { "…": "OwnedNumber — never carries the upstream-provider field" } },
      { "country": "CA", "type": "mobile", "status": "failed",
        "error": { "code": 1307, "message": "Phone number is not available for purchase." } },
      { "country": "CA", "type": "mobile", "status": "pending" }
    ] },
  "pagination": { "page": 1, "perPage": 30, "hasMore": true } }
```

- **Poll to a terminal `status`** (`completed`, `completed_with_errors`, `failed`) —
  equivalently until `finishedAt` is non-null. Start ~2s after the `202`, then back off
  2s → 5s → 10s, capped at 15s; pause while a tab is hidden. On `429` back off — it is not an
  order failure.
- **Counters are whole-order and live; `items[]` is one page.** Never sum `items[]` to build
  totals. `requested == succeeded + failed + pending` holds during and after processing.
- Slot shape: every item has `country`, `type`, `status`. `success` adds `number` and no
  `error`; `failed` adds `error` and no `number`; `pending` has neither. Slots do not echo
  `features` / `region`. Rows flip `pending` → `success`/`failed` between polls, so re-fetch
  the current page each time.
- The upstream-provider field is **never** exposed on a slot, even for a token carrying the
  add-on ability that reveals it elsewhere.
- `status: failed` means the order delivered **nothing** (`succeeded == 0`). An order that
  issued even one number ends `completed_with_errors`, including when its job later died.
- Order-level error: `404`/`1329` Envelope A for an unknown id **or** another partner's
  order — identical responses, so this is not an existence oracle. Pagination violations are
  `422` Envelope B.

## `GET /phone-numbers/bulk`

Your own orders, newest first (`created_at DESC, id DESC` — the id tiebreaker keeps paging
stable for orders accepted in the same second). Query: `page`, `perPage`, optional `status`.
Rows are the read-one payload **without `items[]`** (a page of 30 orders × 500 slots would be
15 000 rows). An empty result is `200` with `data: []`, never `404` — "no orders" and "filter
matched nothing" look the same. No `404` exists on this endpoint. No retention policy today.

## Per-slot error codes

`error.code` inside a `200`; the HTTP status of the response is always `200`.

| code | Meaning on a slot |
|---|---|
| 1304 | Country ISO rejected while buying that number. |
| 1305 | Country not available to this partner — that line's slots fail, other lines still run. |
| 1306 | Upstream could not resolve the country from the allocated msisdn. |
| 1307 | Nothing could be sourced: the catalog had nothing left for that country/type, or every candidate was taken before we bought it (retry ladder exhausted). |
| 1309 | Not delivered — a provisioning failure **or** a slot the run never attempted (its line's catalog call failed, or the batch ended with the slot open). Does not imply the number was rejected upstream. |
| 1310 | Regulated number, unsupported for partners. |
| 1315 | The wallet ran short while buying this slot (`wallet_enforced` only). |

`1308` never surfaces on a slot — it is absorbed by the retry ladder and ends as `1307`.

## The discount ladder

The tier is derived from the count of **active** owned numbers; there is nothing to configure
per partner. Defaults (read the live values from `GET /discount-levels`):
basic 0–5 → 0 %, startup 6–20 → 10 %, business 21–49 → 20 %, pro 50–99 → 25 %, vip 100+ → 30 %.

Three behaviours worth surfacing in any UI:

1. **A purchase counts itself.** The numbers being bought now are added to the active count
   *before* the rate is resolved, and **the whole order is priced at the resulting rate**. A
   partner on 45 active numbers buying 10 is priced at `pro`, for all 10. So a larger order
   can cost *less* per number than the catalog's `discountedPrice` (which is resolved at
   `active + 1`), never more.
2. **Monthly renewal reprices every cycle at the current tier.** Not locked to the rate paid
   at purchase. A growing fleet gets cheaper automatically — and a **shrinking fleet gets
   more expensive per number**, with no notification. Releasing numbers can drop a rung and
   raise the unit price of everything kept.
3. **A bulk order resolves ONE rate at acceptance** from `active + Σ quantity`, stores it, and
   charges every slot at it. Slots never re-resolve, so the order cannot re-tier mid-run.
   Read it as `data.discountPercent` on all three bulk endpoints: `0` = a resolved rate of
   zero (kill switch off, or a Basic partner), `null` = no rate was ever resolved (a
   wallet-disabled partner, charged nothing).

   It will legitimately disagree with `items[].number.billingPrice.discountPercent` — the
   order field is what the numbers were *bought* at, `billingPrice` is what they *renew* at.
   Most commonly they diverge when slots fail on thin supply, so an order quoted at Pro
   settles a fleet that only earns Business. Label them separately.

Where the discount shows up: catalog (`discountedPrice`), quote (both totals), single
purchase and bulk (wallet ledger rows carry `baseAmount` / `discountPercent`), monthly
renewal (repriced each cycle). **Never** on inbound-SMS charges, and n/a on top-ups.

**Kill switch.** The whole ladder sits behind one global, environment-level switch — not
per-partner, with no API to read it. While it is off: `profile.discountPercent` is `0` (while
`level`, `activeNumbers` and `numbersToNextLevel` still report the real tier),
`GET /discount-levels` still reports the configured percentages, everything charges base
price, and ledger rows carry `null` discount fields. `profile.discountPercent > 0` is the one
honest signal that a partner is being discounted right now — treat `0` as an ordinary state,
not an error.

## Affordability checks

- One number: compare `discountedPrice ?? price` against `wallet.availableBalance`. Reading
  `price` alone over-states the cost and sends the partner to top up money they do not need.
- Several numbers: use `POST /phone-numbers/quote` — do **not** multiply the catalog figure.
- Never recompute `base × (100 − p)/100` yourself: the server quantises in integer micros and
  client arithmetic disagrees exactly at tier boundaries, silently.
