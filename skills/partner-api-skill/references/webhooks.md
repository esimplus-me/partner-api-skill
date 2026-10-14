# Webhooks (eSIM Plus → your endpoint)

## Contents
- The endpoint collection (V2)
- Delivery
- Events
- Signature verification
- Retries
- Idempotency
- Receiver checklist

## The endpoint collection (V2)

Partner API V2 replaced the single callback URL with a **list** of endpoints. A partner keeps
several, each with **its own name, its own signing secret and its own explicit subscription**
to events from a published catalogue. The V1 routes (`GET`/`PUT`/`DELETE /settings/webhook`)
were **removed, not deprecated** — a surviving V1 integration must be migrated.

What this changes for a receiver:

- **One secret per endpoint.** Verify with the secret of the endpoint that received the
  request, not an account-wide key. Rotating a staging mirror's secret must not break
  production.
- **Rotation is a hard cutover** — no overlap window, the previous secret stops verifying
  immediately. The secret appears in exactly two responses: creating an endpoint and rotating
  its secret. **An edit never rotates** (V1's `PUT` did, which silently broke verification
  for anyone fixing a typo).
- **`events` is an explicit non-empty array — no wildcard, no null, no empty.** "Select all"
  in the dashboard expands to a literal list.
- **A new catalogue event arrives unchecked on every existing endpoint.** There is no error,
  no log and no delivery row to notice it: a partner whose endpoint already receives
  `sms.inbound` receives **zero** outbound events until they tick the new boxes. The default
  state of an existing endpoint for a new event is "subscribed to nothing".
- **Several endpoints may subscribe to the same event.** No uniqueness constraint on URL or
  on events; each receives its own copy, signed with its own secret.
- **`enabled: false` is a pause, not a delete.** URL, events, secret and id all survive.
  Pausing governs which **new** events fan out; deliveries already queued **drain** on their
  existing back-off, so a paused endpoint can still receive traffic for a while.
- Each endpoint's URL is SSRF-validated on create and on update: `https` only, no credentials
  in the URL, the host must resolve, and no resolved address may be private or reserved.

The management routes are `partner:dashboard`, administrator-only, and answer `403`/`1327`
for a `partner:api` token — see `auth-and-scopes.md`. Their domain codes: `1325` (404,
endpoint not found, including another partner's id), `1349` (422, endpoint limit reached —
default 10), `1350` (422, unknown event key), `1351` (409, endpoint is paused — resume it
before sending a test).

**A failed test delivery is a `200`.** `POST /settings/webhooks/{id}/test` sends one signed
`webhook.test`, synchronously and with **no retries**, and reports
`{ delivered, statusCode, durationMs, error }`. The API call succeeded; the partner's server
is what failed. Only a refusal to *attempt* — unknown endpoint, paused endpoint — is an error
status. `statusCode` is null when nothing answered at all. Its own cooldown: one test per
endpoint per 10 s, answered with a `429` carrying no `code` and no `Retry-After`.

## Delivery

- Method `POST`, `Content-Type: application/json`.
- Body keys are **snake_case** — the one place the API is not camelCase.
- The event type is in the `event` field of the body.
- Request timeout: **10 seconds**. Answer fast: enqueue and return, do not process inline.
- Headers:

| Header | Meaning |
|---|---|
| `X-Esimplus-Signature` | `sha256=<hex>` over `{timestamp}.{raw_body}` |
| `X-Esimplus-Timestamp` | send time, Unix seconds |

## Events

**Nine events exist; eight are subscribable.** `webhook.test` is deliberately not part of the
subscribable enum, which is what makes subscribing to it impossible rather than merely
discouraged. The list is extensible — ignore unknown `event` values with a `2xx` instead of
failing.

| Event | Fires when |
|---|---|
| `sms.inbound` | An SMS arrives on one of your numbers |
| `sms.outbound.sent` | An outbound message is handed off to the carrier |
| `sms.outbound.delivered` | The carrier confirms handset delivery (**best-effort**) |
| `sms.outbound.failed` | Delivery failed (terminal) |
| `wallet.topped_up` | A wallet top-up reaches `completed` |
| `numbers.bulk_completed` | A bulk phone-number order goes terminal |
| `esims.bulk_completed` | A bulk eSIM order goes terminal |
| `esim.topped_up` | An eSIM top-up reaches `completed` (the SIM is credited) |
| `webhook.test` | A partner asks for a test from the dashboard (not subscribable) |

### `sms.inbound`

```json
{
  "event": "sms.inbound",
  "id": "01J9Z3M8Q9V2K7X4B6N0R5T1AF",
  "phone_number": "+12025550123",
  "from": "+447700900123",
  "text": "Your verification code is 481920",
  "received_at": "2026-08-05T12:34:56+00:00"
}
```

`id` unique message id (idempotency key) · `phone_number` your number that received it ·
`from` sender · `text` body · `received_at` ISO-8601 UTC.

### The outbound lifecycle — `sms.outbound.sent` / `.delivered` / `.failed`

Three events, **not one status-carrying event** — so a partner subscribed to the trio keeps
working when `blocked` and `under_review` gain producers. The status words mean exactly what
they mean in `GET /sms`: one vocabulary, never a translation table. **There is no `queued`
event** — `queued` is what `POST /sms` already answered with.

All three carry the **same four fields** and nothing more:

```json
{
  "event": "sms.outbound.sent",
  "id": "01JB9F2K7X4B6N0R5T1AFQ9V2M",
  "phone_number": "+12025550101",
  "to": "+447700900123",
  "sent_at": "2026-10-06T12:04:29+00:00"
}
```

Only the timestamp key differs: `sent_at`, `delivered_at`, `failed_at`.

- `id` is the message's ULID — the one `POST /sms` answered with, **not** the provider's
  message id. The same id appears on every lifecycle event for the message.
- `phone_number` is **your own** number (the external party is `to` here, and `from` on
  `sms.inbound`), E.164 **with** the leading `+`.
- **The payload is four fields and is not extensible in place.** No status (the event name is
  the status), no failure reason, no price, no segment count, no supplier. A partner-side test
  byte-compares the published examples, so an extra key would be a breaking change.
- **`delivered` is best-effort; its absence is not a failure.** Some providers have no receipt
  path at all. A message that never produces one stays `sent` **indefinitely** — there is no
  DLR timeout and no event when a receipt fails to arrive. Treat `sent` as the last guaranteed
  state, and never invent a client-side timeout that reports delivery failure.
- **Emitted in transition order, delivered in any order.** Each delivery is an independent job
  with its own retry schedule, so a `sent` that retried once can arrive after a `delivered`
  that succeeded immediately. Do not depend on arrival order.
- A `sms.outbound.failed` *is* always a real failure — but see `outbound-sms.md` §Money: a
  post-hand-off failure is **charged**, not released.

### `wallet.topped_up`

```json
{
  "event": "wallet.topped_up",
  "topup_id": "01J9Z3P4W2H8Y6D0C3F5G7K9BQ",
  "balance": "1549.0000",
  "balance_cents": 154900,
  "topped_up_at": "2026-08-05T12:35:10+00:00"
}
```

`balance` is the exact 4-decimal signed USD string and is the **source of truth**;
`balance_cents` is a rounded legacy projection. `topup_id` is the idempotency key.

### `esim.topped_up`

The **SIM's own** calling/data credit, never the partner wallet — only this event carries an
`icc`. Fires on credit only (never on a pending or declined top-up), after the transaction
commits.

```json
{
  "event": "esim.topped_up",
  "topup_id": "01JC1M4Q8R2T6V0X3Z5B7D9FGH",
  "icc": "8937201234567890123",
  "amount_cents": 1000,
  "balance": "22.4000",
  "topped_up_at": "2026-09-29T09:12:00+00:00"
}
```

`balance` is the SIM's balance **after** the credit, as a decimal USD string — not a number,
so no float rounding sits between the server and your ledger. **Do not assume a fixed number
of decimal places.** Polling `GET /esims/{icc}/topups` remains the guaranteed channel.

### `numbers.bulk_completed` and `esims.bulk_completed`

Identical shape, different order plane:

```json
{
  "event": "numbers.bulk_completed",
  "order_id": "01JB8ZC5K3QN7V2M4X6P9R1TDE",
  "requested": 60,
  "succeeded": 55,
  "failed": 5,
  "completed_at": "2026-08-13T10:05:00Z"
}
```

At most **one** delivery per order, carrying **no per-slot detail** — read the slots from
`GET /phone-numbers/bulk/{order_id}` or `GET /esims/bulk/{order_id}`. It is an **accelerator,
not the channel**: a partner with no subscribed endpoint receives nothing (not an error), and
an endpoint that stays down never changes the order's status. Polling remains the guaranteed
result path.

Casing is load-bearing: these bodies are snake_case even though an early draft of the
specification showed camelCase. A test pins the published side.

### `webhook.test`

```json
{
  "event": "webhook.test",
  "id": "01JD4K2P7T9M3X5V8B0D2F4HJN",
  "endpoint_id": 7,
  "sent_at": "2026-10-07T12:00:00+00:00"
}
```

One attempt, **no retries**, signed with that endpoint's secret and carrying identical headers
to a real delivery — so verifying the test verifies the real path.

## Signature verification

Compute **HMAC-SHA256** over the string `{timestamp}.{raw_body}` with **the secret of the
endpoint that received the request**, prefix `sha256=`, and compare in constant time to
`X-Esimplus-Signature`.

**Sign the raw body exactly as received.** Re-serialising parsed JSON can change bytes
(key order, whitespace, number formatting) and the comparison then fails for valid requests.
In Express use `express.raw()` / a `verify` hook, in FastAPI `await request.body()`, in
Laravel `$request->getContent()` — always before a body parser rewrites it.

Also reject a stale `X-Esimplus-Timestamp` (e.g. older than 5 minutes) to bound replay.

If you host several endpoints on one route, resolve **which secret to use** before verifying —
by path, by a query parameter you registered, or by trying each configured secret in constant
time. Do not assume one global secret.

### JavaScript (Node.js)

```js
import crypto from "node:crypto";

function verifyEsimplusWebhook(rawBody, timestamp, signatureHeader, secret) {
  const expected =
    "sha256=" +
    crypto
      .createHmac("sha256", secret)
      .update(`${timestamp}.${rawBody}`)
      .digest("hex");
  const a = Buffer.from(signatureHeader);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
```

### Python

```python
import hashlib
import hmac

def verify_esimplus_webhook(raw_body: bytes, timestamp: str, signature_header: str, secret: str) -> bool:
    signed = timestamp.encode() + b"." + raw_body
    expected = "sha256=" + hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)
```

### PHP

```php
<?php
function verify_esimplus_webhook(string $rawBody, string $timestamp, string $signatureHeader, string $secret): bool {
    $expected = 'sha256=' . hash_hmac('sha256', $timestamp . '.' . $rawBody, $secret);
    return hash_equals($expected, $signatureHeader);
}
```

Check an implementation against the bundled test vector:
`python3 scripts/verify_webhook.py --self-test`.

## Retries

Any non-`2xx` response, or a timeout, triggers a retry — up to **5 attempts**:

| Attempt | Delay before the next |
|---|---|
| 1 → 2 | 30 s |
| 2 → 3 | 60 s |
| 3 → 4 | 120 s |
| 4 → 5 | 300 s |
| after 5 | 600 s |

Returning `2xx` for an event you have chosen to ignore is correct; returning `4xx` buys you
five deliveries of the same event. `webhook.test` is the one event that is **never** retried.

## Idempotency

Handling **must** be idempotent on the event's key. The same event can be delivered more than
once; store the key with a unique constraint and let the insert be the dedupe.

| Event | Idempotency key |
|---|---|
| `sms.inbound` | `id` |
| `sms.outbound.sent` / `.delivered` / `.failed` | **`id` together with the event name** |
| `wallet.topped_up` / `esim.topped_up` | `topup_id` |
| `numbers.bulk_completed` / `esims.bulk_completed` | `order_id` |
| `webhook.test` | `id` |

**The outbound row is the one that bites.** All three lifecycle events carry the *same*
message id, so a consumer deduplicating on `id` alone discards `sms.outbound.delivered` as a
repeat of `sms.outbound.sent` and never learns the message arrived. The server keys its own
delivery rows on `(message, endpoint, event_type)` for exactly this reason.

A redelivery is **byte-identical** — payloads are rebuilt from the stored row, never from the
clock.

## Receiver checklist

```
- [ ] Capture the RAW body before any JSON parsing
- [ ] Resolve WHICH endpoint's secret applies before verifying (there may be several)
- [ ] Verify the HMAC in constant time; reject on mismatch with 401 (no retry value)
- [ ] Reject a timestamp older than ~5 minutes
- [ ] Dedupe on the event key — for sms.outbound.*, on (id, event)
- [ ] Enqueue the work and answer 2xx within 10 seconds
- [ ] Ignore unknown `event` values with a 2xx
- [ ] Read `balance` (string), not `balance_cents`, when reconciling wallet state
- [ ] Treat *.bulk_completed and *.topped_up as nudges to poll, not as the result
- [ ] Never render a missing sms.outbound.delivered as a failure
- [ ] After adding an event to the catalogue, tick it on each endpoint — nothing is implicit
```
