#!/usr/bin/env bash
# Schema-change reminder — pre-commit hook script.
#
# Per ~/.claude/standards/db-schema-changes.md (the 7-step schema-change
# ritual) — when prisma/schema.prisma is staged, prompt the author to
# confirm `prisma migrate diff --exit-code` was run AND verification lines
# are pasted in the commit body.
#
# Severity: WARN ONLY (never blocks). Schema-change discipline is a
# 7-step ritual; one CLI hook can't verify all 7 — it can only prompt.
#
# Skipped:
#   - In CI (CI=true).
#   - Via RELLO_SKIP_SCHEMA_REMINDER=1 in env.
#
# Exit codes:
#   0 — always (advisory only)

set -euo pipefail

if [ "${CI:-}" = "true" ]; then
  exit 0
fi

if [ "${RELLO_SKIP_SCHEMA_REMINDER:-}" = "1" ]; then
  exit 0
fi

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || true)"
if [ -z "$GIT_DIR" ]; then
  exit 0
fi

# Detect staged prisma/schema.prisma.
staged="$(git diff --cached --name-only 2>/dev/null || true)"
if [ -z "$staged" ]; then
  exit 0
fi

if ! printf '%s\n' "$staged" | grep -qE '(^|/)prisma/schema\.prisma$'; then
  exit 0
fi

# Read prepared commit message.
msg=""
if [ -f "$GIT_DIR/COMMIT_EDITMSG" ]; then
  msg="$(cat "$GIT_DIR/COMMIT_EDITMSG" 2>/dev/null || true)"
fi
if [ -z "$msg" ] && [ -n "${GIT_COMMIT_MESSAGE:-}" ]; then
  msg="$GIT_COMMIT_MESSAGE"
fi

msg_body=""
if [ -n "$msg" ]; then
  msg_body="$(printf '%s\n' "$msg" | grep -vE '^[[:space:]]*#' || true)"
fi

# Acceptance criteria — either phrase pair is acceptable evidence.
if [ -n "$msg_body" ] && printf '%s\n' "$msg_body" | grep -qE 'prisma migrate diff' \
     && printf '%s\n' "$msg_body" | grep -qE 'No difference detected'; then
  exit 0
fi

if [ -n "$msg_body" ] && printf '%s\n' "$msg_body" | grep -qE 'Verification:' \
     && printf '%s\n' "$msg_body" | grep -qE 'tsc --noEmit' \
     && printf '%s\n' "$msg_body" | grep -qE 'migrate diff'; then
  exit 0
fi

{
  echo
  echo "==============================================================="
  echo "Schema-change reminder — WARN (advisory only)"
  echo "==============================================================="
  echo "prisma/schema.prisma is staged in this commit."
  echo
  echo "Per ~/.claude/standards/db-schema-changes.md, schema changes"
  echo "MUST be verified BEFORE commit:"
  echo
  echo "  1. prisma migrate diff --from-url \"\$DATABASE_URL\" \\"
  echo "       --to-schema-datamodel prisma/schema.prisma --exit-code"
  echo "     (expect exit 0, \"No difference detected\")"
  echo
  echo "  2. npx tsc --noEmit (zero new errors)"
  echo
  echo "Paste both verification lines in the commit body — phrases like:"
  echo "  - \"prisma migrate diff: No difference detected\""
  echo "  - \"Verification: tsc --noEmit clean + migrate diff exit 0\""
  echo
  echo "(advisory — this gate does not block; suppress with RELLO_SKIP_SCHEMA_REMINDER=1)"
  echo "==============================================================="
} >&2

exit 0
