#!/usr/bin/env bash
# check-lockfile-ssh.sh — lockfile ssh-resolved gate for git deps.
#
# Why this exists (DISCOVERED-PLATFORM-GITHUB-PIN-SSH-LOCKFILE-RAILWAY-CACHE-
# LUCK-260610): the platform pin convention `github:rello-platform/<pkg>#vX.Y.Z`
# makes npm record `"resolved": "git+ssh://git@github.com/..."` in
# package-lock.json. Local installs mask it (Kelly's machine carries a global
# ssh->https git rewrite), but Railway build containers have NO ssh key and NO
# rewrite — a live `git ls-remote ssh://git@github.com/...` during `npm ci`
# fails `Permission denied (publickey)` -> exit 128 -> deploy FAILED. Existing
# ssh entries only build via npm build-cache luck; any cache eviction, fresh
# service, or net-new git dep fails deterministically (proven fatal 2026-06-10
# by vault-crypto across Newsletter-Studio, the-drumbeat, Open-House-Hub).
#
# The durable fix is a HAND-EDIT of the lockfile's `resolved` field only
# (`git+ssh://` -> `git+https://github.com/...#<sha>`): pacote fetches verbatim
# from `resolved`. A `git+https` spec in package.json is NOT viable — npm's
# hosted-git-info re-canonicalizes it back to the `github:` shortcut + ssh
# `resolved`, and the floating-refs gate rejects the spec form anyway. And
# because `npm install` RE-STAMPS ssh on any install touching a git dep, the
# guard must live in the hook chain — this script. It runs standalone
# (`npx rello-scripts check-lockfile-ssh [--fix]`) AND is invoked by
# check-stale-pins wherever that gate already runs, so consumer repos inherit
# it with a pin bump and ZERO hook edits.
#
# Behavior:
#   - FAIL (exit 1) if package-lock.json contains any `"resolved": "git+ssh://`
#     entry; the message names each offender (lockfile package path + URL).
#   - `--fix` rewrites github.com offenders in place to
#     `git+https://github.com/<org>/<repo>.git#<sha>` (sha/ref preserved
#     verbatim), via exact-string replacement of each quoted `resolved` value —
#     npm's lockfile formatting is untouched. Non-github ssh entries are NOT
#     auto-fixable and still exit 1 (named for manual review).
#   - Both npm lockfile shapes are walked: v2/v3 `packages` (flat map) and
#     v1 nested `dependencies` (recursive).
#   - Local-only — no network, no fail-open carve-out (unlike check-stale-pins'
#     gh calls, this gate has nothing to be offline FROM).
#
# Exit codes:
#   0 — no git+ssh resolved entries (or --fix rewrote every offender)
#   1 — git+ssh resolved entries present (check mode), or unfixable non-github
#       ssh entries remain after --fix
#   2 — lockfile not found / unparseable, or --root path invalid
#
# v0.5.0 — new subcommand.
# Spec: DISCOVERED-PLATFORM-GITHUB-PIN-SSH-LOCKFILE-RAILWAY-CACHE-LUCK-260610
#       (AMENDED 2026-06-10 §3: "the durable guard must live in the hook chain").

set -uo pipefail

LOCKFILE=""
ROOT=""
FIX=0
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
    --fix)
      FIX=1
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
  LOCKFILE="${ROOT%/}/package-lock.json"
elif [ "${#POSITIONAL[@]}" -gt 0 ]; then
  LOCKFILE="${POSITIONAL[0]}"
else
  LOCKFILE="package-lock.json"
fi

if [ ! -f "$LOCKFILE" ]; then
  printf 'ERROR: %s not found\n' "$LOCKFILE" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Single Node pass: enumerate (and in fix mode, rewrite) git+ssh resolved
# entries. Emits a TAB-separated protocol on stdout:
#   FIXED\t<pkgpath>\t<old-resolved>\t<new-resolved>   (fix mode only)
#   SSH\t<pkgpath>\t<resolved>                          (remaining offenders)
# Exits 0 clean / 1 offenders remain / 2 unreadable-unparseable.
# ---------------------------------------------------------------------------
read -r -d '' NODE_SCAN <<'NODEJS' || true
"use strict";
const fs = require("fs");
const lockPath = process.argv[1];
const fix = process.argv[2] === "fix";

let raw;
try {
  raw = fs.readFileSync(lockPath, "utf8");
} catch (e) {
  process.stderr.write("ERROR: cannot read " + lockPath + ": " + e.message + "\n");
  process.exit(2);
}
let lock;
try {
  lock = JSON.parse(raw);
} catch (e) {
  process.stderr.write("ERROR: malformed JSON in " + lockPath + ": " + e.message + "\n");
  process.exit(2);
}
if (!lock || typeof lock !== "object" || Array.isArray(lock)) {
  process.stderr.write("ERROR: " + lockPath + " is not a JSON object\n");
  process.exit(2);
}

// Walk both lockfile shapes; collect { path, resolved } for every git+ssh entry.
function collect(doc) {
  const found = [];
  // v2/v3: flat `packages` map ("" = root, "node_modules/<name>" = dep).
  if (doc.packages && typeof doc.packages === "object" && !Array.isArray(doc.packages)) {
    for (const key of Object.keys(doc.packages)) {
      const entry = doc.packages[key];
      if (entry && typeof entry.resolved === "string" && entry.resolved.startsWith("git+ssh://")) {
        found.push({ path: key || "(root)", resolved: entry.resolved });
      }
    }
  }
  // v1: nested `dependencies` tree (also present alongside v2 for back-compat).
  function walkDeps(deps, prefix) {
    if (!deps || typeof deps !== "object" || Array.isArray(deps)) return;
    for (const name of Object.keys(deps)) {
      const entry = deps[name];
      if (!entry || typeof entry !== "object") continue;
      const p = prefix ? prefix + " > " + name : name;
      if (typeof entry.resolved === "string" && entry.resolved.startsWith("git+ssh://")) {
        found.push({ path: p, resolved: entry.resolved });
      }
      walkDeps(entry.dependencies, p);
    }
  }
  walkDeps(doc.dependencies, "");
  return found;
}

const offenders = collect(lock);
if (offenders.length === 0) process.exit(0);

// github.com ssh URL -> https rewrite, sha/ref fragment preserved verbatim.
// Handles both slash and scp-colon host separators.
const GH_RE = /^git\+ssh:\/\/git@github\.com[:/]/;
function httpsFor(resolved) {
  return GH_RE.test(resolved)
    ? resolved.replace(GH_RE, "git+https://github.com/")
    : null;
}

if (!fix) {
  for (const o of offenders) {
    process.stdout.write("SSH\t" + o.path + "\t" + o.resolved + "\n");
  }
  process.exit(1);
}

// Fix mode: exact-string replace each quoted resolved value in the RAW text —
// preserves npm's lockfile formatting byte-for-byte outside the URL itself.
// Identical URLs across entries (v1 tree + v2 packages mirror the same dep)
// are all rewritten by the same split/join.
let next = raw;
const fixedUrls = new Map(); // old -> new (dedup identical URLs)
const unfixable = [];
for (const o of offenders) {
  const target = httpsFor(o.resolved);
  if (target === null) {
    unfixable.push(o);
    continue;
  }
  fixedUrls.set(o.resolved, target);
}
for (const [oldUrl, newUrl] of fixedUrls) {
  next = next.split(JSON.stringify(oldUrl)).join(JSON.stringify(newUrl));
}
if (next !== raw) {
  // Verify the rewrite parses before touching disk; never write a broken lockfile.
  try {
    JSON.parse(next);
  } catch (e) {
    process.stderr.write("ERROR: internal: rewrite produced invalid JSON; lockfile NOT modified: " + e.message + "\n");
    process.exit(2);
  }
  fs.writeFileSync(lockPath, next);
}
// Report per-entry from the original offender list (path-accurate).
for (const o of offenders) {
  const target = fixedUrls.get(o.resolved);
  if (target) {
    process.stdout.write("FIXED\t" + o.path + "\t" + o.resolved + "\t" + target + "\n");
  }
}
// Re-scan from disk: anything still ssh (non-github) keeps the gate red.
const remaining = collect(JSON.parse(fs.readFileSync(lockPath, "utf8")));
for (const o of remaining) {
  process.stdout.write("SSH\t" + o.path + "\t" + o.resolved + "\n");
}
process.exit(remaining.length === 0 ? 0 : 1);
NODEJS

MODE="check"
if [ "$FIX" -eq 1 ]; then
  MODE="fix"
fi

set +e
scan="$(node -e "$NODE_SCAN" "$LOCKFILE" "$MODE")"
scan_status=$?
set -e
if [ "$scan_status" -eq 2 ]; then
  # The Node pass has already printed a specific error to stderr.
  exit 2
fi

# Format the protocol lines into the human report.
fixed_count=0
ssh_lines=""
while IFS=$'\t' read -r tag pkgpath oldval newval; do
  [ -z "$tag" ] && continue
  case "$tag" in
    FIXED)
      if [ "$fixed_count" -eq 0 ]; then
        printf 'check-lockfile-ssh — %s (--fix)\n' "$LOCKFILE"
      fi
      printf '  FIXED %s\n        %s\n     -> %s\n' "$pkgpath" "$oldval" "$newval"
      fixed_count=$((fixed_count + 1))
      ;;
    SSH)
      ssh_lines="${ssh_lines}  ${pkgpath}\n        resolved: ${oldval}\n"
      ;;
  esac
done <<< "$scan"

if [ "$scan_status" -eq 0 ]; then
  if [ "$fixed_count" -gt 0 ]; then
    printf 'OK: rewrote %d git+ssh resolved entr%s to git+https in %s.\n' \
      "$fixed_count" "$([ "$fixed_count" -eq 1 ] && echo y || echo ies)" "$LOCKFILE"
    printf 'Commit the lockfile change. NOTE: any future `npm install` touching a git dep\n'
    printf 're-stamps git+ssh — this gate re-fails and `--fix` re-heals (self-healing loop).\n'
  else
    printf 'OK: no git+ssh resolved entries in %s.\n' "$LOCKFILE"
  fi
  exit 0
fi

printf 'ERROR: git+ssh resolved entries in %s — Railway build containers have no ssh\n' "$LOCKFILE" >&2
printf 'key, so `npm ci` fails `Permission denied (publickey)` on any cache miss:\n' >&2
printf "$ssh_lines" >&2
if [ "$FIX" -eq 1 ]; then
  printf '\nThe entries above are NOT github.com URLs, so --fix cannot rewrite them.\n' >&2
  printf 'Convert each to a fetchable git+https URL manually (sha fragment preserved).\n' >&2
else
  printf '\nFix: npx rello-scripts check-lockfile-ssh --fix   (rewrites github.com entries\n' >&2
  printf 'to git+https://github.com/<org>/<repo>.git#<sha>, sha preserved), then commit\n' >&2
  printf 'the lockfile. Keep the github: shortcut in package.json — only the lockfile\n' >&2
  printf 'resolved field flips. Spec: DISCOVERED-PLATFORM-GITHUB-PIN-SSH-LOCKFILE-\n' >&2
  printf 'RAILWAY-CACHE-LUCK-260610 (AMENDED).\n' >&2
fi
exit 1
