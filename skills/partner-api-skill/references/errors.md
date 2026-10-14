# Errors: two envelopes and the domain-code table

## Contents
- The two envelopes
- Complete domain-code table
- Per-endpoint dispatch matrix
- How to write the handler

## The two envelopes

The API answers failures in **two structurally different shapes**. A client that models only
one of them mishandles the other.

**Envelope A — domain errors.** Raised by business/domain exceptions. Carries a numeric
`code` at the **top level**. This is the value to switch on.

```json
{
  "success": false,
  "status": 404,
  "message": "Wallet top-up not found.",
  "code": 1321,
  "errors": []
}
```

`errors` is `[]` for almost every code. Only two populate it:
`1304` → `{ "isoCodes": [...] }`, `1314` → `{ "code": "<regionCode>" }`.

**Envelope B — framework errors.** Raised by request validation (`422`), SSRF rejection and
rate limiting (`429`). **No `code`, no per-field error map** — a single `message`.

```json
{ "status": 422, "message": "The email field is required.", "data": null }
```

There is no field-level error map on a `422`. Do not build UI that reads `errors.<field>`;
dispatch on `message` when you must distinguish validation causes.

`errors` is also populated by `1363` → `{ "scopes": [...] }` (the unrecognised keys).

**Never dispatch on the HTTP status alone.** One status carries several codes — a `422` can
be `1304`, `1306`, `1310`, `1322`, `1326`, `1350`, `1352`–`1355`, `1357`, `1363`, or Envelope
B with no code at all; a `404` can be `1307`, `1311`, `1321`, `1324`, `1325`, `1329`,
`1341`–`1343` or `1348`; a `401` can be `1301`, `1302`, `1303`, `1319`, `1360` or `1361`.

## Complete domain-code table

Codes are globally unique across the partner API — the registry is **flat across submodules**
while the enums are per-submodule, so a collision is only visible to a meta-test that scans
them all. Codes `1316`–`1318`, `1320` and `1328` are **retired and will never be emitted** —
an old client-side table mis-mapped them, so do not revive a meaning for them. `1330`–`1340`
are the dashboard account surface and `1359`–`1363` the token lifecycle, both listed
separately below; the next free code is `1364`.

`1341`–`1348` are the eSIM plane (detailed in `esim.md`), `1349`–`1351` the webhook endpoint
collection (`webhooks.md`), `1352`–`1358` outbound SMS (`outbound-sms.md`). An early draft of
outbound SMS used `1341`–`1347`; that numbering is **dead** and a client carrying it maps one
error onto another's message.

| code | HTTP | message | Raised by |
|---|---|---|---|
| 1301 | 401 | Partner not found. | auth |
| 1302 | 401 | Unauthenticated. | any authed route — missing / invalid / expired token |
| 1303 | 403 | Partner is disabled. | auth |
| 1304 | 422 | One or more country ISO codes are invalid. *(`errors.isoCodes`)* | catalog |
| 1305 | 403 | Country is not available for this partner. | catalog, buy, quote |
| 1306 | 422 | Unable to determine country from the provided msisdn. | buy; also `GET /phone-numbers` with an empty `country` filter |
| 1307 | 404 | Phone number is not available for purchase. | buy |
| 1308 | 409 | Phone number has already been purchased. | buy |
| 1309 | 502 | Phone number purchase failed. | buy — **funds are not charged** |
| 1310 | 422 | Regulated phone numbers are not supported for partners. | buy |
| 1311 | 404 | Phone number not found. | number details, release |
| 1312 | 409 | Phone number cannot be released in its current status. | release |
| 1313 | 404 | No mobile data bundles found for the specified destination. | mobile-data (not part of the numbers surface) |
| 1314 | 404 | The specified region was not found. *(`errors.code`)* | mobile-data |
| 1315 | 402 | Insufficient wallet balance. | buy / bulk accept / per bulk slot — only when `wallet_enforced` |
| 1319 | 401 | Invalid login credentials. | dashboard login |
| 1321 | 404 | Wallet top-up not found. | top-up read |
| 1322 | 422 | Unsupported or disabled top-up provider. | create top-up |
| 1323 | 502 | Payment provider failed to create the invoice. | create top-up |
| 1324 | 404 | API token not found. | delete api-token (dashboard) |
| 1325 | 404 | Webhook not found. | delete webhook (dashboard) |
| 1326 | 422 | Invalid tag data. | create tag, bulk-apply tags |
| 1327 | 403 | This token is not permitted to access this resource. | a `partner:api` token on a dashboard-only route |
| 1329 | 404 | Bulk purchase order not found. | `GET /phone-numbers/bulk/{orderId}` — unknown id **or** another partner's order |
| 1341 | 404 | eSIM destination is unknown or no longer available. | eSIM catalog, buy, bulk slot |
| 1342 | 404 | eSIM offer is no longer available. | eSIM buy, bulk slot — a **real race**, the catalog reserves nothing |
| 1343 | 404 | eSIM not found. | eSIM detail, delete, usage, credentials, top-ups |
| 1344 | 409 | eSIM cannot be deleted in its current status. | `DELETE /esims/{icc}` |
| 1345 | 502 | eSIM profile could not be issued. Nothing was charged. | eSIM buy, bulk slot — kept separate from `1309` |
| 1346 | 409 | eSIM credentials are temporarily unavailable. | `POST /esims/{icc}/credentials` — **retryable** |
| 1347 | 409 | Payment provider rejected this amount for this eSIM. | `POST /esims/{icc}/topups` — also for an unknown provider slug |
| 1348 | 404 | Bulk eSIM order not found. | `GET /esims/bulk/{orderId}` — unknown **or** another partner's |
| 1349 | 422 | You have reached the maximum number of webhook endpoints. | dashboard: create endpoint (cap 10) |
| 1350 | 422 | One or more requested event keys are not recognised. | dashboard: create/edit endpoint |
| 1351 | 409 | This endpoint is paused. Resume it before sending a test. | dashboard: test delivery |
| 1352 | 422 | Blocked by content policy. | `POST /sms` — **reserved, no producer today** |
| 1353 | 422 | Recipient has opted out. | `POST /sms` — **reserved, no producer today** |
| 1354 | 422 | This phone number cannot send SMS. | `POST /sms`, `POST /sms/quote` |
| 1355 | 422 | Sending to this destination is not permitted. | `POST /sms` — **reserved, no producer today** |
| 1356 | 409 | Idempotency key already used for a different message. | `POST /sms` |
| 1357 | 422 | Invalid SMS data. *(`message` is the specific field error)* | `POST /sms`, `POST /sms/quote` |
| 1358 | 502 | SMS provider temporarily unavailable. | allocated, **unreachable** while the hand-off is async |

`1315` only exists for partners with the per-partner `wallet_enforced` flag on (off by
default). While it is off, buying never returns `1315` and touches no wallet balance.

### `1330`–`1340` — dashboard account surface (not reachable with a `partner:api` token)

Registration, email verification, password recovery, invitations and user management are
**dashboard-session routes**. A `partner:api` token on any of them gets `403` / `1327`
before the route's own logic runs, so an integration never sees these codes. They are listed
so that the table stays the complete map of the code space and no future allocation collides.

| code | HTTP | meaning | i18n key |
|---|---|---|---|
| 1330 | 409 | Email is already registered | `errors.emailTaken` |
| 1331 | 410 | Invite token invalid, expired or already used | `errors.inviteInvalid` |
| 1332 | 403 | Action requires a verified email | `errors.emailNotVerified` |
| 1333 | 410 | Verification token invalid, expired or already used | `errors.verificationInvalid` |
| 1334 | 410 | Password-reset token invalid, expired or already used | `errors.resetInvalid` |
| 1335 | 403 | Your role is not allowed to do this | `errors.forbiddenRole` |
| 1336 | 404 | User not found in this partner | `errors.userNotFound` |
| 1337 | 409 | A partner must keep at least one active admin | `errors.lastAdmin` |
| 1338 | 403 | This user account is disabled | `errors.userDisabled` |
| 1339 | 409 | A pending invite for this address already exists | `errors.inviteExists` |
| 1340 | 409 | Invite cannot be resent — the person is no longer `invited` | `errors.inviteResendUnavailable` |

Two facts from this surface that matter even though the routes do not:

- **`1335` and `1327` are different failures.** `1335` is "right kind of token, wrong role";
  `1327` is "wrong kind of token". Only `1327` can ever reach a `partner:api` client.
- **A domain error's `code` is not always a `13xx`.** The weak-password rejection on those
  routes is Envelope A with `code: 422` — a code equal to the HTTP status. A handler that
  assumes `code >= 1300` will mis-bucket it. Nothing on the integration surface does this
  today, but do not encode the assumption.

Changing a password (or completing a reset) **revokes every dashboard session of that user
and leaves the partner's `partner:api` tokens working** — tokens belong to the partner, not
to the person. An integration is never logged out by an account action.

### `1359`–`1363` — API token lifecycle

Three of these **can hit a live integration on any route**, which is what makes them
different from every other block in this table.

| code | HTTP | meaning | What to do |
|---|---|---|---|
| 1359 | 409 | Token limit reached (10 per partner, counting disabled and expired rows) | dashboard-only |
| 1360 | 401 | This API token has expired | mint a new token — the partner cannot undo this |
| 1361 | 401 | This API token is disabled (paused) | ask the partner to re-enable it |
| 1362 | 403 | This token lacks the required scope: `<scope>` | grant the named scope |
| 1363 | 422 | One or more requested scopes are not recognised *(`errors.scopes`)* | dashboard-only |

- **Expiry is tested before pause**: a token that is both expired and disabled answers `1360`.
- `1360`/`1361` are raised **only for a `partner:api` credential** — a dashboard session
  expiring still answers `401`/`1302`.
- **None of the three is retryable.** They are permanent until a human acts in the dashboard;
  a backoff loop on them never terminates. Alert, do not retry.
- The legacy `X-API-TOKEN` header resolves no scoped credential and is therefore **not
  scope-enforced at all** — it never produces `1362`.

## Per-endpoint dispatch matrix

| Call | Codes worth handling explicitly |
|---|---|
| any authenticated call | `1302` re-auth / alert, `1303` partner disabled — stop retrying |
| `GET …/catalog` | `1304` bad ISO (read `errors.isoCodes`), `1305` country not sold to you |
| `POST /phone-numbers` | `1315` top up, `1308` pick another number, `1307` gone — refresh the catalog, `1306`/`1310` bad msisdn — do not retry, `1309` upstream failure — **safe to try another number, nothing was charged** |
| `POST /phone-numbers/quote` | `1305`; note this check is **stricter** than the accept path, so a draft can quote `403` and still submit |
| `POST /phone-numbers/bulk` | `1315` (no order created — retry after top-up), Envelope B `422` for cap violations and for a replayed `Idempotency-Key` with a different body |
| `GET /phone-numbers/bulk/{orderId}` | `1329` unknown/foreign order. Per-slot `error.code` lives inside a `200` — see `bulk-and-pricing.md` |
| `DELETE /phone-numbers/{sid}` | `1311` not found, `1312` not releasable — leave the UI unchanged and show the reason |
| tags | `1326` — a duplicate name, an invalid color, or a sid/tag/icc id you do not own |
| `POST /sms` | `1315` top up, `1311` not your number, `1354` that number cannot send — pick another, `1356` key reused with a different body — **use a new key**, `1357` malformed (`message` is the field error). No `502`, no `1327` |
| `POST /sms/quote` | `1311`, `1354`, `1357` — the same ownership and sendability refusals as the send path |
| `POST /esims` | `1315`, `1341`/`1342` catalog moved on — re-fetch, `1345` nothing charged — safe to try another offer, `1332` unverified email |
| `GET /esims/{icc}` and sub-routes | `1343`; `1346` on credentials is **retryable**; `1344` on delete |
| `POST /esims/{icc}/topups` | `1347` amount/provider pairing — try another provider or amount, `1335` member role, `1332` unverified email |
| `GET /esims/bulk/{orderId}` | `1348` (**not** `1329` — different plane) |
| wallet top-up | `1322` provider, `1323` provider outage — retriable, `1321` unknown top-up id |
| any authenticated call, on a scoped token | `1360` expired, `1361` paused, `1362` missing scope — **all three are terminal**, surface to an operator |
| a dashboard-only route with a `partner:api` token | `1327` — expected. The dashboard-only families are `/settings/*`, `DELETE /auth/session`, the public auth routes (`/auth/register`, `/auth/email/verify*`, `/auth/password/*`, `/auth/invites/*`) and the account routes (`/partner/users*`, `/partner/me*`) |

## How to write the handler

1. On a non-2xx, parse the body once.
2. If it has a numeric `code` → Envelope A: switch on `code`.
3. Otherwise → Envelope B: use `status` + `message`.
4. Treat `429` as transient (Envelope B): back off and retry — nothing was rejected on merit.
   **The response carries no `Retry-After` and no `X-RateLimit-*` header** — the exception
   handler rebuilds the body and drops the exception's headers. Your backoff schedule is a
   client-side convention; do not write code that reads a wait time off the response.
5. Retry safely only for `429`, `1323`, `1346`, and read-path `5xx`. **Never** auto-retry
   `POST /phone-numbers` or `POST /esims` (the latter *ignores* an `Idempotency-Key`); retry
   `POST /phone-numbers/bulk`, `POST /esims/bulk` and `POST /sms` only with the *same*
   `Idempotency-Key`.
6. Never retry `1360`, `1361` or `1362` — they are permanent until a human acts.

```python
def raise_for_partner_error(status: int, body: dict) -> None:
    code = body.get("code")
    if isinstance(code, int):                      # Envelope A
        raise PartnerDomainError(code=code, status=status, message=body.get("message", ""),
                                 details=body.get("errors") or [])
    raise PartnerRequestError(status=status,       # Envelope B
                              message=body.get("message", "Request rejected."))
```
