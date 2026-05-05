#!/usr/bin/env bash
# Rule J Pre-Delete grep gate — pre-commit hook script.
#
# Per PLATFORM-CLASS-LEVEL-RULES.md Rule J + PLATFORM-PATTERNS-CATALOG.md
# §Pattern: Pre-delete verification grep — deletion-bearing commits MUST cite
# pre-flight grep evidence in the message body. This gate detects whether the
# staged commit deletes ≥1 file; if yes, it grep-checks the prepared commit
# message for either "Rule J", "Pre-Delete grep", or "pre-flight grep".
#
# Severity ramp:
#   - v0.3.0 ships at WARN (prints message but exits 0).
#   - Promotion to ERROR (exit 1) gated on Kelly authorization OR 14-day soak —
#     whichever later (per feedback-pre-launch-no-interrupting-gates).
#
# Suppress (one-off escape hatch): set RELLO_SKIP_PREDELETE_GREP=1 in env.
# CI: skip with [skip in CI] when CI=true is set.
#
# Exit codes (current — warn mode):
#   0 — no deletes, OR deletes present + grep evidence in message,
#       OR deletes present without evidence (prints warning, still exits 0)
#   2 — invariant violated (no .git or unexpected state)

set -euo pipefail

# Skip in CI — pre-commit hooks are a local-developer surface.
if [ "${CI:-}" = "true" ]; then
  echo "[pre-delete-grep-gate] skipped in CI" >&2
  exit 0
fi

# Explicit one-off escape hatch.
if [ "${RELLO_SKIP_PREDELETE_GREP:-}" = "1" ]; then
  echo "[pre-delete-grep-gate] skipped via RELLO_SKIP_PREDELETE_GREP=1" >&2
  exit 0
fi

# Resolve git dir; bail benignly if not in a repo (e.g., test sandbox).
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || true)"
if [ -z "$GIT_DIR" ]; then
  exit 0
fi

# Detect staged deletions.
deleted_files="$(git diff --cached --diff-filter=D --name-only 2>/dev/null || true)"
if [ -z "$deleted_files" ]; then
  exit 0
fi

deleted_count="$(printf '%s\n' "$deleted_files" | wc -l | tr -d ' ')"

# Read prepared commit message — first try .git/COMMIT_EDITMSG (the path the
# pre-commit hook lifecycle writes), then fall back to the env var some CI
# tooling sets, then to /dev/null (no message context — skip gracefully).
msg=""
if [ -f "$GIT_DIR/COMMIT_EDITMSG" ]; then
  msg="$(cat "$GIT_DIR/COMMIT_EDITMSG" 2>/dev/null || true)"
fi
if [ -z "$msg" ] && [ -n "${GIT_COMMIT_MESSAGE:-}" ]; then
  msg="$GIT_COMMIT_MESSAGE"
fi

# If we have no message context (merge / squash / amend without editor),
# skip with a single-line note rather than blocking.
if [ -z "$msg" ]; then
  echo "[pre-delete-grep-gate] no message context — skipping (deletes=$deleted_count)" >&2
  exit 0
fi

# Strip comment lines (lines starting with #) — those are .gitmessage helper
# comments, not the author's body.
msg_body="$(printf '%s\n' "$msg" | grep -vE '^[[:space:]]*#' || true)"

# Look for any of the three accepted phrases.
if printf '%s\n' "$msg_body" | grep -qE 'Rule J|Pre-Delete grep|pre-flight grep'; then
  exit 0
fi

# Warn but do not block (severity ramp: warn for v0.3.0 launch).
{
  echo
  echo "==============================================================="
  echo "Rule J Pre-Delete grep gate — WARN (v0.3.0 grace period)"
  echo "==============================================================="
  echo "This commit deletes $deleted_count file(s):"
  printf '%s\n' "$deleted_files" | head -20 | sed 's/^/  /'
  if [ "$deleted_count" -gt 20 ]; then
    echo "  ... and $((deleted_count - 20)) more"
  fi
  echo
  echo "Per PLATFORM-CLASS-LEVEL-RULES.md Rule J, deletion commits SHOULD cite"
  echo "pre-flight grep evidence in the message body — one of:"
  echo
  echo "  Rule J: <grep result>"
  echo "  Pre-Delete grep: <evidence>"
  echo "  pre-flight grep: <evidence>"
  echo
  echo "(or explicitly justify the absence)"
  echo
  echo "To suppress: RELLO_SKIP_PREDELETE_GREP=1"
  echo "See: PLATFORM-PATTERNS-CATALOG.md §Pattern: Pre-delete verification grep"
  echo "==============================================================="
} >&2

# Severity ramp: ships warn — exit 0 even on missing evidence.
exit 0
