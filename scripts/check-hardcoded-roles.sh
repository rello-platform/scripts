#!/usr/bin/env bash
#
# CANONICAL — bundled inside @rello-platform/scripts (PA-053 Phase 2.A).
# Body byte-identical to consumer-side .sh except the `cd "$(dirname "$0")/.."`
# step is dropped: the Node CLI bin/rello-scripts spawns bash with
# cwd: process.cwd() (consumer root), so the gate already operates on
# <consumer-root>/scripts/check-hardcoded-roles.allowlist and the configured
# source root without an explicit cd. Same exit codes, same messages, same
# behavior on every input that matters.
#
# Regression check — fail when lead-facing role labels are hardcoded outside
# the @rello-platform/ui catalog. Lead-facing role copy must come from
# getCopyForAgent() / getTeamCopy() so tenant overrides and per-role catalog
# edits flow through every surface.
#
# v0.2.0 — accepts optional `--root <path>` flag for non-standard layouts
# (e.g. engines using src/jobs/). Default scan root remains `src/`.
#
# Audit:                 ~/AUDITS/AUDIT FINDS TO FIX/DISCOVERED-HR-TEAM-COMPOSITION-MODEL-041626.md
# Phase 1 canonicalization: ~AUDITS/April2026 Platform Audit/PA-048-CHECK-HARDCODED-ROLES-CANONICALIZATION-042626.md
# Phase 2 canonicalization: ~AUDITS/April2026 Platform Audit/PA-053-CHECK-SCRIPTS-PHASE-2-CANONICALIZATION-042626.md
#
# Per-repo allowlist lives in scripts/check-hardcoded-roles.allowlist
# (one path per line; lines starting with `#` are comments; blank lines ignored).
#
set -euo pipefail

PATTERNS='Real Estate Agent|Loan Officer|Mortgage Loan Officer|Real Estate Broker'
ALLOWLIST_FILE="scripts/check-hardcoded-roles.allowlist"
ROOT="src"

# Parse --root <path>. Backward-compatible: no flag → default `src`.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ -z "${2:-}" ]; then
        printf 'ERROR: --root requires a path argument\n' >&2
        exit 2
      fi
      ROOT="$2"
      shift 2
      ;;
    --root=*)
      ROOT="${1#--root=}"
      shift
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  printf 'ERROR: scan root does not exist or is not a directory: %s\n' "$ROOT" >&2
  exit 2
fi

# Allowlist file is optional — repos with no legitimate hardcodes may omit it.
if [[ -f "$ALLOWLIST_FILE" ]]; then
  ALLOWLIST=$(grep -v '^#' "$ALLOWLIST_FILE" | grep -v '^[[:space:]]*$' || true)
else
  ALLOWLIST=""
fi

# Build a regex that matches any allowlisted path. Escape regex meta chars
# (parens, brackets, dots, etc.) so e.g. `(dashboard)` matches as a literal.
# Empty allowlist → sentinel that never matches; grep -Ev becomes a no-op.
if [[ -z "$ALLOWLIST" ]]; then
  ALLOW_REGEX='__check_hardcoded_roles_no_allowlist_sentinel__'
else
  ALLOW_REGEX=$(printf '%s\n' "$ALLOWLIST" | sed 's/[][().+*?^$|\\]/\\&/g; s|/|\\/|g' | tr '\n' '|' | sed 's/|$//')
fi

# Search $ROOT for hardcoded role labels.
#
# - rg's `ts` type already covers .ts / .tsx / .cts / .mts (verify via
#   `rg --type-list | grep '^ts:'`). Do NOT pass `--type tsx`; rg has no
#   `tsx` type and exits 2 with "unrecognized file type". The
#   `_no_match_ok` helper below treats exit 0 + 1 as legitimate (match /
#   no-match) and propagates 2+ as a real error, so a future flag-typo
#   fails loud instead of silent — same intent as PA-048's pipefail
#   discipline, but robust against a truly clean tree (rg exits 1 on no
#   matches, which under pipefail would otherwise fail the whole pipeline
#   and crash the gate before grep -Ev got a chance to filter against the
#   allowlist).
#
# - The `|| true` wraps ONLY the inner grep -Ev (which legitimately exits 1
#   when every hit is allowlisted).
_no_match_ok() {
  "$@"
  local rc=$?
  if [ "$rc" -le 1 ]; then return 0; fi
  return "$rc"
}

if command -v rg >/dev/null 2>&1; then
  HITS=$(_no_match_ok rg -n -e "$PATTERNS" "$ROOT" --type ts | { grep -Ev "$ALLOW_REGEX" || true; })
else
  HITS=$(_no_match_ok grep -RInE "$PATTERNS" "$ROOT" --include='*.ts' --include='*.tsx' | { grep -Ev "$ALLOW_REGEX" || true; })
fi

if [[ -n "$HITS" ]]; then
  echo "ERROR: Hardcoded lead-facing role labels found." >&2
  echo "Use getCopyForAgent() / getTeamCopy() from @rello-platform/ui instead." >&2
  echo "" >&2
  echo "Offending lines:" >&2
  echo "$HITS" >&2
  echo "" >&2
  echo "If this is a legitimate use, add the path to scripts/check-hardcoded-roles.allowlist." >&2
  exit 1
fi

echo "OK: no hardcoded lead-facing role labels found in ${ROOT}/."
