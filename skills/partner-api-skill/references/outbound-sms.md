# Outbound SMS (`POST /sms`, `POST /sms/quote`)

`GET /sms` is no longer
inbound-only — it lists **both directions**, interleaved chronologically.

## Contents
- Who may send, and from which numbers
- The two spellings of one number
- `POST /sms/quote`
- `POST /sms`
- Idempotency
- Money
- Segments
- Lifecycle
- `GET /sms` with outbound rows
- Error codes

## Who may send, and from which numbers

- Scope: **`sms:send`** for sending, **`sms:read`** for listing and quoting.
- **Both token kinds may send** (`partner:api` and `partner:dashboard`) and there is **no role
  gate** — a `member` may send exactly as a member may buy and release numbers.
- **There is no `403`/`1327` on the send route.** A token holding neither kind fails
  *authentication* and answers `401`/`1302`; it never reaches the route. A contract promising
  `1327` here is describing a response the code cannot produce.
- A number may originate when it is yours, `status == 1` (active), carries the `sms`
  capability, **and sits on a provider that can send**. That last clause is invisible in
  `GET /phone-numbers`: an owned, active, `sms`-featured number on a non-sending provider
  answers `422`/`1354`. Filter the picker on
  `status === 1 && features ∋ sms` and handle `1354` as the residual case.
- **An unowned `from` and an unknown `from` answer identically** — one `404`/`1311`. It is not
  an existence oracle.

## The two spellings of one number

`GET /phone-numbers` emits `msisdn` as **bare digits** (`12025550101`). Every SMS surface
emits `from` / `to` as **E.164 with `+`** (`+12025550101`).

- `POST /sms` and `POST /sms/quote` accept **either** form and canonicalise to `+E.164` on the
  way in, so `GET /sms` never shows two spellings of one number.
- The divergence is therefore only *between* the two endpoints. **Compare by digits — the `+`
  is presentational, the digits are the identity.** A client comparing them with `===`
  rejects every number the partner owns.
- Adding `+` to `GET /phone-numbers` would break a published V1 field and is deliberately not
  done.

## `POST /sms/quote`

Prices a message without sending it. A `POST` because the body carries the text, but it
**reads without writing**: nothing is stored, held or queued, it is safe to repeat, and it
takes **no `Idempotency-Key`**. Its own rate bucket (120/min), separate from sending, so
re-pricing a draft cannot lock a partner out of sending it.

```json
// request
{ "from": "12025550101", "to": "+447700900123", "text": "Your code is 481920" }
// 200
{ "data": { "segments": 1, "encoding": "GSM7",
            "unitPriceMinor": 1, "totalPriceMinor": 1, "currency": "USD" } }
```

- The answer is an **estimate** — pricing is recalculated at acceptance. Present it as one and
  do not block a send on it.
- It applies the **same ownership and sendability refusals** the send path does, from the same
  objects (`404`/`1311`, `422`/`1354`) — a quotable-but-unsendable number would be the
  interface contradicting itself.
- It performs **no content/policy evaluation** and leaks no policy verdict, deliberately: a
  quote that revealed "this text would be blocked" is a free policy-probing oracle.
- Errors: `404`/`1311`, `422`/`1357` or `1354`, `429` (own bucket, no `Retry-After`).

## `POST /sms`

Throttled 60/min on its own bucket. **Answers `202`, not `201`.**

```json
// header: Idempotency-Key: <1..255 chars>   (REQUIRED)
{ "from": "12025550101", "to": "+447700900123", "text": "Your code is 481920" }
// 202 → { "data": <Sms with direction "sent", status "queued"> }
```

- The hand-off is **asynchronous** — the endpoint answers before any provider is called, so a
  provider outage is never an HTTP error here. It surfaces later as `status: failed` on the
  message. **There is no `502` on this route**, and `1358` (provider unavailable) is allocated
  but unreachable while the hand-off stays asynchronous.
- The message is immediately visible through `GET /sms` with `direction: sent`,
  `status: queued`.
- `from` is an **msisdn, not a `sid`** — every SMS row already speaks msisdn, and a partner
  knows their numbers by phone number.

### Two independent ceilings on `text`

**1530 characters** *and* **10 segments**, neither implied by the other. For GSM-7 the two
coincide; 1530 Cyrillic characters is roughly 23 segments and is refused despite satisfying
`maxLength`. Both are checked **before** anything is written, charged or queued, and both
answer `422`/`1357`. `text` may not be empty (unlike an inbound message's `text`).

## Idempotency

`Idempotency-Key` is **required** (1–255 chars); absent is a refusal. This is the most
billing-sensitive mutation on the partner plane — a network retry without a key sends and
charges twice.

| Case | Result |
|---|---|
| Same key, same body | `200` with the original message. Nothing sent, nothing charged, no job queued. |
| Same key, different body | `409`/`1356`. Nothing sent — use a new key. |
| New key | A new message, `202`. |

**The replay is evaluated before the wallet and before the insert.** A retry after a timeout
returns the original message even if the balance has since run out — it does not re-litigate a
decision that changed in the meantime. Keys are scoped to the partner.

## Money

- Affordability is checked against **`availableBalance`** (unfrozen), never the raw balance.
  Short → `402`/`1315`, and **nothing is created**: no row, no hold, no job.
- Acceptance **freezes** the exact cost; a successful hand-off **consumes** the hold; any
  failure *before* hand-off **releases** it. Nothing that never reached a carrier is charged.
- **A post-hand-off failure is charged, not released.** A negative delivery receipt arrives
  after `consumeFrozen` has already run, and the receipt path does no wallet work. So a
  `sms.outbound.failed` can carry a non-zero `priceMinor` on a message the partner never
  delivered. The payload does not distinguish the two failure paths.
- Only `wallet_enforced` partners are gated and charged; others still receive `priceMinor`.
- **Charged per segment**, not per message.

### Why `priceMinor` and `totalPriceMinor` look wrong

The wallet is charged the **exact decimal**; the API reports **integer minor units**. On a
sub-cent message `priceMinor` is a **rounding of what was charged, not the charge** — a
message costing $0.0060 reports `priceMinor: 1`.

For the same reason **`totalPriceMinor` is not `unitPriceMinor × segments`**, and must not be
recomputed as such. Both are roundings of exact values, and the total is projected from the
exact decimal so that it equals the `priceMinor` the accepted message reports. At $0.006 a
segment, two segments are `unitPriceMinor: 1` and `totalPriceMinor: 1`, because the real
charge is $0.012. Multiplying overstates a sub-cent invoice by up to 100 %. **Render the
returned value.**

## Segments

| Encoding | Single | Concatenated part |
|---|---|---|
| GSM-03.38 7-bit | 160 | 153 |
| UCS-2 | 70 | 67 |

- The GSM-7 extension set `^ { } [ ] ~ \ | €` costs **two septets** each; a surrogate pair
  costs two UTF-16 units.
- **Packing is greedy and a two-unit character may not straddle a part boundary.**
  `ceil(total / capacity)` is wrong and **under-counts**: on `152×a + € + 152×a` it answers 2
  where the truth is 3, so the provider splits into three parts while the invoice says two.
  (Several widely copied vendor helpers use the `ceil` form — do not copy them.)
- Any character outside the GSM-03.38 alphabet (Cyrillic, most emoji) forces UCS-2 and more
  than halves the characters per segment.
- `SmsEncoding` is `GSM7 | UCS2`.

## Lifecycle

`queued → sent → delivered`, with `failed` and `blocked` as terminal exits.

**`SmsStatus` is published wider than what is produced today**: `queued`, `under_review`,
`sent`, `delivered`, `failed`, `blocked`. Adding a value to a published enum is a breaking
change for a partner switching exhaustively, so the vocabulary is fixed now and filled in
later. **Reachable today: `queued → sent` and `queued → failed`**, plus `delivered` from the
delivery-receipt path. `blocked`, `under_review` and all six `SmsBlockedReason` values
(`content_policy`, `sending_pattern`, `recipient_opted_out`, `recipient_blocked`,
`destination_not_permitted`, `manual_review`) ship **with no producer** — there is no
antifraud pipeline and no opt-out list. Build for them; expect three.

**`delivered` is best-effort and its absence is not a failure.** A delivery receipt is
something the upstream provider chooses to send; some providers have no receipt path at all,
and a partner neither chooses nor sees its provider. **There is no DLR timeout**: a `sent`
message that never gets a receipt stays `sent` indefinitely and emits no terminal event.
Treat `sent` as the last state the platform guarantees — a missing follow-up means *unknown*,
never *failed* — and never invent a client-side timeout that reports failure.

Receipts are **terminal and apply only to a `sent` message**. A repeated receipt, a late
receipt for an already-terminal message, or the loser of two racing receipts updates nothing
and emits nothing.

## `GET /sms` with outbound rows

Outbound fields were added **additively**: every pre-existing field still exists and still
means what it meant. `direction` is now `received | sent` and the list **interleaves both**.
Filter with `direction` when you want one.

Every outbound-only field is **absent, not `null`**, when it does not apply — on an inbound
row, and on an outbound row whose value is not set yet. **Test for presence, not for null.**

| Field | Notes |
|---|---|
| `status` | Present only when `direction` is `sent`; an inbound message has no lifecycle. |
| `blockedReason` / `blockedDetail` | Only when `status` is `blocked` (no producer today). |
| `segments` | Billed segment count, outbound only. |
| `encoding` | `GSM7` \| `UCS2`, outbound only. |
| `priceMinor` / `currency` | Integer minor units, outbound only — a rounding, see Money. |
| `sentAt` / `deliveredAt` / `failedAt` | Present from the matching transition onward. |

**`receivedAt` is the one sortable and filterable time field for both directions** — "when the
platform recorded this message": when it arrived, for inbound; when it was accepted, for
outbound. The name is inherited, not descriptive. It is what lets the two directions
interleave in one chronological list; do not treat its presence on a `sent` row as a bug.

## Error codes

| code | HTTP | Meaning | Produced today? |
|---|---|---|---|
| 1352 | 422 | Blocked by content / sending-pattern checks — an appealable judgement | no (reserved) |
| 1353 | 422 | The recipient has opted out of messages from this number | no (reserved) |
| 1354 | 422 | This number cannot send SMS (provider does not support outbound) | **yes** |
| 1355 | 422 | Your account is not enabled for this destination | no (reserved) |
| 1356 | 409 | Idempotency key reused with a different body | **yes** |
| 1357 | 422 | Malformed request — key, msisdn, empty `text`, or either ceiling | **yes** |
| 1358 | 502 | SMS provider temporarily unavailable | no (unreachable while async) |

Reused unchanged: `1302`, `1311`, `1315`, `1327`.

- `message` is a **finished, partner-facing sentence** for every one of these and is safe to
  show verbatim. For `1357`, and only `1357`, `message` is the **specific field error**
  rather than a fixed sentence.
- `errors` is always `[]` on these endpoints — it is **not** a per-field map. Do not build
  field-level UI from it.
- **`1306` and `1309` are deliberately not reused** here. In this backend they are
  `INVALID_MSISDN` and `PHONE_NUMBER_PURCHASE_FAILED` and belong to number purchase; reusing
  them would route one error to another error's message.
- The block starts at `1352` because `1341`–`1348` are eSIM and `1349`–`1351` are the webhook
  endpoints. An earlier draft of this feature used `1341`–`1347`; that numbering is dead.
