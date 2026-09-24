<div align="center">

# 📱 eSIM Plus Partner API — agent skill

**Ship a correct integration with the eSIM Plus Partner API on the first try.**

Virtual numbers · bulk orders · inbound SMS · wallet · signed webhooks

[![Agent Skill](https://img.shields.io/badge/Agent%20Skill-open%20standard-6b5bd6)](https://agentskills.io/specification)
[![Skill](https://img.shields.io/badge/skill-partner--api--skill-2253f5)](skills/partner-api-skill/SKILL.md)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757)](#install-as-a-plugin-claude-code)
[![API](https://img.shields.io/badge/API-partner%2Fv1-1f6feb)](skills/partner-api-skill/assets/partner-api.openapi.yaml)
[![Scripts](https://img.shields.io/badge/scripts-python%203.9%2B%20stdlib-3776ab)](skills/partner-api-skill/scripts/)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

</div>

---

An [Agent Skill](https://agentskills.io/specification) that teaches a coding agent (Claude
Code, Cursor, Codex, or anything that reads the open-standard `SKILL.md` format) how to
integrate the **eSIM Plus Partner API** correctly: bearer auth, the virtual-number catalog,
single and bulk purchase, quoting, tags, inbound SMS, the wallet, and signed webhooks.

Hand this repository to a partner and their agent stops guessing: it gets the as-built
contract, the error-code table, the traps that break integrations, and two runnable helper
scripts.

One skill per repository: the skill is `skills/partner-api-skill/`, and the repo root carries
the plugin manifests so the same repository can be installed as a **Claude Code plugin**.

## Contents
- Install as a plugin (Claude Code)
- Install (any agent)
- What's inside
- Quick start for a partner
- Maintaining it
- License

## Install as a plugin (Claude Code)

Claude Code is the one agent with a native plugin mechanism, and this repo is a valid
plugin marketplace. Two commands inside Claude Code, no shell:

```
/plugin marketplace add esimplus-me/partner-api-skill
/plugin install partner-api-skill@esimplus
```

`/plugin` then lists it for enable/disable/update, and `claude plugin update partner-api-skill`
pulls a newer version. Nothing is copied into your project — the plugin is managed by Claude
Code itself, so this is the cleanest route if you use it.

No other agent ships a plugin/extension format for skills today (Cursor, Codex, Copilot and
Windsurf all consume plain instruction files; their "plugins" are MCP servers, which is a
different thing). For those, use the installer below — it writes the native instruction file
each of them already reads.

## Install (any agent)

One command, any agent:

```bash
curl -fsSL https://raw.githubusercontent.com/esimplus-me/partner-api-skill/main/install.sh | sh
```

Run it from your project root. It detects which agents the project uses (`.claude/`,
`.cursor/`, `.windsurf/`, `.github/`, `AGENTS.md`) and installs for each of them; with no
agent config present it installs for Claude Code. Re-running updates in place.

```bash
… | sh -s -- --agent cursor      # claude | cursor | codex | copilot | windsurf | all
… | sh -s -- --global            # for every project of this user, not just this one
… | sh -s -- --dry-run           # show what it would write, change nothing
… | sh -s -- --uninstall         # remove everything it installed
```

From a clone, the same flags work directly: `./install.sh --agent all`.

**What it writes.** For Claude Code, the skill itself — `.claude/skills/partner-api-skill/`,
which is all Claude Code needs. For the others, the skill files go to the vendor-neutral
`.agents/skills/partner-api-skill/` and the installer adds a small pointer in the format that
agent reads natively:

| Agent | Pointer it installs |
|---|---|
| Claude Code | `.claude/skills/partner-api-skill/SKILL.md` (native skill — no pointer needed) |
| Cursor | `.cursor/rules/partner-api-skill.mdc` |
| Codex / any `AGENTS.md` agent | a marker-delimited block in `AGENTS.md` |
| GitHub Copilot | `.github/instructions/partner-api-skill.instructions.md` |
| Windsurf | `.windsurf/rules/partner-api-skill.md` |

The pointers hold no contract detail — they tell the agent when to open `SKILL.md`, so there
is only ever one copy of the truth to update.

Prefer not to pipe a script into a shell? Clone and copy the skill folder yourself:

```bash
git clone https://github.com/esimplus-me/partner-api-skill.git /tmp/partner-api-skill
cp -R /tmp/partner-api-skill/skills/partner-api-skill .claude/skills/
```

Keep the directory name `partner-api-skill` — an Agent Skill's `name` must equal its folder
name. Then just describe the task ("buy a US number through the eSIM Plus API", "verify this
webhook signature") — the skill activates on its own. To invoke it explicitly in Claude Code:
`/partner-api-skill`.

> **On "one click".** There is no cross-vendor one-click installer: every agent reads its own
> paths and formats, and none of them has an install URL a browser could hand off. Inside
> Claude Code the plugin commands above are the real thing; everywhere else the single
> `curl … | sh` is the portable equivalent.

## What's inside

```
.claude-plugin/
├── plugin.json               Claude Code plugin manifest
└── marketplace.json          lets this repo be added as a marketplace
skills/partner-api-skill/     the skill itself
├── SKILL.md                  the workflow and the gotchas that cause most bugs
├── references/
│   ├── host-architecture.md  the house rule: fit the host project's conventions
│   ├── endpoints.md          every endpoint, shape, query param and enum
│   ├── errors.md             the two error envelopes + codes 1301–1340
│   ├── bulk-and-pricing.md   bulk orders, quoting, the discount ladder, wallet money
│   └── webhooks.md           delivery, HMAC verification (JS/Python/PHP), retries
├── assets/
│   └── partner-api.openapi.yaml   OpenAPI 3.1 spec — feed it to a client generator
└── scripts/
    ├── probe_api.py          read-only token check: does it auth, what can it reach
    └── verify_webhook.py     verify/produce X-Esimplus-Signature (pinned test vector)
install.sh                    one-command installer for Claude/Cursor/Codex/Copilot/Windsurf
evals/                        trigger + output-conformance scenarios
```

The plugin `name` in `.claude-plugin/plugin.json`, the skill directory name and the skill's
`name:` frontmatter must all stay `partner-api-skill`; bump `version` in **both** manifests
when publishing a change.

## Quick start for a partner

```bash
export ESIMPLUS_PARTNER_TOKEN="…"   # Settings → API tokens in the partner dashboard
cd skills/partner-api-skill         # or the installed copy, e.g. .claude/skills/partner-api-skill
python3 scripts/probe_api.py
python3 scripts/verify_webhook.py --self-test
```

Both scripts need nothing but Python 3.9+ (`probe_api.py` is read-only — it buys nothing).

## Maintaining it

The skill is derived from the backend (`esim/api`, `routes/partner.php` and the
`App\Modules\Partner` modules) and from the partner-dashboard contract docs
(`partner-esimplus/docs/contracts/`, `public/openapi.yaml`). When the API changes:

1. update `skills/partner-api-skill/references/` and, if the integration surface moved,
   refresh `skills/partner-api-skill/assets/partner-api.openapi.yaml` from the dashboard's `public/openapi.yaml` — then
   **re-sanitize it**: this skill is partner-facing, so it must name no upstream number
   carrier and no payment provider (the bundled copy deliberately says "regulated number"
   and "upstream", and reads top-up provider ids from `GET /wallet/topups/providers`
   instead of listing them);
2. add every new error code to the table in `skills/partner-api-skill/references/errors.md` (they are globally unique
   and `1316`–`1318`, `1320`, `1328` are retired — never reuse them);
3. bump `version` in `.claude-plugin/plugin.json` **and** in the `plugins[]` entry of
   `.claude-plugin/marketplace.json` — plugin users update by version;
4. re-run the validator:

```bash
python3 ~/.claude/skills/creating-skills/scripts/validate_skill.py skills/partner-api-skill
```

A new trap discovered while supporting a partner belongs in the `## Gotchas` section of
`skills/partner-api-skill/SKILL.md` — that section is the highest-value part of the skill.

## License

MIT — as declared in `SKILL.md` frontmatter.
