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

  # v0.13.0 — the axis is AGE, so the mock must carry tag DATES. These are
  # written relative to now so the cells never rot into passing by calendar.
  _tagdate() { # repo tag daysAgo
    node -e 'process.stdout.write(new Date(Date.now() - Number(process.argv[1])*86400000).toISOString())' "$3" \
      > "$MOCK/$1.tagdate.$2"
  }
  _tagdate permissions v0.38.0 60    # old AND several minors behind
  _tagdate permissions v0.39.0 45
  _tagdate permissions v0.40.0 2     # FRESH but one minor behind
  _tagdate api-client  v1.9.0  200
  _tagdate api-client  v2.14.0 5

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

  # C2. 🔴 THE INVERSION, HALF ONE: behind by a minor but only 2 DAYS OLD -> OK.
  # Under the old minor-count axis this was WARN, and a 2-minor version of it
  # was a hard FAIL — which is how four repos that had changed in no way went
  # from current to push-blocked because a package shipped three times in one
  # morning.
  csp_fixture csp-warn "@rello-platform/permissions" "github:rello-platform/permissions#v0.40.0"
  assert_exit "fresh pin (2d old, 1 minor behind) — exit 0" "0" "$(csp_run "$TMP/csp-warn")"

  # C3. 🔴 THE INVERSION, HALF TWO: 60 DAYS OLD -> FAIL.
  # Age is the risk. A repo running a gate published two months ago is behind in
  # the way that matters, however few versions separate it from latest.
  csp_fixture csp-fail "@rello-platform/permissions" "github:rello-platform/permissions#v0.38.0"
  assert_exit "stale pin (60d old) — exit 1" "1" "$(csp_run "$TMP/csp-fail")"

  # C3b. 🟢 CONTROL: the message states the AGE, not the version distance —
  # "3 minors behind" tells a reader nothing they can act on.
  csp_age_msg="$( cd "$TMP/csp-fail" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins 2>&1 || true )"
  case "$csp_age_msg" in
    *"is 60d old"*) assert_exit "FAIL message reports AGE in days" "0" "0";;
    *)              assert_exit "FAIL message reports AGE in days" "0" "1";;
  esac

  # C3c. threshold is configurable, and raising it above the age clears the FAIL
  # — proves the verdict is driven by the age comparison and not by something
  # incidental that happens to correlate with it.
  assert_exit "raising the fail threshold past the age clears it — exit 0" "0" \
    "$(cd "$TMP/csp-fail" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PIN_FAIL_DAYS=365 RELLO_STALE_PIN_WARN_DAYS=300 "$CLI" check-stale-pins >/dev/null 2>&1; echo $?)"

  # C3d. 🔴 ARMING: a recorded baseline turns pre-existing debt into DEBT, not
  # FAIL — and the repo becomes pushable. Measured 2026-09-04 across 15 repos:
  # 70 pins are behind, median age 88d, max 138d, and a cold 30d threshold would
  # have blocked 56 of them. That is a stop-work order, not a gate.
  cp -R "$TMP/csp-fail" "$TMP/csp-baseline"
  ( cd "$TMP/csp-baseline" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins --write-baseline >/dev/null 2>&1 )
  assert_exit "baselined pre-existing debt does not block — exit 0" "0" "$(csp_run "$TMP/csp-baseline")"

  # C3e. 🟢 CONTROL: the baseline forgives NOTHING. A baselined pin recorded at
  # a DIFFERENT version — bumped once, then allowed to go stale again — fails.
  ( cd "$TMP/csp-baseline" && node -e '
      const fs = require("fs");
      const b = JSON.parse(fs.readFileSync(".stale-pin-baseline.json", "utf8"));
      for (const k of Object.keys(b.pins)) b.pins[k].version = "9.9.9";
      fs.writeFileSync(".stale-pin-baseline.json", JSON.stringify(b, null, 2));
    ' )
  assert_exit "baseline recorded at another version still FAILs — exit 1" "1" "$(csp_run "$TMP/csp-baseline")"

  # C3f. 🟢 CONTROL: arming records ONLY what is over the threshold. A healthy
  # repo writes an empty ledger, so arming can never silently widen the
  # exemption to pins that were fine.
  cp -R "$TMP/csp-ok" "$TMP/csp-baseline-clean"
  ( cd "$TMP/csp-baseline-clean" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins --write-baseline >/dev/null 2>&1 )
  csp_bl_n="$( node -e '
      const fs=require("fs");
      try { process.stdout.write(String(Object.keys(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).pins).length)); }
      catch { process.stdout.write("0"); }
    ' "$TMP/csp-baseline-clean/.stale-pin-baseline.json" )"
  assert_exit "arming a healthy repo records zero pins" "0" "$([ "$csp_bl_n" = "0" ] && echo 0 || echo 1)"

  # ── A-08 (v0.19.0): --write-baseline MERGES, it does not overwrite ───────
  # Measured 2026-09-05 on MarketIntel-NEW: the writer emitted a fixed
  # {version, recordedAt} per entry and replaced the top-level _comment, so one
  # run deleted ageDaysAtArming / latestAtArming / why and the hand-written
  # "56 of 70 pins" rationale (md5 9ecb79d3… → 10340948…). Two repos carry such
  # content. The writer must touch only version/recordedAt on pins it records,
  # keep every other key of every entry, keep _comment, and never drop an entry
  # it did not author.
  printf '
check-stale-pins --write-baseline merges (A-08, v0.19.0)
'
  _tagdate rello-ui v2.14.0 95     # stale: the ledger fixture below records it
  mkdir -p "$TMP/a08"
  cat > "$TMP/a08/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "@rello-platform/ui": "github:rello-platform/rello-ui#v2.14.0" } }
JSON
  # MarketIntel-NEW's real ledger shape (values abbreviated, keys verbatim).
  cat > "$TMP/a08/.stale-pin-baseline.json" <<'JSON'
{
  "_comment": "DEBT LEDGER, not configuration. Arming cold would have failed 56 of 70 pins across 15 repos — a stop-work order, not a gate.",
  "pins": {
    "@rello-platform/ui": {
      "version": "2.14.0",
      "recordedAt": "2026-09-05",
      "ageDaysAtArming": 89,
      "latestAtArming": "2.29.0",
      "why": "89 days old when this ledger was armed on 2026-09-05, past the 30-day limit."
    }
  }
}
JSON
  a08_md5_before="$(md5 -q "$TMP/a08/.stale-pin-baseline.json" 2>/dev/null || md5sum "$TMP/a08/.stale-pin-baseline.json" | cut -d' ' -f1)"
  ( cd "$TMP/a08" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins --write-baseline >/dev/null 2>&1 )
  a08_md5_after="$(md5 -q "$TMP/a08/.stale-pin-baseline.json" 2>/dev/null || md5sum "$TMP/a08/.stale-pin-baseline.json" | cut -d' ' -f1)"
  # C12. 🔴 A re-run over a ledger that already records the same pin at the same
  # version is a NO-OP: byte-identical file (so recordedAt is not reset either —
  # resetting it would erase the debt's age, which is the ledger's whole point).
  assert_exit "A-08: re-arming an already-recorded pin leaves the ledger byte-identical" "0"     "$([ "$a08_md5_before" = "$a08_md5_after" ] && echo 0 || echo 1)"
  a08_keys="$( node -e '
      const b=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const e=(b.pins||{})["@rello-platform/ui"]||{};
      process.stdout.write([b._comment&&b._comment.includes("56 of 70")?"comment":"", e.ageDaysAtArming===89?"age":"", e.latestAtArming==="2.29.0"?"latest":"", typeof e.why==="string"?"why":"", e.recordedAt==="2026-09-05"?"recordedAt":""].filter(Boolean).join(","));
    ' "$TMP/a08/.stale-pin-baseline.json" )"
  assert_exit "A-08: hand-authored keys + _comment + recordedAt survive --write-baseline" "0"     "$([ "$a08_keys" = "comment,age,latest,why,recordedAt" ] && echo 0 || echo 1)"
  # C13. 🟢 CONTROL — the writer still WRITES: a stale pin the ledger does not
  # yet record is added beside the preserved entry, and an entry recorded at a
  # different version is re-recorded (version + recordedAt only, other keys kept).
  cat > "$TMP/a08/package.json" <<'JSON'
{ "name": "fixture", "dependencies": { "@rello-platform/ui": "github:rello-platform/rello-ui#v2.14.0", "@rello-platform/permissions": "github:rello-platform/permissions#v0.38.0" } }
JSON
  ( cd "$TMP/a08" && node -e '
      const fs=require("fs"); const b=JSON.parse(fs.readFileSync(".stale-pin-baseline.json","utf8"));
      b.pins["@rello-platform/ui"].version="2.10.0"; b.extraTopLevel="kept";
      fs.writeFileSync(".stale-pin-baseline.json", JSON.stringify(b,null,2)+"\n");
    ' )
  ( cd "$TMP/a08" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins --write-baseline >/dev/null 2>&1 )
  a08_merge="$( node -e '
      const b=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const ui=(b.pins||{})["@rello-platform/ui"]||{}, pm=(b.pins||{})["@rello-platform/permissions"]||{};
      const today=new Date().toISOString().slice(0,10);
      process.stdout.write([ui.version==="2.14.0"?"ui-rerecorded":"", ui.recordedAt===today?"ui-redated":"", ui.why?"ui-why-kept":"", ui.ageDaysAtArming===89?"ui-age-kept":"", pm.version==="0.38.0"&&pm.recordedAt===today?"perm-added":"", b.extraTopLevel==="kept"?"toplevel-kept":"", b._comment&&b._comment.includes("56 of 70")?"comment-kept":""].filter(Boolean).join(","));
    ' "$TMP/a08/.stale-pin-baseline.json" )"
  assert_exit "A-08: re-record at a new version + add a new pin, keeping every other key" "0"     "$([ "$a08_merge" = "ui-rerecorded,ui-redated,ui-why-kept,ui-age-kept,perm-added,toplevel-kept,comment-kept" ] && echo 0 || echo 1)"

  # C3g. 🔴 THE OPERATOR-FACING LINE MUST NAME THE REAL REASON. After the axis
  # changed, the header and the failure summary still said ">= 2 minors behind"
  # — and a reader concluded the age gate had been reverted, settling it only by
  # reading the decision code. A stale sentence beside live code is a second,
  # wrong implementation. This pins the summary to the axis so it cannot drift
  # again silently.
  csp_sum="$( cd "$TMP/csp-fail" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins 2>&1 || true )"
  case "$csp_sum" in
    *"minor"*"canonical-latest"*) assert_exit "summary does NOT name the retired axis" "0" "1";;
    *)                            assert_exit "summary does NOT name the retired axis" "0" "0";;
  esac
  case "$csp_sum" in
    *"FAIL: 1"*) assert_exit "A-01: FAIL summary carries the FAIL count" "0" "0";;
    *)           assert_exit "A-01: FAIL summary carries the FAIL count" "0" "1";;
  esac
  case "$csp_sum" in
    *"too OLD"*) assert_exit "summary names AGE as the reason" "0" "0";;
    *)           assert_exit "summary names AGE as the reason" "0" "1";;
  esac
  case "$csp_sum" in
    *"--write-baseline"*) assert_exit "summary offers the baseline for pre-existing debt" "0" "0";;
    *)                    assert_exit "summary offers the baseline for pre-existing debt" "0" "1";;
  esac

  # C3h. 🔴 THE OPERATOR-FACING LOCKFILE MESSAGE MUST NAME THE TRAP.
  # After a pin bump, npm re-stamps git+ssh and the natural reflex is
  # `git checkout origin/main -- package-lock.json` — which reverts the bump,
  # because main's lockfile still resolves the OLD version. An agent nearly took
  # it 2026-09-05. The line a blocked person reads has to name the right ACTION,
  # not just the right diagnosis.
  mkdir -p "$TMP/lk-msg"
  printf '{"name":"t","dependencies":{"@rello-platform/slugs":"github:rello-platform/slugs#v0.6.1"}}\n' > "$TMP/lk-msg/package.json"
  printf '{"name":"t","lockfileVersion":3,"packages":{"node_modules/@rello-platform/slugs":{"version":"0.6.1","resolved":"git+ssh://git@github.com/rello-platform/slugs.git#abc123"}}}\n' > "$TMP/lk-msg/package-lock.json"
  lk_msg="$( cd "$TMP/lk-msg" && "$CLI" check-lockfile-ssh 2>&1 || true )"
  case "$lk_msg" in
    *"DO NOT run: git checkout origin/main -- package-lock.json"*)
      assert_exit "lockfile message names the revert trap" "0" "0";;
    *) assert_exit "lockfile message names the revert trap" "0" "1";;
  esac
  case "$lk_msg" in
    *"--fix heals in place and KEEPS the new version"*)
      assert_exit "lockfile message names --fix as the remedy" "0" "0";;
    *) assert_exit "lockfile message names --fix as the remedy" "0" "1";;
  esac

  # ── NET-NEW, NOT TOTAL STATE (v0.18.0) ────────────────────────────────────
  # A pin that ages past the threshold while nobody touched it must not become
  # the problem of whoever pushes next. That ambush picks its victim at random
  # and lands mid-unrelated-work — measured: four blocked pushes across three
  # agents in one day, one of them mid-PR on an unrelated nurture fix.
  #
  # The discriminator is the BASE BRANCH pin, not the baseline file: identical
  # to base means this push did not touch it.
  csp_netnew() {  # fixture, basePin, currentPin -> exit code
    local d="$TMP/$1"; mkdir -p "$d/base"
    ( cd "$d" && git init -q 2>/dev/null || true )
    printf '{"name":"f","dependencies":{"@rello-platform/permissions":"%s"}}\n' "$2" > "$d/base-package.json"
    printf '{"name":"f","dependencies":{"@rello-platform/permissions":"%s"}}\n' "$3" > "$d/package.json"
    ( cd "$d" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1 || true )
    ( cd "$d" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_BASE_REF="$4" "$CLI" check-stale-pins >/dev/null 2>&1; echo $? )
  }

  # C9. 🔴 AGED IN PLACE — base and current identical, both stale -> does NOT block.
  mkdir -p "$TMP/nn-aged"
  ( cd "$TMP/nn-aged" && git init -q
    printf '{"name":"f","dependencies":{"@rello-platform/permissions":"github:rello-platform/permissions#v0.38.0"}}\n' > package.json
    git add -A && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
  assert_exit "aged in place (base == current) does NOT block — exit 0" "0" \
    "$(cd "$TMP/nn-aged" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_BASE_REF=HEAD "$CLI" check-stale-pins >/dev/null 2>&1; echo $?)"

  # C10. 🟢 CONTROL — THE GATE IS NOT A LOGGER. The push MOVES the pin to an
  # older stale version -> still FAILS. If this passed, every FAIL would
  # self-absorb and the gate would have stopped being a gate.
  ( cd "$TMP/nn-aged" && printf '{"name":"f","dependencies":{"@rello-platform/permissions":"github:rello-platform/permissions#v0.39.0"}}\n' > package.json
    git add -A && git -c user.email=t@t -c user.name=t commit -qm newer
    printf '{"name":"f","dependencies":{"@rello-platform/permissions":"github:rello-platform/permissions#v0.38.0"}}\n' > package.json ) >/dev/null 2>&1
  assert_exit "push MOVES a pin to an older stale version — exit 1" "1" \
    "$(cd "$TMP/nn-aged" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_BASE_REF=HEAD "$CLI" check-stale-pins >/dev/null 2>&1; echo $?)"

  # C11. 🟢 CONTROL — a stale pin ADDED by this push (absent from base) FAILS.
  mkdir -p "$TMP/nn-added"
  ( cd "$TMP/nn-added" && git init -q
    printf '{"name":"f","dependencies":{}}\n' > package.json
    git add -A && git -c user.email=t@t -c user.name=t commit -qm empty
    printf '{"name":"f","dependencies":{"@rello-platform/permissions":"github:rello-platform/permissions#v0.38.0"}}\n' > package.json ) >/dev/null 2>&1
  assert_exit "push ADDS an already-stale pin — exit 1" "1" \
    "$(cd "$TMP/nn-added" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_BASE_REF=HEAD "$CLI" check-stale-pins >/dev/null 2>&1; echo $?)"

  # ── A-09 (v0.19.0): SHA PINS GO THROUGH THE SAME DISCRIMINATOR AS TAGS ──
  # Measured 2026-09-05 (pre-flight §4): the SHA branch set HAS_FAIL=1 directly
  # on ">= 2 minors behind", skipping the baseline and the base-branch check —
  # a SHA pin that aged in place ambushed the next pusher and no ledger entry
  # could absorb it (exit 1 with and without one). PathfinderPro and Rello both
  # carry SHA pins. Same four outcomes as a tag: identical to origin/main →
  # DEBT [aged in place]; baselined at that SHA → DEBT; added/changed by this
  # push → FAIL; base unreadable → FAIL (fail-closed, as tags).
  printf '\ncheck-stale-pins SHA pins use the net-new discriminator (A-09, v0.19.0)\n'
  A09_SHA="3d21e6116143367ac99cac9a244b24dca7616ac2"   # "the v2.14.0 commit": 2 minors behind v2.18.0
  A09_NEW="552bdadb0000000000000000000000000000c0de"   # another SHA the push could move to
  printf 'behind\n' > "$MOCK/api-client.compare.v2.18.0...$A09_SHA"
  printf 'behind\n' > "$MOCK/api-client.compare.v2.16.0...$A09_SHA"
  printf 'behind\n' > "$MOCK/api-client.compare.v2.18.0...$A09_NEW"
  printf 'behind\n' > "$MOCK/api-client.compare.v2.16.0...$A09_NEW"
  a09_pkg() { printf '{"name":"f","dependencies":{"@rello-platform/api-client":"github:rello-platform/api-client#%s"}}\n' "$1"; }
  a09_run() { ( cd "$1" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_BASE_REF="${2:-HEAD}" "$CLI" check-stale-pins 2>&1; echo "EXIT=$?" ); }

  # C14. 🔴 AGED IN PLACE — the SHA pin is identical on the base branch → DEBT, exit 0.
  mkdir -p "$TMP/a09-aged"
  ( cd "$TMP/a09-aged" && git init -q && a09_pkg "$A09_SHA" > package.json \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
  a09_out="$(a09_run "$TMP/a09-aged")"
  assert_exit "A-09: SHA pin identical to base branch → exit 0" "0" "$(printf '%s' "$a09_out" | sed -n 's/^EXIT=//p')"
  case "$a09_out" in *"DEBT  @rello-platform/api-client"*"aged in place"*) assert_exit "A-09: … and is reported as DEBT [aged in place]" "0" "0";; *) assert_exit "A-09: … and is reported as DEBT [aged in place]" "0" "1";; esac

  # C15. 🟢 CONTROL — the push CHANGES the SHA (to another stale one) → FAIL, exit 1.
  ( cd "$TMP/a09-aged" && a09_pkg "$A09_NEW" > package.json )
  a09_out="$(a09_run "$TMP/a09-aged")"
  assert_exit "A-09: SHA pin CHANGED by this push → exit 1" "1" "$(printf '%s' "$a09_out" | sed -n 's/^EXIT=//p')"
  case "$a09_out" in *"FAIL  @rello-platform/api-client"*"CHANGED by this push"*) assert_exit "A-09: … and names CHANGED by this push" "0" "0";; *) assert_exit "A-09: … and names CHANGED by this push" "0" "1";; esac
  ( cd "$TMP/a09-aged" && a09_pkg "$A09_SHA" > package.json )

  # C16. 🟢 CONTROL — a stale SHA pin ADDED by this push → FAIL, exit 1.
  mkdir -p "$TMP/a09-added"
  ( cd "$TMP/a09-added" && git init -q && printf '{"name":"f","dependencies":{}}\n' > package.json \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm empty && a09_pkg "$A09_SHA" > package.json ) >/dev/null 2>&1
  assert_exit "A-09: stale SHA pin ADDED by this push → exit 1" "1" "$(a09_run "$TMP/a09-added" | sed -n 's/^EXIT=//p')"

  # C17. 🔴 BASELINED — a ledger entry recording that SHA absorbs it (pre-flight §2.3 case B), even when the base is unreadable.
  mkdir -p "$TMP/a09-baselined"
  a09_pkg "$A09_SHA" > "$TMP/a09-baselined/package.json"        # not a git repo → base unreadable
  printf '{"pins":{"@rello-platform/api-client":{"version":"%s","recordedAt":"2026-09-05"}}}\n' "$A09_SHA" > "$TMP/a09-baselined/.stale-pin-baseline.json"
  a09_out="$(a09_run "$TMP/a09-baselined" origin/main)"
  assert_exit "A-09: baselined SHA pin → exit 0" "0" "$(printf '%s' "$a09_out" | sed -n 's/^EXIT=//p')"
  case "$a09_out" in *"DEBT  @rello-platform/api-client"*"baselined"*) assert_exit "A-09: … reported as DEBT [baselined]" "0" "0";; *) assert_exit "A-09: … reported as DEBT [baselined]" "0" "1";; esac

  # C18. 🟢 CONTROL — base unreadable and NOT baselined → FAIL-CLOSED, exit 1 (as tags).
  mkdir -p "$TMP/a09-unreadable"
  a09_pkg "$A09_SHA" > "$TMP/a09-unreadable/package.json"
  a09_out="$(a09_run "$TMP/a09-unreadable" origin/main)"
  assert_exit "A-09: base unreadable, not baselined → exit 1 (fail-closed)" "1" "$(printf '%s' "$a09_out" | sed -n 's/^EXIT=//p')"
  case "$a09_out" in *"cannot read origin/main:package.json"*) assert_exit "A-09: … and says why" "0" "0";; *) assert_exit "A-09: … and says why" "0" "1";; esac

  # C19. 🔴 --write-baseline RECORDS a stale SHA pin (so the ledger can carry it).
  cp -R "$TMP/a09-unreadable" "$TMP/a09-arm"
  ( cd "$TMP/a09-arm" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins --write-baseline >/dev/null 2>&1 )
  a09_rec="$( node -e 'const b=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write(String((b.pins||{})["@rello-platform/api-client"]?.version||""))' "$TMP/a09-arm/.stale-pin-baseline.json" 2>/dev/null )"
  assert_exit "A-09: --write-baseline records the SHA pin" "0" "$([ "$a09_rec" = "$A09_SHA" ] && echo 0 || echo 1)"

  # C20. 🟢 CONTROL — the allowlist path is untouched: Rello's real EX-1 shape
  # (scripts/stale-pin-exceptions.json, key → reason string) still short-circuits
  # a SHA pin to OK allowlisted before any lookup. D-18: this entry is the only
  # thing between Rello's api-client SHA pin and a hard FAIL.
  mkdir -p "$TMP/a09-ex1/scripts"
  a09_pkg "$A09_SHA" > "$TMP/a09-ex1/package.json"
  cat > "$TMP/a09-ex1/scripts/stale-pin-exceptions.json" <<'JSON'
{
  "@rello-platform/api-client": "EX-1 intentional hold: pinned to the v2.19.0 commit (ahead of latest tag v2.18.0; adds getOvenBaseUrl()) — no v2.19.0 git tag exists yet, so this cannot be a tag pin. Bumping to v2.18.0 would be a downgrade. See DISCOVERED-PINCONV-PHASE2-INTENTIONAL-PIN-EXCEPTIONS-260524 (EX-1)."
}
JSON
  a09_out="$(a09_run "$TMP/a09-ex1" origin/main)"
  assert_exit "A-09: EX-1 allowlist shape still classifies OK allowlisted → exit 0" "0" "$(printf '%s' "$a09_out" | sed -n 's/^EXIT=//p')"
  case "$a09_out" in *"OK    @rello-platform/api-client  -> allowlisted: EX-1"*) assert_exit "A-09: … with the allowlisted reason line" "0" "0";; *) assert_exit "A-09: … with the allowlisted reason line" "0" "1";; esac

  # C4. full major behind — in a REAL git fixture with a readable base (A-01,
  # v0.19.0). Until v0.19.0 this fixture was not a git repo, so the run landed
  # on the fail-closed __BASE_UNREADABLE__ path and the test passed for a
  # reason unrelated to its name (closeout audit S1 / ledger C-04). Two cells:
  #   C4a — the major-behind pin is ADDED by this push → FAIL, exit 1, summary says FAIL: 1.
  #   C4b — the same pin identical on the base branch → today ABSORBED as DEBT,
  #         exit 0. ⚑ That is A-02 (ledger; OPEN): the header promises a full
  #         major behind FAILs at any age. This cell DOCUMENTS the current
  #         behaviour so the summary is at least truthful about it; flip it to
  #         exit 1 when A-02 lands.
  mkdir -p "$TMP/csp-major"
  ( cd "$TMP/csp-major" && git init -q && printf '{"name":"f","dependencies":{}}\n' > package.json \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm empty ) >/dev/null 2>&1
  csp_fixture csp-major "@rello-platform/api-client" "github:rello-platform/api-client#v1.9.0"
  c4a_out="$( cd "$TMP/csp-major" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_BASE_REF=HEAD "$CLI" check-stale-pins 2>&1; echo "EXIT=$?" )"
  assert_exit "C4a: 1 major behind, ADDED by this push — exit 1" "1" "$(printf '%s' "$c4a_out" | sed -n 's/^EXIT=//p')"
  case "$c4a_out" in *"FAIL: 1"*) assert_exit "A-01: FAIL summary counts what the run found (FAIL: 1)" "0" "0";; *) assert_exit "A-01: FAIL summary counts what the run found (FAIL: 1)" "0" "1";; esac
  ( cd "$TMP/csp-major" && git add -A && git -c user.email=t@t -c user.name=t commit -qm pin ) >/dev/null 2>&1
  c4b_out="$( cd "$TMP/csp-major" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" RELLO_STALE_PINS_BASE_REF=HEAD "$CLI" check-stale-pins 2>&1; echo "EXIT=$?" )"
  assert_exit "C4b: 1 major behind, aged in place — absorbed as DEBT today (A-02 open) — exit 0" "0" "$(printf '%s' "$c4b_out" | sed -n 's/^EXIT=//p')"

  # ── A-01 (v0.19.0): THE SUCCESS LINE STATES WHAT THE RUN FOUND ────────────
  # check-stale-pins.sh:728 @ 2946cd0 printed "OK: all @rello-platform/* pins
  # within 1 minor of canonical-latest" on every exit-0 run — beside a DEBT
  # line 12 minors behind, or a WARN "inside the 14d window" 3 minors behind.
  # The final line must carry the counts (FAIL · DEBT · WARN) and claim OK only
  # when FAIL = 0; it must never assert the retired distance axis.
  printf '\ncheck-stale-pins summary states counts (A-01, v0.19.0)\n'
  # C21. 🔴 an exit-0 run carrying a DEBT: summary says DEBT: 1, never "within 1 minor".
  case "$c4b_out" in *"within 1 minor"*) assert_exit "A-01: exit-0 summary does NOT claim 'within 1 minor'" "0" "1";; *) assert_exit "A-01: exit-0 summary does NOT claim 'within 1 minor'" "0" "0";; esac
  case "$c4b_out" in *"OK"*"FAIL: 0"*"DEBT: 1"*) assert_exit "A-01: exit-0 summary reads OK … FAIL: 0 · DEBT: 1" "0" "0";; *) assert_exit "A-01: exit-0 summary reads OK … FAIL: 0 · DEBT: 1" "0" "1";; esac
  # C22. 🔴 closeout Probe A: a FRESH tag 3 minors behind is a per-dep OK/WARN and must not be summarised as "within 1 minor".
  csp_fixture csp-probe-a "@rello-platform/permissions" "github:rello-platform/permissions#v0.40.0"
  pa_out="$( cd "$TMP/csp-probe-a" && RELLO_STALE_PINS_MOCK_DIR="$MOCK" "$CLI" check-stale-pins 2>&1; echo "EXIT=$?" )"
  assert_exit "Probe A: fresh tag one minor behind — exit 0" "0" "$(printf '%s' "$pa_out" | sed -n 's/^EXIT=//p')"
  case "$pa_out" in *"within 1 minor"*) assert_exit "A-01: Probe-A summary does NOT claim 'within 1 minor'" "0" "1";; *) assert_exit "A-01: Probe-A summary does NOT claim 'within 1 minor'" "0" "0";; esac
  case "$pa_out" in *"FAIL: 0"*) assert_exit "A-01: Probe-A summary carries FAIL: 0" "0" "0";; *) assert_exit "A-01: Probe-A summary carries FAIL: 0" "0" "1";; esac
  # C23. 🟢 CONTROL — the FAIL path never prints an OK line.
  case "$c4a_out" in *$'\nOK'*) assert_exit "A-01: a run with a FAIL prints no OK line" "0" "1";; *) assert_exit "A-01: a run with a FAIL prints no OK line" "0" "0";; esac

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

  # ── check-manifest-regression (E) ─────────────────────────────────────────
  # The pure diff is unit-tested in test/manifest-regression-cases.mjs. These
  # cells pin the FAIL-CLOSED half, which only exists at the CLI boundary.

  # E1. Not a git work tree — UNVERIFIED, never a pass.
  mkdir -p "$TMP/mr-nogit"
  printf '{"name":"f","version":"1.0.0"}\n' > "$TMP/mr-nogit/package.json"
  assert_exit "manifest: not a git work tree — exit 2" "2" "$(run_in_fixture "$TMP/mr-nogit" check-manifest-regression)"

  # E2. No package.json — UNVERIFIED.
  mkdir -p "$TMP/mr-nopkg"
  ( cd "$TMP/mr-nopkg" && git init -q && echo x > a.txt \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
  assert_exit "manifest: no package.json — exit 2" "2" "$(run_in_fixture "$TMP/mr-nopkg" check-manifest-regression)"

  # E3. No v* tag to compare against — UNVERIFIED. A package with no published
  # state has no manifest to regress FROM, and that is not a pass.
  mkdir -p "$TMP/mr-notag"
  ( cd "$TMP/mr-notag" && git init -q \
      && printf '{"name":"f","version":"1.0.0"}\n' > package.json \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
  assert_exit "manifest: no baseline tag — exit 2" "2" "$(run_in_fixture "$TMP/mr-notag" check-manifest-regression)"

  # E4. A baseline ref that does not exist — UNVERIFIED, not a pass.
  assert_exit "manifest: missing --against ref — exit 2" "2" "$(run_in_fixture "$TMP/mr-notag" check-manifest-regression --against v9.9.9)"

  # E5. GREEN on an unchanged manifest against a real tag.
  ( cd "$TMP/mr-notag" && git tag v1.0.0 )
  assert_exit "manifest: unchanged vs tag — exit 0" "0" "$(run_in_fixture "$TMP/mr-notag" check-manifest-regression)"

  # E6. 🔴 RED on the real incident: version decrease.
  ( cd "$TMP/mr-notag" && printf '{"name":"f","version":"0.9.0"}\n' > package.json )
  assert_exit "manifest: version decrease — exit 1" "1" "$(run_in_fixture "$TMP/mr-notag" check-manifest-regression)"

  # E7. 🔴 RED on a narrowed exports map.
  mkdir -p "$TMP/mr-narrow"
  ( cd "$TMP/mr-narrow" && git init -q \
      && printf '{"name":"f","version":"1.0.0","exports":{".":{"import":"./a.js","require":"./a.cjs"}}}\n' > package.json \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm i && git tag v1.0.0 \
      && printf '{"name":"f","version":"1.0.0","exports":{".":{"import":"./a.js"}}}\n' > package.json )
  assert_exit "manifest: exports narrowed — exit 1" "1" "$(run_in_fixture "$TMP/mr-narrow" check-manifest-regression)"

  # E8. 🟢 GREEN on ABSENCE — five of nine platform packages ship no exports key.
  # A check that read absence as narrowing would fail five repos on day one.
  mkdir -p "$TMP/mr-absent"
  # The manifest's targets must EXIST — v0.11.0 checks value, not just presence.
  # These cells are about absence-is-not-narrowing, so the file is created to
  # keep the cell testing the one thing it is for.
  ( cd "$TMP/mr-absent" && git init -q \
      && printf 'module.exports={}\n' > a.js \
      && printf '{"name":"f","version":"1.0.0","main":"./a.js"}\n' > package.json \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm i && git tag v1.0.0 \
      && printf '{"name":"f","version":"1.1.0","main":"./a.js"}\n' > package.json )
  assert_exit "manifest: absence is not narrowing — exit 0" "0" "$(run_in_fixture "$TMP/mr-absent" check-manifest-regression)"

  # E9. 🟢 GREEN on ADDING an exports map — widening is not regression.
  ( cd "$TMP/mr-absent" && printf '{"name":"f","version":"1.1.0","main":"./a.js","exports":{".":"./a.js"}}\n' > package.json )
  assert_exit "manifest: adding exports is widening — exit 0" "0" "$(run_in_fixture "$TMP/mr-absent" check-manifest-regression)"

  # ── check-explicit-apikey (F) ─────────────────────────────────────────────

  # F1. No source directory — UNVERIFIED.
  assert_exit "apikey: --root nonexistent — exit 2" "2" "$(run_in_fixture "$TMP" check-explicit-apikey --root /nonexistent-ak)"

  # F2. Zero source files scanned — UNVERIFIED. A guard that examined nothing
  # must never report green.
  mkdir -p "$TMP/ak-empty/src"
  assert_exit "apikey: scanned 0 files — exit 2" "2" "$(run_in_fixture "$TMP/ak-empty" check-explicit-apikey)"

  # F3. 🔴 RED on an implicit construction site.
  mkdir -p "$TMP/ak-implicit/src"
  cat > "$TMP/ak-implicit/src/c.ts" <<'EOF'
import { RelloClient } from "@rello-platform/api-client";
export const c = new RelloClient({ appSlug: "x" });
EOF
  assert_exit "apikey: implicit site — exit 1" "1" "$(run_in_fixture "$TMP/ak-implicit" check-explicit-apikey)"

  # F4. 🟢 GREEN on an explicit site.
  mkdir -p "$TMP/ak-explicit/src"
  cat > "$TMP/ak-explicit/src/c.ts" <<'EOF'
import { createRelloClient } from "@rello-platform/api-client";
export const c = createRelloClient({ appSlug: "x", apiKey: process.env.X_TO_RELLO_API_KEY });
EOF
  assert_exit "apikey: explicit site — exit 0" "0" "$(run_in_fixture "$TMP/ak-explicit" check-explicit-apikey)"

  # F5. 🟢 GREEN on a LOCAL class of the same name — not this package, so it
  # cannot use the fallback. Counting it inflated the platform figure.
  mkdir -p "$TMP/ak-local/src"
  cat > "$TMP/ak-local/src/c.ts" <<'EOF'
class RelloClient { constructor(k) {} }
export const c = new RelloClient();
EOF
  assert_exit "apikey: local same-named class not counted — exit 0" "0" "$(run_in_fixture "$TMP/ak-local" check-explicit-apikey)"

  printf '\nTotal: %d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
