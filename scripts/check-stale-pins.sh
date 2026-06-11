#!/usr/bin/env bash
# check-stale-pins.sh — version-staleness gate for @rello-platform/* deps.
#
# Phase 4 of PLATFORM-PACKAGE-PIN-CONVENTION-AND-VERSION-SYNC. Where
# `floating-refs` (Phase 0) prevents pin-FORM drift, this prevents pin-VERSION
# staleness — so no spoke silently falls many minors behind canonical-latest
# again (the "OHH was 38 minors behind permissions" failure class).
#
# Runs as a husky pre-push hook (`npx rello-scripts check-stale-pins`), NOT a
# GitHub Action (the GH-Actions retirement migrated every gate to husky).
#
# For each @rello-platform/* dep in the consumer's package.json:
#   - Canonical-latest is the newest git TAG of the dep's repo, fetched via
#         gh api repos/rello-platform/<repo>/tags --jq '.[].name'
#     and `sort -V`-ed. NOT `gh release list` — releases lag tags (e.g.
#     permissions latest release v0.35.0 vs latest tag v0.41.0). See
#     reference-rello-platform-pkgs-publish-via-git-tags-not-github-releases.
#   - The repo name is read from the PIN VALUE (`github:rello-platform/<repo>#`),
#     not the package key — because @rello-platform/ui lives in repo `rello-ui`.
#
# Classification (per spec §4 + Build-KA Phase 4 lock):
#   OK    — current (0 minors behind), or ahead of latest tag
#   WARN  — exactly 1 minor behind  (surfaced, does NOT block)
#   FAIL  — >= 2 minors behind, OR a full major behind  (exit 1, blocks push)
# Exit status: 1 if any dep is FAIL (and not allowlisted); else 0.
# Prerelease tags (v1.2.3-rc.1) are ignored for staleness counting.
#
# SHA-pinned deps: a SHA carries no semver. Resolve via
#       gh api repos/rello-platform/<repo>/compare/<base>...<sha>  ->  .status
#   - ahead / identical to latest tag        -> OK
#   - diverged from latest tag               -> WARN + note (manual review)
#   - behind latest tag, but ahead-of/at the second-newest minor tag -> WARN (1 behind)
#   - behind the second-newest minor tag too -> FAIL (>= 2 minors behind)
#   (Bounded to <=3 compare calls; mirrors the FIX-2/Phase-2 ahead/behind logic.)
#
# Exception allowlist — three intentional held pins MUST classify OK
# (DISCOVERED-PINCONV-PHASE2-INTENTIONAL-PIN-EXCEPTIONS-260524): Rello
# api-client (v2.19.0 commit, ahead of latest tag), Rello eslint-config
# (diverged SHA), Milo api-client@v1.9.0 (CJS-held, a major behind). Two
# JSON-legal mechanisms (a `//` comment in package.json is NOT viable — it
# breaks `npm install`'s strict JSON parse):
#   (a) scripts/stale-pin-exceptions.json — `{ "@rello-platform/<pkg>": "reason", ... }`
#   (b) a `relloStalePinExceptions` object field inside package.json itself
#       (the JSON-legal "inline annotation next to the dep")
# A dep present in either is reported `OK (allowlisted: <reason>)` and never FAILs.
#
# Skips: workspace refs ("*" / "workspace:*") and non-@rello-platform deps.
# Non-canonical pins (caret/registry/git+https with no resolvable repo) are
# reported WARN (form is the floating-refs gate's job, not this one).
#
# Fail-open offline: if gh/network is unreachable or rate-limited, a dep is
# reported `UNKNOWN (network)` (WARN-class) and never FAILs — a pre-push hook
# must not block a developer who is offline. Uses GH_TOKEN/GITHUB_TOKEN (gh
# reads them automatically) for an authenticated rate budget.
#
# Test hooks (internal; unset in real use):
#   RELLO_STALE_PINS_MOCK_DIR=<dir>      read tags/compare from fixtures, no network
#   RELLO_STALE_PINS_SIMULATE_OFFLINE=1  force the gh wrapper to fail (offline path)
#
# v0.4.0 — new subcommand.
# v0.5.0 — also runs the sibling check-lockfile-ssh gate against the adjacent
#          package-lock.json (when present), so every repo wiring
#          check-stale-pins inherits the ssh-lockfile guard with a pin bump
#          and zero hook edits. That gate is local-only (no network) and is
#          NOT fail-open. See DISCOVERED-PLATFORM-GITHUB-PIN-SSH-LOCKFILE-
#          RAILWAY-CACHE-LUCK-260610 (AMENDED).
# Spec: PLATFORM-PACKAGE-PIN-CONVENTION-AND-VERSION-SYNC.md Phase 4.

set -uo pipefail

PKG=""
ROOT=""
POSITIONAL=()

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
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ -n "$ROOT" ]; then
  if [ ! -d "$ROOT" ]; then
    printf 'ERROR: --root path does not exist or is not a directory: %s\n' "$ROOT" >&2
    exit 2
  fi
  PKG="${ROOT%/}/package.json"
elif [ "${#POSITIONAL[@]}" -gt 0 ]; then
  PKG="${POSITIONAL[0]}"
else
  PKG="package.json"
fi

if [ ! -f "$PKG" ]; then
  printf 'ERROR: %s not found\n' "$PKG" >&2
  exit 2
fi

PKG_DIR="$(cd "$(dirname "$PKG")" && pwd)"
EXC_FILE="$PKG_DIR/scripts/stale-pin-exceptions.json"

# ---------------------------------------------------------------------------
# 1. Parse package.json -> one `key<TAB>value` line per @rello-platform/* dep.
#    Also collect allowlisted keys (from the inline package.json field AND the
#    sidecar scripts/stale-pin-exceptions.json) into a `KEY<TAB>reason` stream
#    prefixed with a sentinel so a single Node pass emits both.
# ---------------------------------------------------------------------------
read -r -d '' NODE_PARSER <<'NODEJS' || true
"use strict";
const fs = require("fs");
const pkgPath = process.argv[1];
const excPath = process.argv[2];

let pkg;
try {
  pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
} catch (e) {
  process.stderr.write("ERROR: cannot parse " + pkgPath + ": " + e.message + "\n");
  process.exit(2);
}
if (!pkg || typeof pkg !== "object" || Array.isArray(pkg)) {
  process.stderr.write("ERROR: " + pkgPath + " is not a JSON object\n");
  process.exit(2);
}

// Allowlist: inline package.json field + sidecar file. Sidecar wins on conflict.
const allow = {};
const inline = pkg.relloStalePinExceptions;
if (inline && typeof inline === "object" && !Array.isArray(inline)) {
  for (const k of Object.keys(inline)) allow[k] = String(inline[k]);
}
try {
  const side = JSON.parse(fs.readFileSync(excPath, "utf8"));
  if (side && typeof side === "object" && !Array.isArray(side)) {
    // Accept either { "@rello-platform/x": "reason" } or
    // { "exceptions": { ... } } / { "exceptions": [ {package, reason} ] }.
    let map = side;
    if (side.exceptions) map = side.exceptions;
    if (Array.isArray(map)) {
      for (const e of map) {
        if (e && e.package) allow[String(e.package)] = String(e.reason || "");
      }
    } else if (map && typeof map === "object") {
      for (const k of Object.keys(map)) allow[k] = String(map[k]);
    }
  }
} catch (e) {
  // No sidecar (or unreadable) -> inline-only. Not an error.
}
for (const k of Object.keys(allow)) {
  process.stdout.write("ALLOW\t" + k + "\t" + allow[k].replace(/\t|\n/g, " ") + "\n");
}

const SECTIONS = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];
for (const section of SECTIONS) {
  const deps = pkg[section];
  if (!deps || typeof deps !== "object" || Array.isArray(deps)) continue;
  for (const key of Object.keys(deps)) {
    if (!/^@rello-platform\//.test(key)) continue;
    process.stdout.write("DEP\t" + key + "\t" + String(deps[key]) + "\n");
  }
}
NODEJS

parsed="$(node -e "$NODE_PARSER" "$PKG" "$EXC_FILE")"
if [ "$?" -ne 0 ]; then
  exit 2
fi

# Build the allowlist as a newline-delimited "key<TAB>reason" string. (bash 3.2
# on macOS has no associative arrays — `declare -A` is bash-4+, so we look up
# via awk against this string instead.)
ALLOWLIST_DATA="$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="ALLOW"{print $2"\t"$3}')"

# allowlist_reason <key> — prints the reason and returns 0 if allowlisted, else 1.
allowlist_reason() {
  printf '%s\n' "$ALLOWLIST_DATA" \
    | awk -F'\t' -v k="$1" '$1==k {print $2; f=1} END{exit f?0:1}'
}

# ---------------------------------------------------------------------------
# 2. GitHub access wrappers (mockable + fail-open).
#    latest_tag_for <repo>            -> echoes newest non-prerelease tag, or ""
#    compare_status  <repo> <b> <h>   -> echoes "ahead"|"behind"|"identical"|"diverged", or ""
#    A blank result signals an offline/unknown condition to the caller.
# ---------------------------------------------------------------------------
gh_offline() {
  [ "${RELLO_STALE_PINS_SIMULATE_OFFLINE:-}" = "1" ]
}

latest_tag_for() {
  local repo="$1" tags=""
  if [ -n "${RELLO_STALE_PINS_MOCK_DIR:-}" ]; then
    if gh_offline; then echo ""; return 0; fi
    [ -f "$RELLO_STALE_PINS_MOCK_DIR/$repo.tags" ] || { echo ""; return 0; }
    tags="$(cat "$RELLO_STALE_PINS_MOCK_DIR/$repo.tags")"
  else
    if gh_offline; then echo ""; return 0; fi
    tags="$(gh api "repos/rello-platform/$repo/tags" --paginate --jq '.[].name' 2>/dev/null)" || { echo ""; return 0; }
  fi
  # Newest non-prerelease vX.Y.Z tag.
  printf '%s\n' "$tags" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -1
}

# All non-prerelease tags, sorted ascending (used for minor-counting).
all_tags_for() {
  local repo="$1" tags=""
  if [ -n "${RELLO_STALE_PINS_MOCK_DIR:-}" ]; then
    if gh_offline; then echo ""; return 0; fi
    [ -f "$RELLO_STALE_PINS_MOCK_DIR/$repo.tags" ] || { echo ""; return 0; }
    tags="$(cat "$RELLO_STALE_PINS_MOCK_DIR/$repo.tags")"
  else
    if gh_offline; then echo ""; return 0; fi
    tags="$(gh api "repos/rello-platform/$repo/tags" --paginate --jq '.[].name' 2>/dev/null)" || { echo ""; return 0; }
  fi
  printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}

compare_status() {
  local repo="$1" base="$2" head="$3"
  if [ -n "${RELLO_STALE_PINS_MOCK_DIR:-}" ]; then
    if gh_offline; then echo ""; return 0; fi
    local f="$RELLO_STALE_PINS_MOCK_DIR/$repo.compare.$base...$head"
    [ -f "$f" ] || { echo ""; return 0; }
    cat "$f"
  else
    if gh_offline; then echo ""; return 0; fi
    gh api "repos/rello-platform/$repo/compare/$base...$head" --jq '.status' 2>/dev/null || echo ""
  fi
}

# ---------------------------------------------------------------------------
# 3. Tag classifier (semver). Given the pinned x.y.z and the newline tag list,
#    prints "OK|WARN|FAIL<TAB>message".
# ---------------------------------------------------------------------------
read -r -d '' NODE_CLASSIFY_TAG <<'NODEJS' || true
"use strict";
const pinned = process.argv[1];          // e.g. "0.38.0"
const latest = process.argv[2];          // e.g. "v0.41.0" (already newest)
const tagsRaw = process.argv[3] || "";   // newline-separated vX.Y.Z list (asc)

function parse(v) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(v.trim());
  if (!m) return null;
  return { maj: +m[1], min: +m[2], pat: +m[3] };
}
const p = parse(pinned);
const l = parse(latest);
if (!p || !l) {
  process.stdout.write("WARN\tcould not parse pinned/latest semver (pinned=" + pinned + " latest=" + latest + ")");
  process.exit(0);
}

// Ahead of (or equal to) latest tag -> OK.
const cmp = (a, b) =>
  a.maj !== b.maj ? a.maj - b.maj :
  a.min !== b.min ? a.min - b.min :
  a.pat - b.pat;

if (cmp(p, l) >= 0) {
  process.stdout.write("OK\tcurrent (pinned v" + pinned + " >= latest tag " + latest + ")");
  process.exit(0);
}

// A full major behind is always FAIL.
if (p.maj < l.maj) {
  process.stdout.write("FAIL\t" + (l.maj - p.maj) + " major(s) behind (pinned v" + pinned + ", latest " + latest + ")");
  process.exit(0);
}

// Same major: count distinct tagged minors strictly above the pinned minor.
const minors = new Set();
for (const t of tagsRaw.split("\n")) {
  const pt = parse(t);
  if (!pt) continue;
  if (pt.maj === l.maj && pt.min > p.min) minors.add(pt.min);
}
const behind = minors.size;
if (behind === 0) {
  // Same minor as latest (only patch differences) -> treat as current.
  process.stdout.write("OK\tcurrent minor (pinned v" + pinned + ", latest " + latest + ")");
} else if (behind === 1) {
  process.stdout.write("WARN\t1 minor behind (pinned v" + pinned + ", latest " + latest + ")");
} else {
  process.stdout.write("FAIL\t" + behind + " minors behind (pinned v" + pinned + ", latest " + latest + ")");
}
NODEJS

classify_tag() {
  # args: pinnedVer latestTag allTags(newline)
  node -e "$NODE_CLASSIFY_TAG" "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# 4. Walk each dep, classify, aggregate.
# ---------------------------------------------------------------------------
HAS_FAIL=0
declare -a REPORT=()

# Extract repo + ref from a canonical-ish pin value.
#   github:rello-platform/<repo>#<ref>
#   git+https://github.com/rello-platform/<repo>.git#<ref>
# Echoes "<repo>\t<ref>" or empty if not a rello-platform git pin.
parse_pin() {
  local val="$1" repo="" ref=""
  if [[ "$val" =~ rello-platform/([A-Za-z0-9._-]+)(\.git)?#(.+)$ ]]; then
    repo="${BASH_REMATCH[1]}"
    ref="${BASH_REMATCH[3]}"
    printf '%s\t%s' "$repo" "$ref"
  fi
}

while IFS=$'\t' read -r tag key val; do
  [ "$tag" = "DEP" ] || continue
  [ -z "$key" ] && continue

  # Allowlisted -> OK, no network.
  if reason="$(allowlist_reason "$key")"; then
    REPORT+=("OK    $key  -> allowlisted: $reason")
    continue
  fi

  # Skip workspace / wildcard refs (the floating-refs gate validates those).
  if [ "$val" = "*" ] || [[ "$val" == workspace:* ]]; then
    REPORT+=("SKIP  $key  -> workspace/wildcard ref")
    continue
  fi

  pin="$(parse_pin "$val")"
  if [ -z "$pin" ]; then
    REPORT+=("WARN  $key  -> non-canonical pin form \"$val\" (floating-refs gate covers this)")
    continue
  fi
  repo="${pin%%$'\t'*}"
  ref="${pin#*$'\t'}"

  latest="$(latest_tag_for "$repo")"
  if [ -z "$latest" ]; then
    REPORT+=("WARN  $key  -> UNKNOWN (network/no tags for repo $repo) — not blocking")
    continue
  fi

  if [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]]; then
    # Tag pin. Strip any prerelease suffix for the comparison base version.
    pinnedver="${ref#v}"
    pinnedver="${pinnedver%%-*}"
    alltags="$(all_tags_for "$repo")"
    res="$(classify_tag "$pinnedver" "$latest" "$alltags")"
    status="${res%%$'\t'*}"
    msg="${res#*$'\t'}"
    case "$status" in
      OK)   REPORT+=("OK    $key  -> $msg");;
      WARN) REPORT+=("WARN  $key  -> $msg");;
      FAIL) REPORT+=("FAIL  $key  -> $msg"); HAS_FAIL=1;;
      *)    REPORT+=("WARN  $key  -> $msg");;
    esac

  elif [[ "$ref" =~ ^[a-f0-9]{40}$ ]]; then
    # SHA pin. Compare latest-tag...sha.
    st="$(compare_status "$repo" "$latest" "$ref")"
    if [ -z "$st" ]; then
      REPORT+=("WARN  $key  -> UNKNOWN (network; SHA $ref) — not blocking")
      continue
    fi
    case "$st" in
      ahead|identical)
        REPORT+=("OK    $key  -> SHA at/ahead of latest tag $latest ($st)")
        ;;
      diverged)
        REPORT+=("WARN  $key  -> SHA diverged from latest tag $latest (manual review)")
        ;;
      behind)
        # Behind latest. Is it also behind the second-newest MINOR tag?
        # second-newest minor = newest tag whose minor < latest's minor (same major).
        # Compute prev-minor tag (newest tag whose minor < latest's minor) in Node.
        prevtag="$(node -e '
          const tags=(process.argv[1]||"").split("\n").map(s=>s.trim()).filter(Boolean);
          const latest=process.argv[2];
          const p=v=>{const m=/^v(\d+)\.(\d+)\.(\d+)$/.exec(v);return m?{maj:+m[1],min:+m[2],pat:+m[3],raw:v}:null;};
          const L=p(latest); if(!L){process.exit(0);}
          let best=null;
          for(const t of tags){const q=p(t);if(!q)continue;if(q.maj===L.maj&&q.min<L.min){if(!best||q.min>best.min||(q.min===best.min&&q.pat>best.pat))best=q;}}
          if(best)process.stdout.write(best.raw);
        ' "$(all_tags_for "$repo")" "$latest")"
        if [ -z "$prevtag" ]; then
          # No lower minor exists -> sha is only patch-behind latest minor.
          REPORT+=("OK    $key  -> SHA behind latest tag $latest by patches only (no lower minor)")
        else
          st2="$(compare_status "$repo" "$prevtag" "$ref")"
          if [ -z "$st2" ]; then
            REPORT+=("WARN  $key  -> UNKNOWN (network; SHA vs $prevtag) — not blocking")
          elif [ "$st2" = "ahead" ] || [ "$st2" = "identical" ]; then
            REPORT+=("WARN  $key  -> SHA ~1 minor behind (>= $prevtag, < latest $latest)")
          else
            REPORT+=("FAIL  $key  -> SHA >= 2 minors behind (< $prevtag; latest $latest)"); HAS_FAIL=1
          fi
        fi
        ;;
      *)
        REPORT+=("WARN  $key  -> compare returned '$st' (manual review)")
        ;;
    esac
  else
    REPORT+=("WARN  $key  -> ref '$ref' is neither a vX.Y.Z tag nor a 40-hex SHA (floating-refs gate covers this)")
  fi
done <<< "$parsed"

# ---------------------------------------------------------------------------
# 5. Sibling gate: lockfile git+ssh resolved entries (v0.5.0).
#    Riding here means every repo already running check-stale-pins inherits
#    the ssh-lockfile guard with a pin bump and ZERO hook edits. Runs even
#    when there are no @rello-platform/* deps (any git dep can carry a
#    git+ssh resolved entry), and is NOT subject to the fail-open-offline
#    carve-out — it is local-only (no network).
#    Spec: DISCOVERED-PLATFORM-GITHUB-PIN-SSH-LOCKFILE-RAILWAY-CACHE-LUCK-
#    260610 (AMENDED §3: the guard must live in the hook chain because
#    `npm install` re-stamps git+ssh).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKFILE="$PKG_DIR/package-lock.json"
PIN_FAIL="$HAS_FAIL"
LOCK_SSH_FAIL=0
LOCK_SSH_OUTPUT=""
if [ -f "$LOCKFILE" ]; then
  set +e
  LOCK_SSH_OUTPUT="$(bash "$SCRIPT_DIR/check-lockfile-ssh.sh" "$LOCKFILE" 2>&1)"
  lock_status=$?
  set -e
  if [ "$lock_status" -ne 0 ]; then
    # exit 1 (offenders) and exit 2 (unparseable lockfile) both block — a
    # lockfile npm can't parse can't deploy either.
    LOCK_SSH_FAIL=1
    HAS_FAIL=1
  fi
fi

# ---------------------------------------------------------------------------
# 6. Print report + exit.
# ---------------------------------------------------------------------------
if [ "${#REPORT[@]}" -eq 0 ]; then
  printf 'OK: no @rello-platform/* deps in %s.\n' "$PKG"
else
  printf 'check-stale-pins — %s\n' "$PKG"
  for line in "${REPORT[@]}"; do
    printf '  %s\n' "$line"
  done
fi

if [ -n "$LOCK_SSH_OUTPUT" ]; then
  if [ "$LOCK_SSH_FAIL" -eq 1 ]; then
    printf '\n%s\n' "$LOCK_SSH_OUTPUT" >&2
  else
    printf '  %s\n' "$LOCK_SSH_OUTPUT"
  fi
fi

if [ "$HAS_FAIL" -eq 1 ]; then
  if [ "$PIN_FAIL" -eq 1 ]; then
    printf '\nFAIL: one or more @rello-platform/* pins are >= 2 minors behind canonical-latest.\n' >&2
    printf 'Bump the FAIL deps to the latest tag (github:rello-platform/<repo>#v<X.Y.Z>),\n' >&2
    printf 'or add an intentional-hold exception (scripts/stale-pin-exceptions.json or the\n' >&2
    printf 'relloStalePinExceptions field in package.json) with a documented reason.\n' >&2
  fi
  if [ "$LOCK_SSH_FAIL" -eq 1 ]; then
    printf '\nFAIL: package-lock.json carries git+ssh resolved entries (Railway-unfetchable).\n' >&2
    printf 'Run `npx rello-scripts check-lockfile-ssh --fix` and commit the lockfile.\n' >&2
  fi
  exit 1
fi

printf '\nOK: all @rello-platform/* pins within 1 minor of canonical-latest (WARN/UNKNOWN do not block); no git+ssh lockfile entries.\n'
exit 0
