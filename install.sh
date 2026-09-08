#!/bin/sh
# Install the eSIM Plus Partner API agent skill into whichever AI coding agent you use.
#
#   curl -fsSL https://raw.githubusercontent.com/esimplus-me/partner-api-skill/main/install.sh | sh
#
# or, from a clone:
#
#   ./install.sh                 # auto-detect the agents used in this project
#   ./install.sh --agent cursor  # or claude | codex | copilot | windsurf | all
#   ./install.sh --global        # install for every project of this user
#   ./install.sh --dry-run       # print what would happen, change nothing
#   ./install.sh --uninstall
#
# POSIX sh; needs only curl or git, plus tar. Idempotent — re-running updates in place.

set -eu

REPO_SLUG="esimplus-me/partner-api-skill"
SKILL_NAME="partner-api-skill"
REF="${PARTNER_API_SKILL_REF:-main}"

AGENTS=""
SCOPE="project"
DRY_RUN=0
UNINSTALL=0
TARGET_ROOT="."
SOURCE_DIR=""
TMP_DIR=""

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { warn "error: $*"; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT INT TERM

run() {
  if [ "$DRY_RUN" -eq 1 ]; then say "  would run: $*"; else "$@"; fi
}

# --- arguments --------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENTS="${AGENTS} ${2:-}"; shift 2 ;;
    --agent=*) AGENTS="${AGENTS} ${1#*=}"; shift ;;
    --global) SCOPE="global"; shift ;;
    --dir) TARGET_ROOT="${2:-}"; shift 2 ;;
    --dir=*) TARGET_ROOT="${1#*=}"; shift ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --ref=*) REF="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -d "$TARGET_ROOT" ] || die "not a directory: $TARGET_ROOT"
TARGET_ROOT=$(cd "$TARGET_ROOT" && pwd)
[ "$SCOPE" = "global" ] && TARGET_ROOT="$HOME"

# --- where the skill files come from ---------------------------------------

# The skill lives at skills/<name>/ so the repo doubles as a Claude Code plugin.
skill_dir_in() {  # skill_dir_in <repo root> -> prints the skill dir if it holds a SKILL.md
  if [ -f "$1/skills/$SKILL_NAME/SKILL.md" ]; then printf '%s' "$1/skills/$SKILL_NAME"
  elif [ -f "$1/SKILL.md" ]; then printf '%s' "$1"   # older flat layout
  fi
}

resolve_source() {
  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
  if [ -n "$script_dir" ]; then
    found=$(skill_dir_in "$script_dir")
    if [ -n "$found" ]; then SOURCE_DIR="$found"; return; fi
  fi
  # Piped from curl: fetch the repo into a temp dir.
  TMP_DIR=$(mktemp -d) || die "cannot create a temp dir"
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 --branch "$REF" "https://github.com/${REPO_SLUG}.git" \
      "$TMP_DIR/src" >/dev/null 2>&1 || die "git clone failed for ${REPO_SLUG}@${REF}"
    SOURCE_DIR=$(skill_dir_in "$TMP_DIR/src")
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://codeload.github.com/${REPO_SLUG}/tar.gz/${REF}" \
      | (cd "$TMP_DIR" && tar -xzf -) || die "download failed for ${REPO_SLUG}@${REF}"
    root=$(find "$TMP_DIR" -maxdepth 1 -type d -name '*partner-api-skill*' | head -n 1)
    SOURCE_DIR=$(skill_dir_in "$root")
  else
    die "need git or curl to fetch the skill"
  fi
  [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/SKILL.md" ] \
    || die "fetched tree has no skills/${SKILL_NAME}/SKILL.md"
}

# --- agent detection --------------------------------------------------------

detect_agents() {
  found=""
  [ -d "$TARGET_ROOT/.claude" ] && found="$found claude"
  [ -d "$TARGET_ROOT/.cursor" ] && found="$found cursor"
  [ -d "$TARGET_ROOT/.windsurf" ] && found="$found windsurf"
  [ -d "$TARGET_ROOT/.github" ] && found="$found copilot"
  { [ -f "$TARGET_ROOT/AGENTS.md" ] || [ -d "$TARGET_ROOT/.codex" ]; } && found="$found codex"
  printf '%s' "$found"
}

# --- copy helpers -----------------------------------------------------------

copy_skill() {  # copy_skill <destination dir>
  dest="$1"
  say "  skill files -> ${dest}"
  [ "$DRY_RUN" -eq 1 ] && return 0
  mkdir -p "$dest"
  rm -rf "$dest/references" "$dest/assets" "$dest/scripts"
  cp "$SOURCE_DIR/SKILL.md" "$dest/SKILL.md"
  cp -R "$SOURCE_DIR/references" "$SOURCE_DIR/assets" "$SOURCE_DIR/scripts" "$dest/"
  [ -f "$SOURCE_DIR/README.md" ] && cp "$SOURCE_DIR/README.md" "$dest/README.md"
  chmod +x "$dest/scripts/"*.py 2>/dev/null || true
}

POINTER_BODY_FILE=""
write_pointer_body() {  # shared prose for the non-Claude adapters; $1 = relative skill path
  POINTER_BODY_FILE=$(mktemp)
  cat > "$POINTER_BODY_FILE" <<EOF
When the task touches the **eSIM Plus Partner API** (\`api.esimplus.net/api/partner/v1\`) —
buying or releasing virtual phone numbers, the number catalog, bulk orders and quoting, tags,
inbound SMS, the partner wallet, partner error codes 1301-1329, or verifying an
\`X-Esimplus-Signature\` webhook — read \`$1/SKILL.md\` first and follow it.

It carries the as-built contract, so do not guess field names, error codes or the signature
algorithm. Load the files it points to as needed:

- \`$1/references/host-architecture.md\` — fit the integration into THIS project's
  architecture (read before writing code).
- \`$1/references/endpoints.md\` — endpoints, request/response shapes, enums.
- \`$1/references/errors.md\` — the two error envelopes and the domain-code table.
- \`$1/references/bulk-and-pricing.md\` — bulk orders, quoting, discounts, wallet money.
- \`$1/references/webhooks.md\` — delivery, HMAC verification, retries, idempotency.
- \`$1/assets/partner-api.openapi.yaml\` — OpenAPI 3.1 spec for client generation.

Non-negotiable: \`POST /phone-numbers\` is not idempotent (never auto-retry it), array query
params need PHP brackets (\`tags[]=\`), and the webhook signature is computed over the raw
request body.
EOF
}

install_claude() {
  base="$TARGET_ROOT/.claude/skills/$SKILL_NAME"
  say "claude · Claude Code skill"
  copy_skill "$base"
}

install_cursor() {
  say "cursor · Cursor rule + skill files"
  copy_skill "$TARGET_ROOT/.agents/skills/$SKILL_NAME"
  write_pointer_body ".agents/skills/$SKILL_NAME"
  rule="$TARGET_ROOT/.cursor/rules/$SKILL_NAME.mdc"
  say "  rule -> ${rule}"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$rule")"
    { printf -- '---\ndescription: eSIM Plus Partner API integration — virtual numbers, bulk orders, inbound SMS, wallet, signed webhooks\nalwaysApply: false\n---\n\n'
      cat "$POINTER_BODY_FILE"; } > "$rule"
  fi
  rm -f "$POINTER_BODY_FILE"
}

install_windsurf() {
  say "windsurf · Windsurf rule + skill files"
  copy_skill "$TARGET_ROOT/.agents/skills/$SKILL_NAME"
  write_pointer_body ".agents/skills/$SKILL_NAME"
  rule="$TARGET_ROOT/.windsurf/rules/$SKILL_NAME.md"
  say "  rule -> ${rule}"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$rule")"
    { printf -- '---\ntrigger: model_decision\ndescription: eSIM Plus Partner API integration — virtual numbers, bulk orders, inbound SMS, wallet, signed webhooks\n---\n\n'
      cat "$POINTER_BODY_FILE"; } > "$rule"
  fi
  rm -f "$POINTER_BODY_FILE"
}

install_copilot() {
  say "copilot · GitHub Copilot instructions + skill files"
  copy_skill "$TARGET_ROOT/.agents/skills/$SKILL_NAME"
  write_pointer_body ".agents/skills/$SKILL_NAME"
  rule="$TARGET_ROOT/.github/instructions/$SKILL_NAME.instructions.md"
  say "  instructions -> ${rule}"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$rule")"
    { printf -- '---\napplyTo: "**"\ndescription: eSIM Plus Partner API integration\n---\n\n'
      cat "$POINTER_BODY_FILE"; } > "$rule"
  fi
  rm -f "$POINTER_BODY_FILE"
}

install_codex() {
  say "codex · AGENTS.md block + skill files"
  copy_skill "$TARGET_ROOT/.agents/skills/$SKILL_NAME"
  write_pointer_body ".agents/skills/$SKILL_NAME"
  agents_md="$TARGET_ROOT/AGENTS.md"
  say "  AGENTS.md block -> ${agents_md}"
  if [ "$DRY_RUN" -eq 0 ]; then
    tmp=$(mktemp)
    if [ -f "$agents_md" ]; then
      awk '/<!-- partner-api-skill:start -->/{skip=1} !skip{print} /<!-- partner-api-skill:end -->/{skip=0}' \
        "$agents_md" > "$tmp"
      printf '\n' >> "$tmp"
    fi
    { printf -- '<!-- partner-api-skill:start -->\n## eSIM Plus Partner API\n\n'
      cat "$POINTER_BODY_FILE"
      printf -- '<!-- partner-api-skill:end -->\n'; } >> "$tmp"
    mv "$tmp" "$agents_md"
  fi
  rm -f "$POINTER_BODY_FILE"
}

uninstall_all() {
  say "Removing the skill from ${TARGET_ROOT}"
  for path in \
    ".claude/skills/$SKILL_NAME" \
    ".agents/skills/$SKILL_NAME" \
    ".cursor/rules/$SKILL_NAME.mdc" \
    ".windsurf/rules/$SKILL_NAME.md" \
    ".github/instructions/$SKILL_NAME.instructions.md"
  do
    [ -e "$TARGET_ROOT/$path" ] && { say "  rm ${path}"; run rm -rf "$TARGET_ROOT/$path"; }
  done
  if [ -f "$TARGET_ROOT/AGENTS.md" ] && grep -q 'partner-api-skill:start' "$TARGET_ROOT/AGENTS.md"; then
    say "  strip block from AGENTS.md"
    if [ "$DRY_RUN" -eq 0 ]; then
      tmp=$(mktemp)
      awk '/<!-- partner-api-skill:start -->/{skip=1} !skip{print} /<!-- partner-api-skill:end -->/{skip=0}' \
        "$TARGET_ROOT/AGENTS.md" > "$tmp"
      mv "$tmp" "$TARGET_ROOT/AGENTS.md"
    fi
  fi
  say "Done."
}

# --- main -------------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
  uninstall_all
  exit 0
fi

resolve_source

AGENTS=$(printf '%s' "$AGENTS" | tr ',' ' ' | tr -s ' ')
case "$AGENTS" in
  *all*) AGENTS="claude cursor codex copilot windsurf" ;;
  "")
    AGENTS=$(detect_agents)
    if [ -z "$AGENTS" ]; then
      AGENTS="claude"
      say "No agent config found in ${TARGET_ROOT} — defaulting to Claude Code."
      say "Pass --agent cursor|codex|copilot|windsurf|all to choose another."
    else
      say "Detected:$AGENTS"
    fi
    ;;
esac

say "Installing ${SKILL_NAME} (${SCOPE} scope) into ${TARGET_ROOT}"
[ "$DRY_RUN" -eq 1 ] && say "(dry run — nothing will be written)"
say ""

for agent in $AGENTS; do
  case "$agent" in
    claude) install_claude ;;
    cursor) install_cursor ;;
    codex|agents) install_codex ;;
    copilot) install_copilot ;;
    windsurf) install_windsurf ;;
    *) warn "skipping unknown agent: $agent" ;;
  esac
  say ""
done

say "Done. Verify with:"
case "$AGENTS" in
  *claude*) say "  plugin  → or install it as a plugin instead: /plugin marketplace add ${REPO_SLUG}" ;;
esac
case "$AGENTS" in
  *claude*) say "  claude  → ask \"buy a US virtual number via the eSIM Plus API\", or run /${SKILL_NAME}" ;;
esac
say "  probe   → python3 <skill dir>/scripts/probe_api.py --token \"\$ESIMPLUS_PARTNER_TOKEN\""
say "  webhook → python3 <skill dir>/scripts/verify_webhook.py --self-test"
