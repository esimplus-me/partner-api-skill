# Tokens, scopes and the four ways a request is refused

Partner API V2 gave every partner API token an expiry, a pause switch, a
rotatable secret, an identifying prefix and an **enforced scope set**. Before it, a partner's
several tokens differed only by a label. A client written against the pre-V2 API still works
— but it can now be refused for three new reasons, and all three are permanent until a human
acts in the dashboard.

## Contents
- The token value
- The scope catalogue
- Which scope each route needs
- Four refusals at four levels
- Token management is a dashboard action
- Webhook endpoints are a dashboard action

## The token value

- Issued value: the literal **`esp_live_`** followed by 40 random alphanumerics — **49
  characters**, with **no `{id}|` segment** and no environment marker. One literal in every
  environment.
- **`prefix` is literally the first 13 characters** (`esp_live_` + 4), non-secret, and is what
  identifies a credential found in a log or a config without revealing it. It **changes on
  rotation**.
- `prefix` is **`null`** on any token issued before V2 — the plaintext was never retained, so
  there is nothing to derive one from. Rotation is how such a token acquires one. Null here
  is not an error and not `""`.
- **Pre-V2 values keep working.** Resolution branches on the presence of `|`: old values
  resolve by primary key, new ones through the token column.
- Send it as `Authorization: Bearer <token>`. The legacy `X-API-TOKEN: <token>` header still
  works and is **not scope-enforced at all** (it resolves no scoped credential, so the scope
  check passes it through) — which is a reason to migrate off it, not a feature to rely
  on. It also never carries the optional upstream-provider add-on.
- `lastUsedAt` is written **synchronously on every authenticated request** — exact, not
  sampled.

## The scope catalogue

Thirteen keys, published verbatim by `GET /settings/api-token-scopes` with an English `group`
and `description` per key:

| Group | Scope | Grants |
|---|---|---|
| Phone numbers | `numbers:read` | List owned numbers, read details, browse the catalogue, price an order |
| | `numbers:write` | Buy and release numbers, including bulk orders |
| SMS | `sms:read` | List messages, read delivery statistics, price an outbound message |
| | `sms:send` | Send outbound messages |
| eSIM | `esim:read` | List eSIMs, read details and usage, browse the data-plan catalogue |
| | `esim:write` | Buy and delete eSIMs, including bulk orders |
| | `esim:credentials` | Reveal SIM credentials |
| | `esim:topup` | Top up an eSIM's balance |
| Tags | `tags:read` | List tags |
| | `tags:write` | Create and delete tags, and apply them to numbers and eSIMs |
| Wallet | `wallet:read` | Read the balance, transactions and top-up history |
| | `wallet:topup` | Open a wallet top-up with a payment provider |
| Account | `partner:read` | Read the partner profile and the discount ladder |

Scopes are stored as an **explicit list, never a wildcard**. Consequences worth knowing:

- **A new scope added to the catalogue reaches no existing token** until a partner ticks it.
  A new endpoint behind a new scope is therefore `403`/`1362` for every token that predates
  it, silently, until someone edits the token.
- **A token keeps a scope key the catalogue no longer publishes.** Scopes are derived by
  subtracting the known abilities from the stored list, so an unrecognised string is still a
  scope. Opening the editor never narrows a live token as a side effect.
- Tokens minted before V2 were migrated with the **full catalogue** — exactly what they could
  already do. No token was narrowed and no expiry was invented.

## Which scope each route needs

| Scope | Routes |
|---|---|
| `numbers:read` | `GET /phone-numbers/countries`, `.../countries/{iso}/catalog`, `GET /phone-numbers`, `GET /phone-numbers/{sid}`, `GET /phone-numbers/bulk`, `GET /phone-numbers/bulk/{orderId}`, `POST /phone-numbers/quote` |
| `numbers:write` | `POST /phone-numbers`, `POST /phone-numbers/bulk`, `DELETE /phone-numbers/{sid}` |
| `sms:read` | `GET /sms`, `POST /sms/quote`, `GET /stats/sms-received` |
| `sms:send` | `POST /sms` |
| `esim:read` | `GET /esims/destinations`, `.../destinations/{code}/catalog`, `GET /esims`, `GET /esims/{icc}`, `.../usage`, `.../topups`, `GET /esims/bulk`, `GET /esims/bulk/{orderId}`, and the `/mobile-data/*` catalogue |
| `esim:write` | `POST /esims`, `DELETE /esims/{icc}`, `POST /esims/bulk` |
| `esim:credentials` | `POST /esims/{icc}/credentials` |
| `esim:topup` | `POST /esims/{icc}/topups` |
| `tags:read` | `GET /tags` |
| `tags:write` | `POST /tags`, `DELETE /tags/{id}`, `POST /phone-numbers/tags`, `POST /esims/tags` |
| `wallet:read` | `GET /wallet`, `/wallet/transactions`, `/wallet/topups*` |
| `wallet:topup` | `POST /wallet/topups` |
| `partner:read` | `GET /partner/profile`, `GET /discount-levels` |

Note the splits that are easy to get wrong: **`POST /phone-numbers/quote` needs `numbers:read`,
not `numbers:write`** (it reads and reserves nothing), **`POST /sms/quote` needs `sms:read`,
not `sms:send`**, and **`POST /phone-numbers/tags` / `POST /esims/tags` need `tags:write`, not
the product's own write scope**.

## Four refusals at four levels

| Check | Code | HTTP | What the integrator must do |
|---|---|---|---|
| Token expired | `1360` | 401 | Mint a new token — the partner cannot undo this |
| Token paused | `1361` | 401 | Ask the partner to re-enable it in the dashboard |
| Missing scope | `1362` | 403 | Grant the scope; **the `message` names it** |
| `partner:api` on a `/settings/*` route | `1327` | 403 | Expected — that is a dashboard action |

- **Expiry is tested before pause.** A token that is both expired and disabled answers `1360`,
  never `1361` — expiry is the one the partner cannot fix by flipping a switch.
- **`1360` / `1361` are raised only for a `partner:api` credential.** A dashboard session
  expires through the same branch and must keep answering `401`/`1302`, which is the only code
  the dashboard evicts a session on.
- **All four are permanent until a human acts.** None is retryable and none is transient —
  a client that backs off and retries on `1360`–`1362` loops forever. Surface them to an
  operator.
- `1362` is **not** `1327`, and neither is `1335`: `1327` is "wrong kind of token", `1362` is
  "right token, missing scope", `1335` is "right token kind, wrong human role" (dashboard
  sessions only — a `partner:api` token has no person behind it and is never role-gated).

## Token management is a dashboard action

All of these need a `partner:dashboard` session, are **administrator-only in their entirety,
the reads included**, and answer `403`/`1327` for a `partner:api` token. Listed so you know
where a partner provisions your credential — not so you call them.

| Method | Path | Notes |
|---|---|---|
| GET | `/settings/api-token-scopes` | The catalogue above |
| GET | `/settings/api-tokens` | `ApiToken` rows — never the secret |
| POST | `/settings/api-tokens` | `201` with the **only** copy of `token`; verified email required |
| PATCH | `/settings/api-tokens/{id}` | Name, scopes, `enabled`, `expiresAt` — **never rotates** |
| POST | `/settings/api-tokens/{id}/rotate` | New `token` + new `prefix`, same id/name/scopes; verified email |
| DELETE | `/settings/api-tokens/{id}` | Verified email required (new in V2) |

- **An edit never rotates.** `PATCH` returns no secret and writes no hash — a partner fixing a
  typo in a name does not break every integration.
- **Omitted and explicit-null `expiresAt` are different requests.** Omitted leaves the expiry
  alone; `null` removes it.
- The cap is **10 tokens per partner** (`1359`, 409) and it **counts disabled and expired rows
  too** — expired tokens are deliberately never pruned, because the dashboard shows them so a
  partner can delete one to make room.
- An unknown scope key in a create/edit is `422`/`1363`, carrying `errors.scopes` with exactly
  the unrecognised keys. Ordinary field validation is a plain `422` with no `code`.
- `1324` (404) answers both an unknown id and **another partner's** id — not an oracle.
- **Changing a password or completing a reset never revokes a `partner:api` token.** Tokens
  belong to the partner, not to the person.

## Webhook endpoints are a dashboard action

Same gating (`partner:dashboard`, admin-only throughout, `1327` for an API token). The V1
single-URL routes `GET`/`PUT`/`DELETE /settings/webhook` were **removed**, not deprecated.

| Method | Path | Notes |
|---|---|---|
| GET | `/settings/webhook-events` | The subscribable event catalogue |
| GET | `/settings/webhooks` | `WebhookEndpoint` rows — never the secret |
| POST | `/settings/webhooks` | `201` with the **only** copy of `secret`; verified email |
| PATCH | `/settings/webhooks/{id}` | Name, url, events, `enabled` — **never rotates the secret** |
| POST | `/settings/webhooks/{id}/secret` | Rotate: new secret, **hard cutover, no overlap window** |
| DELETE | `/settings/webhooks/{id}` | |
| POST | `/settings/webhooks/{id}/test` | One signed `webhook.test`, synchronous, **no retries** |

Details of the collection model and the delivery contract are in `webhooks.md`.
