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

**Never dispatch on the HTTP status alone.** One status carries several codes — a `422` can
be `1304`, `1306`, `1310`, `1322`, `1326`, or Envelope B with no code at all; a `404` can be
`1307`, `1311`, `1321`, `1324`, `1325`, or `1329`.

## Complete domain-code table

Codes are globally unique across the partner API. Codes `1316`–`1318`, `1320` and `1328` are
**retired and will never be emitted** — an old client-side table mis-mapped them, so do not
revive a meaning for them. The next free code is `1330`.

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

`1315` only exists for partners with the per-partner `wallet_enforced` flag on (off by
default). While it is off, buying never returns `1315` and touches no wallet balance.

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
| tags | `1326` — a duplicate name, an invalid color, or a sid/tag id you do not own |
| wallet top-up | `1322` provider, `1323` provider outage — retriable, `1321` unknown top-up id |
| `/settings/*` with a `partner:api` token | `1327` — expected; these are dashboard-only |

## How to write the handler

1. On a non-2xx, parse the body once.
2. If it has a numeric `code` → Envelope A: switch on `code`.
3. Otherwise → Envelope B: use `status` + `message`.
4. Treat `429` as transient (Envelope B): back off and retry — nothing was rejected on merit.
5. Retry safely only for `429`, `1323`, and read-path `5xx`. **Never** auto-retry
   `POST /phone-numbers`; retry `POST /phone-numbers/bulk` only with the *same*
   `Idempotency-Key`.

```python
def raise_for_partner_error(status: int, body: dict) -> None:
    code = body.get("code")
    if isinstance(code, int):                      # Envelope A
        raise PartnerDomainError(code=code, status=status, message=body.get("message", ""),
                                 details=body.get("errors") or [])
    raise PartnerRequestError(status=status,       # Envelope B
                              message=body.get("message", "Request rejected."))
```
