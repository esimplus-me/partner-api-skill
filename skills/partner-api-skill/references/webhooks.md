# Webhooks (eSIM Plus → your endpoint)

## Contents
- Delivery
- Events
- Signature verification
- Retries
- Idempotency
- Receiver checklist

## Delivery

One endpoint per partner, configured in the dashboard (Settings → Webhook). A second
configuration **rotates** it, it does not append — there is exactly one active endpoint, and
the signing secret is returned **once**, when the URL is saved. The URL must be `https` with a
public host (SSRF-validated).

- Method `POST`, `Content-Type: application/json`.
- Body keys are **snake_case** — the one place the API is not camelCase.
- The event type is in the `event` field of the body.
- Request timeout: **10 seconds**. Answer fast: enqueue and return, do not process inline.
- Headers:

| Header | Meaning |
|---|---|
| `X-Esimplus-Signature` | `sha256=<hex>` over the body (see below) |
| `X-Esimplus-Timestamp` | send time, Unix seconds |

## Events

The list is extensible — ignore unknown `event` values instead of failing.

### `sms.inbound`

```json
{
  "event": "sms.inbound",
  "id": "01J9Z3M8Q9V2K7X4B6N0R5T1AF",
  "phone_number": "+12025550123",
  "from": "+447700900123",
  "text": "Your verification code is 481920",
  "received_at": "2026-08-05T12:34:56Z"
}
```

`id` unique message id (idempotency key) · `phone_number` your number that received it ·
`from` sender · `text` body · `received_at` ISO-8601 UTC.

### `wallet.topped_up`

```json
{
  "event": "wallet.topped_up",
  "topup_id": "01J9Z3P4W2H8Y6D0C3F5G7K9BQ",
  "balance": "1549.0000",
  "balance_cents": 154900,
  "topped_up_at": "2026-08-05T12:35:10Z"
}
```

`balance` is the exact 4-decimal signed USD string and is the **source of truth**;
`balance_cents` is a rounded legacy projection. `topup_id` is the idempotency key.

### `numbers.bulk_completed`

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

At most **one** delivery per order, and it carries **no per-slot detail** — read the slots
from `GET /phone-numbers/bulk/{order_id}`. It is an **accelerator, not the channel**: a
partner with no active endpoint receives nothing (not an error), and an endpoint that stays
down never changes the order's status. Polling remains the guaranteed result path.

## Signature verification

Compute **HMAC-SHA256** over the string `{timestamp}.{raw_body}` with the endpoint secret,
prefix `sha256=`, and compare in constant time to `X-Esimplus-Signature`.

**Sign the raw body exactly as received.** Re-serialising parsed JSON can change bytes
(key order, whitespace, number formatting) and the comparison then fails for valid requests.
In Express use `express.raw()` / a `verify` hook, in FastAPI `await request.body()`, in
Laravel `$request->getContent()` — always before a body parser rewrites it.

Also reject a stale `X-Esimplus-Timestamp` (e.g. older than 5 minutes) to bound replay.

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
five deliveries of the same event.

## Idempotency

Handling **must** be idempotent on the event's key — `id` for `sms.inbound`, `topup_id` for
`wallet.topped_up`, `order_id` for `numbers.bulk_completed`. The same event can be delivered
more than once and double-processing must not double-apply any effect. Store the key with a
unique constraint and let the insert be the dedupe.

## Receiver checklist

```
- [ ] Capture the RAW body before any JSON parsing
- [ ] Verify the HMAC in constant time; reject on mismatch with 401 (no retry value)
- [ ] Reject a timestamp older than ~5 minutes
- [ ] Dedupe on the event key with a unique constraint
- [ ] Enqueue the work and answer 2xx within 10 seconds
- [ ] Ignore unknown `event` values with a 2xx
- [ ] Read `balance` (string), not `balance_cents`, when reconciling wallet state
- [ ] Treat `numbers.bulk_completed` as a nudge to poll, not as the result
```
