# Fitting the integration into the host project

The rule this file serves: **the host project's architecture wins.** This skill supplies the
API contract; the surrounding codebase supplies the form. Run this before step 1 of the
workflow — it is cheap and it is what stops the integration from reading like a pasted
snippet.

## Contents
- Discovery procedure
- What to mirror
- Declare the plan before coding
- Conflicts worth escalating
- Per-stack notes

## Discovery procedure

1. **Read the project's own instructions.** `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`,
   `docs/`, ADRs, lint/formatter config. These outrank everything in this skill except the
   wire contract and the safety rules.
2. **Find the closest precedent** — an existing client for another third-party HTTP API
   (payments, mail, SMS, CRM). Grep for the project's HTTP entry points, e.g.
   `HttpClient|axios|fetch(|requests\.|Guzzle|http\.Client|RestTemplate|Faraday`, and for
   `Authorization` / `Bearer` to see how outbound credentials are already attached. That
   precedent is your template.
3. **Locate the seams** you must plug into: where config/secrets come from, where errors are
   translated for the caller, where retries and timeouts are decided, how outbound calls are
   logged/traced, how dependencies are wired, where the tests for such a client live and how
   they fake HTTP.
4. **Only then choose file locations and names**, matching the layering and naming already in
   use — not the layout implied by this skill's examples.

If the project has **no** precedent for an outbound API client, say so, propose the smallest
structure consistent with its existing idiom, and let the maintainer confirm before you
spread it across files.

## What to mirror

| Seam | Follow the project's answer, not this skill's example |
|---|---|
| HTTP client | Reuse the library and the shared instance/factory already there. Never add a second HTTP library. |
| Base URL & token | Use the existing config/env/secret-manager mechanism. Never hard-code either, never read `process.env` / `os.environ` inline if the project has a config object. |
| Error model | Translate the two envelopes (`references/errors.md`) into the project's own error/exception type at the client boundary; do not leak raw response bodies upward. Keep the numeric domain `code` on the translated error — callers dispatch on it. |
| Retries & timeouts | Adopt the project's policy, with the exemptions below. |
| Serialization | Match its casing/DTO conventions (mapper, schema library, generated types). Map the API's camelCase and the webhooks' snake_case at the boundary, then use the project's own naming inward. |
| Logging & tracing | Same logger, same correlation-id propagation, same redaction rules — the token and the webhook secret are secrets. |
| Wiring | Same DI/registration/module pattern; no ad-hoc singletons or import-time side effects. |
| Money & time types | Use the project's existing money and datetime types. Feed them from the exact `*Decimal` strings, not the rounded integers. |
| Tests | Same framework, same fake-HTTP approach (recorded fixtures, MSW, VCR, a stub server), same layout. |
| Async work | Bulk polling and webhook processing belong in the project's existing queue/scheduler, not in a hand-rolled thread or a request-blocking loop. |
| Persistence | Store `sid`, `orderId`, top-up `id` and webhook event keys through the project's data layer, with the unique constraint the dedupe rule needs. |

## Declare the plan before coding

Before the first edit, state briefly:

- the precedent you are following (files);
- where the new code goes (paths);
- which seams you plug into (config, errors, logging, queue, tests);
- any exemption you are claiming from a project convention, and why.

Two or three sentences. This is the artifact the reviewer checks, and it costs less than
rewriting a misplaced client.

## Conflicts worth escalating

Follow the project — except where a convention would break the API contract or a safety
rule. In those cases carve out the narrowest exception and say it out loud:

- **A blanket "retry all failed requests" wrapper** must not cover `POST /phone-numbers` (not
  idempotent — a retry buys and charges for a second number). Exempt that one call, or
  restrict the wrapper to reads.
- **A generic "retry on 5xx/429 with the same body" wrapper** over
  `POST /phone-numbers/bulk` must reuse the *same* `Idempotency-Key`; regenerating it per
  attempt duplicates orders.
- **A global JSON body-parsing middleware** breaks webhook signature verification — the
  signature is over the raw bytes. Register a raw-body route/exception for the webhook path.
- **A shared HTTP client with a default query serializer** will emit `?tags=1&tags=2`, which
  the API rejects; array params need `?tags[]=1&tags[]=2`. Override the serializer for this
  client rather than patching call sites.
- **A strictly typed `int` money field** (project convention or generated model) breaks on
  `2.1`; amounts are numbers that may arrive integral or fractional.
- **A "fail fast on any non-2xx" policy** mishandles the bulk status endpoint: per-slot
  failures arrive inside a `200`, and partial success is the normal outcome.
- **A "credit on redirect" payment convention** must not be applied to top-ups — the wallet
  is credited server-side; poll the top-up until `completed`.

## Per-stack notes

Illustrative, not prescriptive — the point is to find the project's answer, not to adopt these.

- **TypeScript / Node.** If the project generates types from OpenAPI, generate from
  `assets/partner-api.openapi.yaml` instead of hand-writing interfaces, and keep the
  generated file where its other generated code lives. Match its fetch wrapper; supply a
  custom `querySerializer` for bracket arrays. Webhooks: raw-body handler (`express.raw`, a
  `verify` hook, or the framework's equivalent).
- **PHP / Laravel.** A dedicated client class behind an interface, registered in a service
  provider, configured through `config/*.php` reading env — not `env()` calls at runtime.
  Translate errors into the project's exception hierarchy. Webhooks: read
  `$request->getContent()`, verify with `hash_equals`, dispatch a queued job.
- **Python.** Follow the project's session/client pattern (`requests.Session`, `httpx.Client`,
  async or sync — do not mix), its settings object (pydantic-settings, Django settings), and
  its retry helper. Webhooks: `await request.body()` before parsing.
- **Go / Java / C#.** Constructor-injected client with an interface for tests, options struct
  or configuration binding for base URL and token, context/timeout propagation as the project
  already does it, decoding amounts into a decimal type from the `*Decimal` strings.
