#!/usr/bin/env bash
# Phase 0 durability gate — rejects floating or non-canonical
# @rello-platform/* refs in package.json.
#
# Accepts:
#   - github:rello-platform/<pkg>#v<X.Y.Z>[<-prerelease>]   (semver tag)
#   - github:rello-platform/<pkg>#<40-char-hex-sha>         (full commit SHA)
#
# Rejects:
#   - github:rello-platform/<pkg>                  (bare ref, no #)
#   - github:rello-platform/<pkg>#main             (branch ref)
#   - github:rello-platform/<pkg>#<branch-name>    (any non-tag-non-sha ref)
#   - github:rello-platform/<pkg>#<short-sha>      (under 40 hex chars)
#
# Spec: PERMISSIONS-CANONICALIZATION.md Phase 0; Locks #1 + #4.

set -euo pipefail

PKG="${1:-package.json}"
if [ ! -f "$PKG" ]; then
  printf 'ERROR: %s not found\n' "$PKG" >&2
  exit 2
fi

violations=()
while IFS= read -r line; do
  ref="$(printf '%s\n' "$line" | sed -nE 's/.*"(github:rello-platform\/[^"]*)".*/\1/p')"
  [ -z "$ref" ] && continue

  if [[ "$ref" =~ ^github:rello-platform/[a-z][a-z-]*$ ]]; then
    violations+=("$line  -- bare ref (no #)")
  elif [[ "$ref" =~ ^github:rello-platform/[a-z][a-z-]*#v[0-9]+\.[0-9]+\.[0-9]+([-.][a-z0-9.-]+)?$ ]]; then
    : # accept: semver tag
  elif [[ "$ref" =~ ^github:rello-platform/[a-z][a-z-]*#[a-f0-9]{40}$ ]]; then
    : # accept: full 40-char hex SHA
  else
    violations+=("$line  -- non-canonical ref (must be #v<X.Y.Z> tag or #<40-char-sha>)")
  fi
done < <(grep -nE '"github:rello-platform/' "$PKG" || true)

if [ "${#violations[@]}" -gt 0 ]; then
  printf 'ERROR: floating or non-canonical @rello-platform/* refs in %s:\n' "$PKG" >&2
  printf '  %s\n' "${violations[@]}" >&2
  printf '\nEach ref MUST be either:\n' >&2
  printf '  - github:rello-platform/<pkg>#v<X.Y.Z>      (semver tag)\n' >&2
  printf '  - github:rello-platform/<pkg>#<40-char-sha> (full commit SHA)\n' >&2
  printf '\nSpec: PERMISSIONS-CANONICALIZATION.md Phase 0; Locks #1 + #4.\n' >&2
  exit 1
fi

printf 'OK: all @rello-platform/* refs in %s are pinned (tag or full SHA).\n' "$PKG"
