#!/usr/bin/env bash
# Behavior-parity test harness for @rello-platform/scripts.
#
# Builds synthetic-fixture project trees in $TMPDIR, invokes the CLI against
# each, and asserts on the exit code (and message string where it matters).
# Run via `npm test` or `bash test/run-tests.sh`.
#
# Each subcommand is exercised against the input shapes named in PA-053
# Phase 2.A bootstrap acceptance criteria:
#
#   floating-refs:
#     - pinned (#v0.1.0)              → exit 0
#     - pinned (#<40-char sha>)       → exit 0
#     - bare ref (no #)               → exit 1
#     - branch ref (#main)            → exit 1
#     - short sha (#<8 hex>)          → exit 1
#     - missing package.json          → exit 2
#
#   roles:
#     - clean src/                              → exit 0
#     - violation in src/, not allowlisted     → exit 1
#     - violation in src/, allowlisted         → exit 0
#     - missing allowlist + clean src/         → exit 0
#     - --root src/jobs, violation             → exit 1   (v0.2.0)
#     - --root src/jobs, clean                 → exit 0   (v0.2.0)
#     - --root /nonexistent                    → exit 2   (v0.2.0)
#
#   floating-refs (--root flag, v0.2.0):
#     - --root <dir-with-pinned-package.json>  → exit 0
#     - --root /nonexistent                    → exit 2
#
#   db-apply-sql:
#     - missing schema arg              → exit 2
#     - missing sql-dir arg             → exit 2
#     - empty sql/                      → exit 0 + friendly empty message
#
# (db-apply-sql happy path requires a live Postgres — exercised in consumer
# Wave 1 cutover, not in this synthetic harness.)

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$PKG_ROOT/bin/rello-scripts"

PASS=0
FAIL=0

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS  %s (exit=%s)\n' "$desc" "$actual"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (expected exit=%s, got=%s)\n' "$desc" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

run_in_fixture() {
  local fixture="$1"
  shift
  ( cd "$fixture" && "$CLI" "$@" >/dev/null 2>&1; echo $? )
}

run_in_fixture_capture() {
  local fixture="$1"
  shift
  ( cd "$fixture" && "$CLI" "$@" 2>&1 )
}

TMP=""
cleanup() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

main() {
  TMP="$(mktemp -d -t rello-scripts-test.XXXXXX)"

  printf '\nfloating-refs\n'

  # 1. pinned tag — exit 0
  mkdir -p "$TMP/fr-tag"
  cat > "$TMP/fr-tag/package.json" <<'JSON'
{
  "name": "fixture",
  "devDependencies": {
    "@rello-platform/permissions": "github:rello-platform/permissions#v0.3.0"
  }
}
JSON
  assert_exit "pinned tag" "0" "$(run_in_fixture "$TMP/fr-tag" floating-refs)"

  # 2. pinned 40-char sha — exit 0
  mkdir -p "$TMP/fr-sha"
  cat > "$TMP/fr-sha/package.json" <<'JSON'
{
  "name": "fixture",
  "devDependencies": {
    "@rello-platform/permissions": "github:rello-platform/permissions#0123456789abcdef0123456789abcdef01234567"
  }
}
JSON
  assert_exit "pinned 40-char sha" "0" "$(run_in_fixture "$TMP/fr-sha" floating-refs)"

  # 3. bare ref — exit 1
  mkdir -p "$TMP/fr-bare"
  cat > "$TMP/fr-bare/package.json" <<'JSON'
{
  "name": "fixture",
  "devDependencies": {
    "@rello-platform/permissions": "github:rello-platform/permissions"
  }
}
JSON
  assert_exit "bare ref (no #)" "1" "$(run_in_fixture "$TMP/fr-bare" floating-refs)"

  # 4. branch ref — exit 1
  mkdir -p "$TMP/fr-branch"
  cat > "$TMP/fr-branch/package.json" <<'JSON'
{
  "name": "fixture",
  "devDependencies": {
    "@rello-platform/permissions": "github:rello-platform/permissions#main"
  }
}
JSON
  assert_exit "branch ref (#main)" "1" "$(run_in_fixture "$TMP/fr-branch" floating-refs)"

  # 5. short sha — exit 1
  mkdir -p "$TMP/fr-short"
  cat > "$TMP/fr-short/package.json" <<'JSON'
{
  "name": "fixture",
  "devDependencies": {
    "@rello-platform/permissions": "github:rello-platform/permissions#0123abc"
  }
}
JSON
  assert_exit "short sha (<40 hex)" "1" "$(run_in_fixture "$TMP/fr-short" floating-refs)"

  # 6. missing package.json — exit 2
  mkdir -p "$TMP/fr-missing"
  assert_exit "missing package.json" "2" "$(run_in_fixture "$TMP/fr-missing" floating-refs)"

  printf '\nroles\n'

  # 7. clean src/ — exit 0
  mkdir -p "$TMP/roles-clean/src"
  cat > "$TMP/roles-clean/src/index.ts" <<'TS'
export const greet = (name: string) => `Hello, ${name}`;
TS
  assert_exit "clean src/" "0" "$(run_in_fixture "$TMP/roles-clean" roles)"

  # 8. violation, not allowlisted — exit 1
  mkdir -p "$TMP/roles-violation/src"
  cat > "$TMP/roles-violation/src/badge.ts" <<'TS'
export const ROLE_LABEL = "Real Estate Broker";
TS
  assert_exit "violation, not allowlisted" "1" "$(run_in_fixture "$TMP/roles-violation" roles)"

  # 9. violation, allowlisted — exit 0
  mkdir -p "$TMP/roles-allowed/src" "$TMP/roles-allowed/scripts"
  cat > "$TMP/roles-allowed/src/badge.ts" <<'TS'
export const ROLE_LABEL = "Real Estate Broker";
TS
  cat > "$TMP/roles-allowed/scripts/check-hardcoded-roles.allowlist" <<'TXT'
# legitimate copy hardcode for the badge surface
src/badge.ts
TXT
  assert_exit "violation, allowlisted" "0" "$(run_in_fixture "$TMP/roles-allowed" roles)"

  # 10. missing allowlist + clean src/ — exit 0
  mkdir -p "$TMP/roles-no-allowlist/src"
  cat > "$TMP/roles-no-allowlist/src/index.ts" <<'TS'
export const greet = (name: string) => `Hello, ${name}`;
TS
  assert_exit "missing allowlist + clean src/" "0" "$(run_in_fixture "$TMP/roles-no-allowlist" roles)"

  # 10a. --root src/jobs with violation — exit 1
  mkdir -p "$TMP/roles-root-violation/src/jobs"
  cat > "$TMP/roles-root-violation/src/jobs/handler.ts" <<'TS'
export const ROLE_LABEL = "Real Estate Broker";
TS
  assert_exit "--root src/jobs, violation" "1" "$(run_in_fixture "$TMP/roles-root-violation" roles --root src/jobs)"

  # 10b. --root src/jobs with clean tree — exit 0
  mkdir -p "$TMP/roles-root-clean/src/jobs"
  cat > "$TMP/roles-root-clean/src/jobs/handler.ts" <<'TS'
export const greet = (name: string) => `Hello, ${name}`;
TS
  assert_exit "--root src/jobs, clean" "0" "$(run_in_fixture "$TMP/roles-root-clean" roles --root src/jobs)"

  # 10c. --root with missing path — exit 2 + friendly message
  mkdir -p "$TMP/roles-root-missing"
  assert_exit "--root /nonexistent" "2" "$(run_in_fixture "$TMP/roles-root-missing" roles --root /nonexistent)"

  local missing_root_msg
  missing_root_msg="$(run_in_fixture_capture "$TMP/roles-root-missing" roles --root /nonexistent || true)"
  if printf '%s' "$missing_root_msg" | grep -q "ERROR: --root path does not exist"; then
    printf '  PASS  --root /nonexistent prints friendly error\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  --root /nonexistent missing friendly error; got: %s\n' "$missing_root_msg"
    FAIL=$((FAIL + 1))
  fi

  # 10d. roles default (no --root) still works — regression check
  mkdir -p "$TMP/roles-default-regression/src"
  cat > "$TMP/roles-default-regression/src/badge.ts" <<'TS'
export const ROLE_LABEL = "Real Estate Broker";
TS
  assert_exit "default (no --root) regression" "1" "$(run_in_fixture "$TMP/roles-default-regression" roles)"

  printf '\nfloating-refs --root\n'

  # 10e. floating-refs --root <dir-with-pinned-package.json> — exit 0
  mkdir -p "$TMP/fr-root/sub"
  cat > "$TMP/fr-root/sub/package.json" <<'JSON'
{
  "name": "fixture",
  "devDependencies": {
    "@rello-platform/permissions": "github:rello-platform/permissions#v0.3.0"
  }
}
JSON
  assert_exit "--root <subdir>" "0" "$(run_in_fixture "$TMP/fr-root" floating-refs --root sub)"

  # 10f. floating-refs --root /nonexistent — exit 2
  mkdir -p "$TMP/fr-root-missing"
  assert_exit "floating-refs --root /nonexistent" "2" "$(run_in_fixture "$TMP/fr-root-missing" floating-refs --root /nonexistent)"

  printf '\ndb-apply-sql\n'

  # 11. missing schema arg — exit 2
  mkdir -p "$TMP/db-no-schema"
  assert_exit "missing schema (arg /nonexistent)" "2" "$(run_in_fixture "$TMP/db-no-schema" db-apply-sql /nonexistent/schema /nonexistent/dir)"

  # 12. missing sql-dir arg — exit 2
  mkdir -p "$TMP/db-no-sqldir"
  cat > "$TMP/db-no-sqldir/schema.prisma" <<'PRISMA'
generator client { provider = "prisma-client-js" }
PRISMA
  assert_exit "missing sql-dir (arg /nonexistent)" "2" "$(run_in_fixture "$TMP/db-no-sqldir" db-apply-sql ./schema.prisma /nonexistent/dir)"

  # 13. empty sql/ — exit 0 + friendly message
  mkdir -p "$TMP/db-empty/sql"
  cat > "$TMP/db-empty/schema.prisma" <<'PRISMA'
generator client { provider = "prisma-client-js" }
PRISMA
  assert_exit "empty sql dir" "0" "$(run_in_fixture "$TMP/db-empty" db-apply-sql ./schema.prisma ./sql)"

  local empty_msg
  empty_msg="$(run_in_fixture_capture "$TMP/db-empty" db-apply-sql ./schema.prisma ./sql || true)"
  if printf '%s' "$empty_msg" | grep -q "No .sql files in"; then
    printf '  PASS  empty sql dir prints friendly message\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  empty sql dir missing friendly message; got: %s\n' "$empty_msg"
    FAIL=$((FAIL + 1))
  fi

  printf '\nCLI flag handling\n'

  # 14. unknown subcommand — exit 2
  assert_exit "unknown subcommand" "2" "$(run_in_fixture "$TMP" not-a-real-subcommand)"

  # 15. no subcommand — exit 2
  assert_exit "no subcommand" "2" "$(run_in_fixture "$TMP")"

  # 16. --help — exit 0
  assert_exit "--help" "0" "$(run_in_fixture "$TMP" --help)"

  printf '\npre-delete-grep-gate (v0.3.0)\n'

  # P1. fixture with no deletes — exit 0
  mkdir -p "$TMP/predel-clean"
  ( cd "$TMP/predel-clean" && git init -q && git config user.email t@t && git config user.name t \
      && touch a.txt && git add a.txt && git commit -q -m "init" )
  assert_exit "no deletes — exit 0" "0" "$(run_in_fixture "$TMP/predel-clean" pre-delete-grep-gate)"

  # P2. fixture with staged delete + no Rule J evidence — exit 0 (warn mode)
  mkdir -p "$TMP/predel-warn"
  ( cd "$TMP/predel-warn" && git init -q && git config user.email t@t && git config user.name t \
      && touch a.txt b.txt && git add a.txt b.txt && git commit -q -m "init" \
      && git rm -q a.txt && printf 'deleting a\n' > .git/COMMIT_EDITMSG )
  assert_exit "delete + no evidence — warn (exit 0)" "0" "$(run_in_fixture "$TMP/predel-warn" pre-delete-grep-gate)"

  # P3. fixture with staged delete + "Rule J" evidence — exit 0 (silent pass)
  mkdir -p "$TMP/predel-evidence"
  ( cd "$TMP/predel-evidence" && git init -q && git config user.email t@t && git config user.name t \
      && touch a.txt b.txt && git add a.txt b.txt && git commit -q -m "init" \
      && git rm -q a.txt && printf 'deleting a\n\nRule J: greppped src/ — zero callers\n' > .git/COMMIT_EDITMSG )
  assert_exit "delete + Rule J evidence — exit 0" "0" "$(run_in_fixture "$TMP/predel-evidence" pre-delete-grep-gate)"

  # P4. RELLO_SKIP_PREDELETE_GREP=1 short-circuits even on uninstalled git — exit 0
  assert_exit "RELLO_SKIP_PREDELETE_GREP=1 — exit 0" "0" \
    "$(cd "$TMP" && RELLO_SKIP_PREDELETE_GREP=1 "$CLI" pre-delete-grep-gate >/dev/null 2>&1; echo $?)"

  # P5. CI=true short-circuits — exit 0
  assert_exit "CI=true — exit 0" "0" \
    "$(cd "$TMP" && CI=true "$CLI" pre-delete-grep-gate >/dev/null 2>&1; echo $?)"

  printf '\nschema-change-reminder (v0.3.0)\n'

  # S1. fixture with no schema staged — exit 0
  mkdir -p "$TMP/schema-clean"
  ( cd "$TMP/schema-clean" && git init -q && git config user.email t@t && git config user.name t \
      && touch a.txt && git add a.txt && git commit -q -m "init" )
  assert_exit "no schema — exit 0" "0" "$(run_in_fixture "$TMP/schema-clean" schema-change-reminder)"

  # S2. fixture with prisma/schema.prisma staged + no verification — exit 0 (advisory)
  mkdir -p "$TMP/schema-warn/prisma"
  ( cd "$TMP/schema-warn" && git init -q && git config user.email t@t && git config user.name t \
      && touch a.txt && git add a.txt && git commit -q -m "init" \
      && printf 'generator client { provider = "prisma-client-js" }\n' > prisma/schema.prisma \
      && git add prisma/schema.prisma && printf 'schema change\n' > .git/COMMIT_EDITMSG )
  assert_exit "schema staged + no verification — advisory (exit 0)" "0" "$(run_in_fixture "$TMP/schema-warn" schema-change-reminder)"

  # S3. fixture with prisma/schema.prisma staged + verification phrases — exit 0 (silent)
  mkdir -p "$TMP/schema-verified/prisma"
  ( cd "$TMP/schema-verified" && git init -q && git config user.email t@t && git config user.name t \
      && touch a.txt && git add a.txt && git commit -q -m "init" \
      && printf 'generator client { provider = "prisma-client-js" }\n' > prisma/schema.prisma \
      && git add prisma/schema.prisma \
      && printf 'schema change\n\nprisma migrate diff: No difference detected\n' > .git/COMMIT_EDITMSG )
  assert_exit "schema staged + verified — exit 0 silent" "0" "$(run_in_fixture "$TMP/schema-verified" schema-change-reminder)"

  # S4. RELLO_SKIP_SCHEMA_REMINDER=1 short-circuits — exit 0
  assert_exit "RELLO_SKIP_SCHEMA_REMINDER=1 — exit 0" "0" \
    "$(cd "$TMP" && RELLO_SKIP_SCHEMA_REMINDER=1 "$CLI" schema-change-reminder >/dev/null 2>&1; echo $?)"

  printf '\nTotal: %d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
