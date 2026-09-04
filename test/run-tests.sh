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

# Fixture isolation (v0.5.0): when this harness runs under a git hook (husky
# pre-push), git exports GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE into the hook
# environment. The pre-delete-grep-gate / schema-change-reminder fixtures
# `git init` + commit inside $TMP — with those vars inherited, every fixture
# git command silently operates on the OUTER repo instead (observed pushing
# from a linked worktree: fixture commits landed on the real branch and real
# files were staged for deletion). Unset them so fixture git is always local.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

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

  printf '\nfloating-refs (v0.3.1 structural shapes)\n'

  # v0.3.1 catches every non-canonical pin shape — not just github:-prefixed.
  # Helper: write a one-dep fixture, assert exit code.
  fr_fixture() {
    local name="$1" dep="$2" val="$3"
    mkdir -p "$TMP/$name"
    cat > "$TMP/$name/package.json" <<JSON
{
  "name": "fixture",
  "dependencies": {
    "$dep": "$val"
  }
}
JSON
  }

  # --- exit 1 shapes ---
  fr_fixture v31-githttps "@rello-platform/scripts" "git+https://github.com/rello-platform/scripts.git#10bcaed51f319cbc0071e81ffabc7df998558af1"
  assert_exit "git+https://" "1" "$(run_in_fixture "$TMP/v31-githttps" floating-refs)"

  fr_fixture v31-caret "@rello-platform/billing-client" "^0.1.0"
  assert_exit "npm-caret ^0.1.0" "1" "$(run_in_fixture "$TMP/v31-caret" floating-refs)"

  fr_fixture v31-tilde "@rello-platform/billing-client" "~0.1.0"
  assert_exit "npm-tilde ~0.1.0" "1" "$(run_in_fixture "$TMP/v31-tilde" floating-refs)"

  fr_fixture v31-wild-nomember "@rello-platform/asset-whitelist" "*"
  assert_exit "wildcard * (no workspace member)" "1" "$(run_in_fixture "$TMP/v31-wild-nomember" floating-refs)"

  fr_fixture v31-bare "@rello-platform/foo" "github:rello-platform/foo"
  assert_exit "bare github:rello-platform/foo" "1" "$(run_in_fixture "$TMP/v31-bare" floating-refs)"

  fr_fixture v31-branch "@rello-platform/foo" "github:rello-platform/foo#main"
  assert_exit "branch ref #main" "1" "$(run_in_fixture "$TMP/v31-branch" floating-refs)"

  fr_fixture v31-shortsha "@rello-platform/foo" "github:rello-platform/foo#0123abc"
  assert_exit "short sha" "1" "$(run_in_fixture "$TMP/v31-shortsha" floating-refs)"

  fr_fixture v31-file "@rello-platform/foo" "file:../x"
  assert_exit "file:../x" "1" "$(run_in_fixture "$TMP/v31-file" floating-refs)"

  fr_fixture v31-link "@rello-platform/foo" "link:../x"
  assert_exit "link:../x" "1" "$(run_in_fixture "$TMP/v31-link" floating-refs)"

  fr_fixture v31-npmalias "@rello-platform/foo" "npm:@scope/x@1"
  assert_exit "npm:@scope/x@1" "1" "$(run_in_fixture "$TMP/v31-npmalias" floating-refs)"

  # --- exit 0 shapes ---
  fr_fixture v31-tag "@rello-platform/permissions" "github:rello-platform/permissions#v1.2.3"
  assert_exit "valid #v1.2.3 tag" "0" "$(run_in_fixture "$TMP/v31-tag" floating-refs)"

  fr_fixture v31-prerelease "@rello-platform/permissions" "github:rello-platform/permissions#v1.2.3-rc.1"
  assert_exit "valid #v1.2.3-rc.1 prerelease" "0" "$(run_in_fixture "$TMP/v31-prerelease" floating-refs)"

  fr_fixture v31-sha "@rello-platform/permissions" "github:rello-platform/permissions#0123456789abcdef0123456789abcdef01234567"
  assert_exit "valid 40-hex SHA" "0" "$(run_in_fixture "$TMP/v31-sha" floating-refs)"

  # --- workspace carve-out: * WITH a matching packages/* member — exit 0 ---
  mkdir -p "$TMP/v31-workspace/packages/asset-whitelist"
  cat > "$TMP/v31-workspace/package.json" <<'JSON'
{
  "name": "fixture",
  "workspaces": ["packages/*"],
  "dependencies": {
    "@rello-platform/asset-whitelist": "*"
  }
}
JSON
  cat > "$TMP/v31-workspace/packages/asset-whitelist/package.json" <<'JSON'
{
  "name": "@rello-platform/asset-whitelist",
  "version": "1.0.0"
}
JSON
  assert_exit "wildcard * WITH workspace member" "0" "$(run_in_fixture "$TMP/v31-workspace" floating-refs)"

  # --- per-violation message names the offending key + canonical replacement ---
  local v31_msg
  v31_msg="$(run_in_fixture_capture "$TMP/v31-githttps" floating-refs || true)"
  if printf '%s' "$v31_msg" | grep -q "@rello-platform/scripts" \
     && printf '%s' "$v31_msg" | grep -q "github:rello-platform/scripts#v<X.Y.Z>"; then
    printf '  PASS  violation message names key + canonical replacement\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  violation message missing key/canonical hint; got: %s\n' "$v31_msg"
    FAIL=$((FAIL + 1))
  fi

  # --- malformed package.json — exit 2 ---
  mkdir -p "$TMP/v31-malformed"
  printf '{ this is not valid json' > "$TMP/v31-malformed/package.json"
  assert_exit "malformed package.json" "2" "$(run_in_fixture "$TMP/v31-malformed" floating-refs)"

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

  printf '\ncheck-stale-pins (v0.4.0)\n'

  # Shared mock GitHub state — no network. Tags are sorted -V internally; the
  # gate reads <repo>.tags (newline tag list) and <repo>.compare.<base>...<head>.
  local MOCK="$TMP/csp-mock"
  mkdir -p "$MOCK"
  printf 'v0.38.0\nv0.39.0\nv0.40.0\nv0.41.0\n' > "$MOCK/permissions.tags"
  printf 'v2.14.0\nv2.16.0\nv2.18.0\n'           > "$MOCK/api-client.tags"
  printf 'v2.14.0\nv2.16.0\nv2.18.0\n'           > "$MOCK/rello-ui.tags"

  # csp helper: write a one-dep package.json fixture.
  csp_fixture() {
    local name="$1" dep="$2" val="$3"
    mkdir -p "$TMP/$name"
    cat > "$TMP/$name/package.json" <<JSON
{ "name": "fixture", "dependencies": { "$dep": "$val" } }
JSON
  }
  # csp run: invoke under the mock dir.
  csp_run() {
    local fixture="$1"; shift
    ( cd "$fixture" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins "$@" >/dev/null 2>&1; echo $? )
  }

  # C1. current tag — exit 0
  csp_fixture csp-ok "@rello-platform/permissions" "github:rello-platform/permissions#v0.41.0"
  assert_exit "OK: current tag (v0.41.0)" "0" "$(csp_run "$TMP/csp-ok")"

  # C2. 1 minor behind — WARN, exit 0
  csp_fixture csp-warn "@rello-platform/permissions" "github:rello-platform/permissions#v0.40.0"
  assert_exit "WARN: 1 minor behind (v0.40.0) — exit 0" "0" "$(csp_run "$TMP/csp-warn")"

  # C3. >=2 minors behind — FAIL, exit 1
  csp_fixture csp-fail "@rello-platform/permissions" "github:rello-platform/permissions#v0.38.0"
  assert_exit "FAIL: 3 minors behind (v0.38.0) — exit 1" "1" "$(csp_run "$TMP/csp-fail")"

  # C4. full major behind — FAIL, exit 1
  csp_fixture csp-major "@rello-platform/api-client" "github:rello-platform/api-client#v1.9.0"
  assert_exit "FAIL: 1 major behind (v1.9.0 < v2.18.0) — exit 1" "1" "$(csp_run "$TMP/csp-major")"

  # C5. allowlisted via sidecar scripts/stale-pin-exceptions.json — exit 0
  mkdir -p "$TMP/csp-allow-side/scripts"
  cat > "$TMP/csp-allow-side/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "@rello-platform/api-client": "github:rello-platform/api-client#v1.9.0" } }
JSON
  cat > "$TMP/csp-allow-side/scripts/stale-pin-exceptions.json" <<'JSON'
{ "@rello-platform/api-client": "CJS-held v1.9.0 (EX-3)" }
JSON
  assert_exit "allowlisted (sidecar) suppresses FAIL — exit 0" "0" "$(csp_run "$TMP/csp-allow-side")"

  # C6. allowlisted via inline relloStalePinExceptions field — exit 0
  mkdir -p "$TMP/csp-allow-inline"
  cat > "$TMP/csp-allow-inline/package.json" <<'JSON'
{ "name": "fixture",
  "relloStalePinExceptions": { "@rello-platform/api-client": "CJS-held v1.9.0 (EX-3)" },
  "dependencies": { "@rello-platform/api-client": "github:rello-platform/api-client#v1.9.0" } }
JSON
  assert_exit "allowlisted (inline field) suppresses FAIL — exit 0" "0" "$(csp_run "$TMP/csp-allow-inline")"

  # C7. offline / unreachable gh — fail-open, exit 0 (even on a would-be-FAIL)
  assert_exit "offline fail-open on would-be-FAIL — exit 0" "0" \
    "$(cd "$TMP/csp-fail" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_SIMULATE_OFFLINE=1 "$CLI" check-stale-pins >/dev/null 2>&1; echo $?)"

  # C8. workspace wildcard skipped; @rello-platform/ui maps to repo rello-ui — exit 0
  mkdir -p "$TMP/csp-mixed"
  cat > "$TMP/csp-mixed/package.json" <<'JSON'
{ "name": "fixture", "dependencies": {
    "@rello-platform/asset-whitelist": "*",
    "@rello-platform/ui": "github:rello-platform/rello-ui#v2.18.0" } }
JSON
  assert_exit "workspace skip + ui->rello-ui repo map — exit 0" "0" "$(csp_run "$TMP/csp-mixed")"

  # C9. SHA ahead of latest tag — OK, exit 0
  local SHA1="1111111111111111111111111111111111111111"
  csp_fixture csp-sha-ahead "@rello-platform/api-client" "github:rello-platform/api-client#$SHA1"
  printf 'ahead' > "$MOCK/api-client.compare.v2.18.0...$SHA1"
  assert_exit "SHA ahead of latest tag — exit 0" "0" "$(csp_run "$TMP/csp-sha-ahead")"

  # C10. SHA >=2 minors behind — FAIL, exit 1
  local SHA2="2222222222222222222222222222222222222222"
  csp_fixture csp-sha-fail "@rello-platform/api-client" "github:rello-platform/api-client#$SHA2"
  printf 'behind' > "$MOCK/api-client.compare.v2.18.0...$SHA2"
  printf 'behind' > "$MOCK/api-client.compare.v2.16.0...$SHA2"
  assert_exit "SHA >=2 minors behind — exit 1" "1" "$(csp_run "$TMP/csp-sha-fail")"

  # C11. SHA exactly 1 minor behind (>= second-newest minor) — WARN, exit 0
  local SHA3="3333333333333333333333333333333333333333"
  csp_fixture csp-sha-warn "@rello-platform/api-client" "github:rello-platform/api-client#$SHA3"
  printf 'behind' > "$MOCK/api-client.compare.v2.18.0...$SHA3"
  printf 'ahead'  > "$MOCK/api-client.compare.v2.16.0...$SHA3"
  assert_exit "SHA 1 minor behind — WARN, exit 0" "0" "$(csp_run "$TMP/csp-sha-warn")"

  # C12. no @rello-platform deps — exit 0
  mkdir -p "$TMP/csp-none"
  cat > "$TMP/csp-none/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "left-pad": "^1.0.0" } }
JSON
  assert_exit "no @rello-platform deps — exit 0" "0" "$(csp_run "$TMP/csp-none")"

  # C13. --root <subdir> resolution — exit 0
  mkdir -p "$TMP/csp-root/sub"
  cat > "$TMP/csp-root/sub/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "@rello-platform/permissions": "github:rello-platform/permissions#v0.41.0" } }
JSON
  assert_exit "--root <subdir> — exit 0" "0" "$(csp_run "$TMP/csp-root" --root sub)"

  printf '\ncheck-lockfile-ssh (v0.5.0)\n'

  # Shared fixture URLs. The sha fragment must survive --fix verbatim.
  local CLS_SHA="0123456789abcdef0123456789abcdef01234567"
  local CLS_SSH="git+ssh://git@github.com/rello-platform/vault-crypto.git#$CLS_SHA"
  local CLS_HTTPS="git+https://github.com/rello-platform/vault-crypto.git#$CLS_SHA"

  # cls helper: write a package-lock.json fixture (v3 `packages` shape).
  cls_fixture() {
    local name="$1" resolved="$2"
    mkdir -p "$TMP/$name"
    cat > "$TMP/$name/package-lock.json" <<JSON
{
  "name": "fixture",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "fixture" },
    "node_modules/@rello-platform/vault-crypto": {
      "resolved": "$resolved",
      "integrity": "sha512-fake"
    },
    "node_modules/left-pad": {
      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz"
    }
  }
}
JSON
  }

  # L1. clean lockfile (git+https + registry) — exit 0
  cls_fixture cls-clean "$CLS_HTTPS"
  assert_exit "clean lockfile (git+https + registry) — exit 0" "0" "$(run_in_fixture "$TMP/cls-clean" check-lockfile-ssh)"

  # L2. git+ssh entry (v3 packages shape) — exit 1
  cls_fixture cls-ssh "$CLS_SSH"
  assert_exit "git+ssh resolved entry — exit 1" "1" "$(run_in_fixture "$TMP/cls-ssh" check-lockfile-ssh)"

  # L2a. failure message names the offender path + URL + --fix remediation
  local cls_msg
  cls_msg="$(run_in_fixture_capture "$TMP/cls-ssh" check-lockfile-ssh || true)"
  if printf '%s' "$cls_msg" | grep -q "node_modules/@rello-platform/vault-crypto" \
     && printf '%s' "$cls_msg" | grep -q "git+ssh://git@github.com/rello-platform/vault-crypto" \
     && printf '%s' "$cls_msg" | grep -q "check-lockfile-ssh --fix"; then
    printf '  PASS  failure message names offender + URL + --fix remediation\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  failure message missing offender/URL/remediation; got: %s\n' "$cls_msg"
    FAIL=$((FAIL + 1))
  fi

  # L3. --fix rewrites to git+https preserving the sha — exit 0
  cls_fixture cls-fix "$CLS_SSH"
  assert_exit "--fix rewrites github ssh entry — exit 0" "0" "$(run_in_fixture "$TMP/cls-fix" check-lockfile-ssh --fix)"
  if grep -qF "\"resolved\": \"$CLS_HTTPS\"" "$TMP/cls-fix/package-lock.json" \
     && ! grep -q "git+ssh://" "$TMP/cls-fix/package-lock.json"; then
    printf '  PASS  --fix wrote git+https with sha preserved\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  --fix did not write expected git+https resolved value\n'
    FAIL=$((FAIL + 1))
  fi

  # L3a. post-fix re-check is green (self-healing loop closes) — exit 0
  assert_exit "post-fix re-check — exit 0" "0" "$(run_in_fixture "$TMP/cls-fix" check-lockfile-ssh)"

  # L3b. lockfile still parses as JSON after --fix
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$TMP/cls-fix/package-lock.json" 2>/dev/null; then
    printf '  PASS  lockfile still valid JSON after --fix\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  lockfile broken after --fix\n'
    FAIL=$((FAIL + 1))
  fi

  # L4. v1 nested `dependencies` shape — exit 1
  mkdir -p "$TMP/cls-v1"
  cat > "$TMP/cls-v1/package-lock.json" <<JSON
{
  "name": "fixture",
  "lockfileVersion": 1,
  "dependencies": {
    "@rello-platform/signals": {
      "version": "git+ssh://git@github.com/rello-platform/signals.git#$CLS_SHA",
      "resolved": "git+ssh://git@github.com/rello-platform/signals.git#$CLS_SHA",
      "dependencies": {
        "nested-dep": {
          "resolved": "git+ssh://git@github.com/rello-platform/nested.git#$CLS_SHA"
        }
      }
    }
  }
}
JSON
  assert_exit "v1 nested dependencies ssh — exit 1" "1" "$(run_in_fixture "$TMP/cls-v1" check-lockfile-ssh)"

  # L5. non-github git+ssh is NOT auto-fixable — --fix still exit 1
  cls_fixture cls-nongh "git+ssh://git@gitlab.example.com/org/repo.git#$CLS_SHA"
  assert_exit "non-github ssh, --fix unfixable — exit 1" "1" "$(run_in_fixture "$TMP/cls-nongh" check-lockfile-ssh --fix)"

  # L6. mixed github + non-github ssh, --fix — github fixed, exit 1 on remainder
  mkdir -p "$TMP/cls-mixed"
  cat > "$TMP/cls-mixed/package-lock.json" <<JSON
{
  "name": "fixture",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "fixture" },
    "node_modules/a": { "resolved": "$CLS_SSH" },
    "node_modules/b": { "resolved": "git+ssh://git@gitlab.example.com/org/repo.git#$CLS_SHA" }
  }
}
JSON
  assert_exit "mixed ssh, --fix — exit 1 (non-github remains)" "1" "$(run_in_fixture "$TMP/cls-mixed" check-lockfile-ssh --fix)"
  if grep -qF "\"resolved\": \"$CLS_HTTPS\"" "$TMP/cls-mixed/package-lock.json"; then
    printf '  PASS  mixed --fix still rewrote the github entry\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  mixed --fix did not rewrite the github entry\n'
    FAIL=$((FAIL + 1))
  fi

  # L7. missing package-lock.json — exit 2
  mkdir -p "$TMP/cls-missing"
  assert_exit "missing package-lock.json — exit 2" "2" "$(run_in_fixture "$TMP/cls-missing" check-lockfile-ssh)"

  # L8. malformed package-lock.json — exit 2
  mkdir -p "$TMP/cls-malformed"
  printf '{ not json' > "$TMP/cls-malformed/package-lock.json"
  assert_exit "malformed package-lock.json — exit 2" "2" "$(run_in_fixture "$TMP/cls-malformed" check-lockfile-ssh)"

  # L9. --root <subdir> resolution — exit 1 on ssh under sub/
  mkdir -p "$TMP/cls-root"
  cls_fixture cls-root/sub "$CLS_SSH"
  assert_exit "--root <subdir> ssh — exit 1" "1" "$(run_in_fixture "$TMP/cls-root" check-lockfile-ssh --root sub)"

  printf '\ncheck-stale-pins x check-lockfile-ssh integration (v0.5.0)\n'

  # C14. current pin + adjacent ssh lockfile — exit 1 (inherits the guard,
  #      zero hook edits) even though the pin itself is OK.
  mkdir -p "$TMP/csp-lock-ssh"
  cat > "$TMP/csp-lock-ssh/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "@rello-platform/permissions": "github:rello-platform/permissions#v0.41.0" } }
JSON
  cat > "$TMP/csp-lock-ssh/package-lock.json" <<JSON
{
  "name": "fixture",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "fixture" },
    "node_modules/@rello-platform/permissions": { "resolved": "$CLS_SSH" }
  }
}
JSON
  assert_exit "stale-pins: OK pin + ssh lockfile — exit 1" "1" "$(csp_run "$TMP/csp-lock-ssh")"

  # C14a. ...and the failure output names the lockfile remediation
  local csp_lock_msg
  csp_lock_msg="$( cd "$TMP/csp-lock-ssh" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins 2>&1 || true )"
  if printf '%s' "$csp_lock_msg" | grep -q "check-lockfile-ssh --fix"; then
    printf '  PASS  stale-pins failure output names check-lockfile-ssh --fix\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  stale-pins failure output missing lockfile remediation; got: %s\n' "$csp_lock_msg"
    FAIL=$((FAIL + 1))
  fi

  # C15. current pin + clean adjacent lockfile — exit 0
  mkdir -p "$TMP/csp-lock-clean"
  cat > "$TMP/csp-lock-clean/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "@rello-platform/permissions": "github:rello-platform/permissions#v0.41.0" } }
JSON
  cat > "$TMP/csp-lock-clean/package-lock.json" <<JSON
{
  "name": "fixture",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "fixture" },
    "node_modules/@rello-platform/permissions": { "resolved": "$CLS_HTTPS" }
  }
}
JSON
  assert_exit "stale-pins: OK pin + clean lockfile — exit 0" "0" "$(csp_run "$TMP/csp-lock-clean")"

  # C16. no @rello-platform deps + ssh lockfile — STILL exit 1 (the guard
  #      runs even on the no-deps early path; any git dep can be ssh-stamped).
  mkdir -p "$TMP/csp-nodeps-ssh"
  cat > "$TMP/csp-nodeps-ssh/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "left-pad": "^1.0.0" } }
JSON
  cat > "$TMP/csp-nodeps-ssh/package-lock.json" <<JSON
{
  "name": "fixture",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "fixture" },
    "node_modules/some-git-dep": { "resolved": "$CLS_SSH" }
  }
}
JSON
  assert_exit "stale-pins: no rello deps + ssh lockfile — exit 1" "1" "$(csp_run "$TMP/csp-nodeps-ssh")"

  # C17. ssh-lockfile guard is NOT fail-open offline (local check, no network)
  assert_exit "stale-pins offline + ssh lockfile — still exit 1" "1" \
    "$(cd "$TMP/csp-lock-ssh" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_SIMULATE_OFFLINE=1 "$CLI" check-stale-pins >/dev/null 2>&1; echo $?)"


  # ── verify-sql-objects ─────────────────────────────────────────────────
  printf '\nverify-sql-objects\n'

  # DB-independent paths only. The exit-1 (object genuinely missing) path
  # needs a live database and is proven per-consumer at rollout, not here.
  vso_run() {
    ( cd "$1" && shift && env -u DATABASE_URL -u DIRECT_URL -u DIRECT_DATABASE_URL \
        "$CLI" verify-sql-objects "$@" >/dev/null 2>&1; echo $? )
  }
  vso_out() {
    ( cd "$1" && shift && env -u DATABASE_URL -u DIRECT_URL -u DIRECT_DATABASE_URL \
        "$CLI" verify-sql-objects "$@" 2>&1 )
  }

  mkdir -p "$TMP/vso-ok/prisma/sql"
  printf '{"name":"fixture"}\n' > "$TMP/vso-ok/package.json"
  cat > "$TMP/vso-ok/prisma/sql/001.sql" <<'SQL'
CREATE INDEX IF NOT EXISTS idx_thing ON "Thing" ("a");
ALTER TYPE "public"."Status" ADD VALUE IF NOT EXISTS 'ARCHIVED';
SQL

  # V1. No database URL is UNVERIFIED (2), never a pass. A repo whose URL
  # variable is spelled differently would otherwise read green forever.
  assert_exit "no DB url — exit 2 (UNVERIFIED, not pass)" "2" "$(vso_run "$TMP/vso-ok")"

  # V2. ⚑ An unrecognised flag must be a hard error, not a silent no-op.
  # Measured 2026-08-18: `--sqlDir` (the flag is `--sql-dir`) was dropped
  # without a word, the run silently fell back to the default directory, and
  # the survey compared one repo's declarations against another repo's
  # database while reporting total confidence.
  assert_exit "unknown flag — exit 2" "2" "$(vso_run "$TMP/vso-ok" --sqlDir /nope)"
  # NB: capture FIRST, then grep. The harness runs under `set -o pipefail`, so
  # `vso_out … | grep -q` yields verify-sql-objects' exit 2 even when grep
  # matches — the assertion would fail on output that is exactly right.
  # `|| true` because these paths exit non-zero BY DESIGN and the harness
  # runs under `set -e` — without it the assignment aborts the whole suite.
  vso_unknown_out="$(vso_out "$TMP/vso-ok" --sqlDir /nope || true)"
  if printf '%s' "$vso_unknown_out" | grep -q "unrecognised argument"; then
    printf '  PASS  unknown flag names itself\n'; PASS=$((PASS + 1))
  else
    printf '  FAIL  unknown flag names itself\n'; FAIL=$((FAIL + 1))
  fi

  # V3. ALTER TYPE … ADD VALUE is MODELLED, not reported as a parser gap.
  # Six of these across Harvest-Home / Open-House-Hub / Newsletter-Studio were
  # the only thing holding those three repos at UNVERIFIED.
  vso_inv_out="$(vso_out "$TMP/vso-ok" --inventory || true)"
  if printf '%s' "$vso_inv_out" | grep -q "enumvalue public.Status.ARCHIVED"; then
    printf '  PASS  ALTER TYPE ADD VALUE parsed as an enumvalue\n'; PASS=$((PASS + 1))
  else
    printf '  FAIL  ALTER TYPE ADD VALUE parsed as an enumvalue\n'; FAIL=$((FAIL + 1))
  fi

  # V4. DDL the parser does not model is UNVERIFIED, never silently skipped.
  mkdir -p "$TMP/vso-gap/prisma/sql"
  printf '{"name":"fixture"}\n' > "$TMP/vso-gap/package.json"
  printf 'CREATE FOREIGN TABLE weird () SERVER s;\n' > "$TMP/vso-gap/prisma/sql/001.sql"
  assert_exit "unmodelled DDL — exit 2" "2" "$(vso_run "$TMP/vso-gap")"

  # V5. A missing prisma/sql directory is UNVERIFIED, not a vacuous pass.
  mkdir -p "$TMP/vso-nodir"
  printf '{"name":"fixture"}\n' > "$TMP/vso-nodir/package.json"
  assert_exit "no prisma/sql dir — exit 2" "2" "$(vso_run "$TMP/vso-nodir")"

  # ── check-dist-fresh ──────────────────────────────────────────────────────
  # The pure classification core is pinned in test/dist-fresh-cases.mjs (the
  # `scanSource` pattern). Here we pin the CLI-level fail-closed contract, which
  # is the half that decides whether a caller can be fooled.
  printf '\ncheck-dist-fresh:\n'
  node "$PKG_ROOT/test/dist-fresh-cases.mjs" >/dev/null 2>&1
  assert_exit "pure core unit tests" "0" "$?"

  # D1. Not a git work tree — UNVERIFIED, never a pass.
  mkdir -p "$TMP/df-nogit"
  printf '{"name":"f","scripts":{"build":"tsc"}}\n' > "$TMP/df-nogit/package.json"
  assert_exit "not a git work tree — exit 2" "2" "$(run_in_fixture "$TMP/df-nogit" check-dist-fresh)"

  # D2. No build script — UNVERIFIED. Nothing to reproduce from.
  mkdir -p "$TMP/df-nobuild"
  ( cd "$TMP/df-nobuild" && git init -q && printf '{"name":"f"}\n' > package.json \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
  assert_exit "no build script — exit 2" "2" "$(run_in_fixture "$TMP/df-nobuild" check-dist-fresh)"

  # D3. Build script but NO committed dist — UNVERIFIED, emphatically not 0.
  # This is the cell that would let a staleness gate run green forever.
  mkdir -p "$TMP/df-nodist"
  ( cd "$TMP/df-nodist" && git init -q \
      && printf '{"name":"f","scripts":{"build":"true"}}\n' > package.json \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
  assert_exit "no committed dist — exit 2" "2" "$(run_in_fixture "$TMP/df-nodist" check-dist-fresh)"

  # D4. A ref that does not exist — UNVERIFIED, not a pass.
  assert_exit "missing ref — exit 2" "2" "$(run_in_fixture "$TMP/df-nodist" check-dist-fresh --ref v9.9.9)"

  # D5. --root pointing nowhere — UNVERIFIED.
  assert_exit "--root nonexistent — exit 2" "2" "$(run_in_fixture "$TMP/df-nodist" check-dist-fresh --root /nonexistent-df)"

  printf '\nTotal: %d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
