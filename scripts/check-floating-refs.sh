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
# v0.2.0 — accepts optional `--root <dir>` flag (resolves to <dir>/package.json).
# Backward-compatible: existing positional package.json arg still works.
#
# Spec: PERMISSIONS-CANONICALIZATION.md Phase 0; Locks #1 + #4.

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
