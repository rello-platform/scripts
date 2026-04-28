#!/usr/bin/env bash
# Apply every prisma/sql/*.sql file via `prisma db execute`.
#
# Spec: ~/.claude/CLAUDE.md "Database Schema Changes" → "prisma/sql/
# carve-out" paragraph. The carve-out exists for Postgres-native objects
# Prisma's DSL can't model (partial indexes, triggers, GIN-with-where,
# cross-schema views). Each file in prisma/sql/ uses idempotent
# CREATE ... IF NOT EXISTS so re-applying after every `prisma db push`
# is safe.
#
# Canonicalization: PA-049 — this script ships byte-identical across
# every consumer repo that uses the prisma/sql/ carve-out pattern.
# md5 must match across consumers; package.json `db:apply-sql` is a
# thin shim (`bash scripts/db-apply-sql.sh`).
#
# Behavior:
#   - Iterates prisma/sql/*.sql in glob order (filename-sorted in practice).
#   - Fail-fast: any non-zero exit from `prisma db execute` aborts the
#     loop immediately and exits non-zero. No silent "continue past
#     failure" mode — that's the drift PA-049 closed.
#
# Optional positional args (defaults match the convention every consumer uses):
#   $1  schema path (default: prisma/schema.prisma)
#   $2  sql directory (default: prisma/sql)

set -euo pipefail

SCHEMA="${1:-prisma/schema.prisma}"
SQL_DIR="${2:-prisma/sql}"

if [ ! -f "$SCHEMA" ]; then
  printf 'ERROR: schema not found at %s\n' "$SCHEMA" >&2
  exit 2
fi

if [ ! -d "$SQL_DIR" ]; then
  printf 'ERROR: sql directory not found at %s\n' "$SQL_DIR" >&2
  exit 2
fi

shopt -s nullglob
files=("$SQL_DIR"/*.sql)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  printf 'No .sql files in %s — nothing to apply.\n' "$SQL_DIR"
  exit 0
fi

for f in "${files[@]}"; do
  printf 'Applying %s...\n' "$f"
  npx prisma db execute --file "$f" --schema "$SCHEMA"
done

printf 'OK: applied %d file(s) from %s.\n' "${#files[@]}" "$SQL_DIR"
