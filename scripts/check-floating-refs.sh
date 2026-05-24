#!/usr/bin/env bash
# Phase 0 durability gate — rejects floating or non-canonical
# @rello-platform/* refs in package.json.
#
# v0.3.1 — structural parse (was prefix-only grep). The pre-v0.3.1 extractor
# only inspected values starting with `"github:rello-platform/`, so any other
# shape (git+https://, npm-caret ^X.Y.Z, wildcard "*", npm:, file:, link:) was
# invisible to the gate. This version parses dependencies / devDependencies /
# optionalDependencies / peerDependencies structurally via Node and validates
# EVERY @rello-platform/* value against the canonical regex.
#
# Accepts:
#   - github:rello-platform/<pkg>#v<X.Y.Z>[<-prerelease>]   (semver tag)
#   - github:rello-platform/<pkg>#<40-char-hex-sha>         (full commit SHA)
#   - "*" / "workspace:*" / "workspace:^" / etc.            (npm workspace ref)
#         ONLY when a local workspace member package with that exact `name`
#         exists (workspaces globs in this package.json, expanded + read).
#         A wildcard/workspace value with NO matching member is a VIOLATION
#         (stray wildcard). See DISCOVERED-PINCONV-ASSET-WHITELIST-IS-WORKSPACE-
#         PKG-NOT-VIOLATION-260524 (Rello's @rello-platform/asset-whitelist).
#
# Rejects (non-canonical — must convert to a tag or full SHA):
#   - github:rello-platform/<pkg>                  (bare ref, no #)
#   - github:rello-platform/<pkg>#main             (branch ref)
#   - github:rello-platform/<pkg>#<branch-name>    (any non-tag-non-sha ref)
#   - github:rello-platform/<pkg>#<short-sha>      (under 40 hex chars)
#   - git+https://github.com/rello-platform/<pkg>.git#...  (git+https form)
#   - git+ssh://... / https://...                  (other git url forms)
#   - ^X.Y.Z / ~X.Y.Z / X.Y.Z                       (npm-range / exact registry)
#   - npm:@scope/x@1                               (npm alias)
#   - file:../x / link:../x                        (filesystem links — not workspace)
#   - "*" / "workspace:*" with NO matching local workspace member
#
# v0.2.0 — accepts optional `--root <dir>` flag (resolves to <dir>/package.json).
# Backward-compatible: existing positional package.json arg still works.
#
# Spec: PERMISSIONS-CANONICALIZATION.md Phase 0 (Decision B-02) +
#       PLATFORM-PACKAGE-PIN-CONVENTION-AND-VERSION-SYNC.md Phase 0; Locks #1 + #4.

set -euo pipefail

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

# Structural parser. Node is guaranteed present (the bin shim that dispatches
# this script is Node). Emits one TAB-separated `key<TAB>value<TAB>isWorkspace`
# line per @rello-platform/* dependency across all four dependency sections.
# `isWorkspace` is 1 iff a local npm-workspace member package with that exact
# `name` exists in this manifest's workspaces globs. Exits 2 (and prints a
# clear error) on a missing/malformed package.json — never silently passes.
read -r -d '' NODE_PARSER <<'NODEJS' || true
"use strict";
const fs = require("fs");
const path = require("path");

const pkgPath = process.argv[1];
let raw;
try {
  raw = fs.readFileSync(pkgPath, "utf8");
} catch (e) {
  process.stderr.write("ERROR: cannot read " + pkgPath + ": " + e.message + "\n");
  process.exit(2);
}
let pkg;
try {
  pkg = JSON.parse(raw);
} catch (e) {
  process.stderr.write("ERROR: malformed JSON in " + pkgPath + ": " + e.message + "\n");
  process.exit(2);
}
if (!pkg || typeof pkg !== "object" || Array.isArray(pkg)) {
  process.stderr.write("ERROR: " + pkgPath + " is not a JSON object\n");
  process.exit(2);
}

const root = path.dirname(path.resolve(pkgPath));

// Build the set of local workspace member package names.
const wsNames = new Set();
let globs = [];
if (Array.isArray(pkg.workspaces)) {
  globs = pkg.workspaces;
} else if (pkg.workspaces && Array.isArray(pkg.workspaces.packages)) {
  globs = pkg.workspaces.packages;
}
for (const g of globs) {
  if (typeof g !== "string") continue;
  const memberDirs = [];
  if (g.endsWith("/*")) {
    const base = path.join(root, g.slice(0, -2));
    let entries = [];
    try {
      entries = fs.readdirSync(base, { withFileTypes: true });
    } catch (e) {
      entries = []; // glob base absent — no members from this glob
    }
    for (const ent of entries) {
      if (ent.isDirectory()) memberDirs.push(path.join(base, ent.name));
    }
  } else {
    memberDirs.push(path.join(root, g)); // exact path glob
  }
  for (const dir of memberDirs) {
    try {
      const mp = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
      if (mp && typeof mp.name === "string") wsNames.add(mp.name);
    } catch (e) {
      // Expected control flow: dir has no readable package.json -> not a member.
    }
  }
}

const SECTIONS = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];
for (const section of SECTIONS) {
  const deps = pkg[section];
  if (!deps || typeof deps !== "object" || Array.isArray(deps)) continue;
  for (const key of Object.keys(deps)) {
    if (!/^@rello-platform\//.test(key)) continue;
    const val = deps[key];
    const isWs = wsNames.has(key) ? "1" : "0";
    process.stdout.write(key + "\t" + String(val) + "\t" + isWs + "\n");
  }
}
NODEJS

# Canonical accepted pin form (semver tag OR full 40-hex SHA).
CANON_RE='^github:rello-platform/[a-z][a-z-]*#(v[0-9]+\.[0-9]+\.[0-9]+([-.][a-z0-9.-]+)?|[a-f0-9]{40})$'

# Run the parser, capturing stdout; let its stderr surface. Exit 2 on parse failure.
set +e
parsed="$(node -e "$NODE_PARSER" "$PKG")"
node_status=$?
set -e
if [ "$node_status" -ne 0 ]; then
  # The parser has already printed a specific error to stderr.
  exit 2
fi

violations=()
while IFS=$'\t' read -r key val isws; do
  [ -z "$key" ] && continue
  pkgname="${key#@rello-platform/}"
  if [[ "$val" =~ $CANON_RE ]]; then
    : # accept: canonical semver tag or full SHA
  elif [[ "$val" == "*" || "$val" == workspace:* ]]; then
    if [ "$isws" = "1" ]; then
      : # accept: legitimate local npm-workspace reference (member exists)
    else
      violations+=("$key: \"$val\"  -- wildcard/workspace ref but NO local workspace member named $key (use github:rello-platform/$pkgname#v<X.Y.Z> or #<40-char-sha>)")
    fi
  else
    violations+=("$key: \"$val\"  -- non-canonical ref (use github:rello-platform/$pkgname#v<X.Y.Z> or #<40-char-sha>)")
  fi
done <<< "$parsed"

if [ "${#violations[@]}" -gt 0 ]; then
  printf 'ERROR: floating or non-canonical @rello-platform/* refs in %s:\n' "$PKG" >&2
  printf '  %s\n' "${violations[@]}" >&2
  printf '\nEach @rello-platform/* ref MUST be either:\n' >&2
  printf '  - github:rello-platform/<pkg>#v<X.Y.Z>      (semver tag)\n' >&2
  printf '  - github:rello-platform/<pkg>#<40-char-sha> (full commit SHA)\n' >&2
  printf '  - "*"/"workspace:*"                          (ONLY for a local workspace member)\n' >&2
  printf '\nSpec: PERMISSIONS-CANONICALIZATION.md Phase 0; PLATFORM-PACKAGE-PIN-CONVENTION-AND-VERSION-SYNC.md.\n' >&2
  exit 1
fi

printf 'OK: all @rello-platform/* refs in %s are pinned (tag, full SHA, or local workspace member).\n' "$PKG"
