# @rello-platform/scripts

Canonical CLI for cross-consumer Rello platform scripts (gates + operational tooling). Single source of truth for the three canonicalized scripts that previously lived as byte-identical local copies across consumer repos:

- `floating-refs` — gate that rejects floating or non-canonical `@rello-platform/*` refs in `package.json` (formerly `scripts/check-floating-refs.sh`).
- `roles` — gate that rejects hardcoded lead-facing role labels in `src/` (formerly `scripts/check-hardcoded-roles.sh`).
- `db-apply-sql` — operational tooling that applies `prisma/sql/*.sql` files via `prisma db execute` (formerly `scripts/db-apply-sql.sh`).

## Provenance

This package is the durable consolidation of three Phase 1 byte-identical baselines:

- `floating-refs` — Phase 0 baseline shipped under PA-ANOMALY-009 Session 4 cleanup (`PERMISSIONS-CANONICALIZATION-PARTIAL.md` Session 4 §B). sha1 `4a98a0ee90aafab6ce4ce291ef680743b57ededb`.
- `roles` — Phase 1 baseline shipped under PA-048-CHECK-HARDCODED-ROLES-CANONICALIZATION-042626. sha1 `6acfc5633d0c9337a33caaa5b5c2bed1dca9d196` (consumer-side; bundled body here drops the `cd "$(dirname "$0")/.."` line since the Node CLI sets `cwd: process.cwd()` to the consumer root before spawning bash).
- `db-apply-sql` — Phase 1 baseline shipped under PA-049-DB-APPLY-SQL-SCRIPT-DRIFT-042626. sha1 `217fd5d60cd330b3e1557269e95b1ee2b2d06fce`.

Phase 2 (this package) is tracked in `~AUDITS/April2026 Platform Audit/PA-053-CHECK-SCRIPTS-PHASE-2-CANONICALIZATION-042626.md`.

## Install

Pin via `github:` in the consumer's `package.json` (matches the platform's `@rello-platform/*` package convention):

```json
{
  "devDependencies": {
    "@rello-platform/scripts": "github:rello-platform/scripts#v0.2.0"
  }
}
```

Then `npm install`.

## Usage

```sh
npx rello-scripts floating-refs                       # defaults to scanning ./package.json
npx rello-scripts floating-refs path/to/package.json
npx rello-scripts floating-refs --root path/to/dir    # scans <dir>/package.json (v0.2.0)

npx rello-scripts roles                               # scans ./src for hardcoded role labels
                                                      # consults ./scripts/check-hardcoded-roles.allowlist (optional)
npx rello-scripts roles --root src/jobs               # non-standard layout (e.g. engines) (v0.2.0)

npx rello-scripts db-apply-sql                        # defaults: ./prisma/schema.prisma + ./prisma/sql
npx rello-scripts db-apply-sql ./schema.prisma ./sql
```

### `--root <path>` (v0.2.0)

Both `floating-refs` and `roles` accept an optional `--root <path>` flag for repos with non-standard layouts:

- `floating-refs --root <dir>` resolves to `<dir>/package.json`. Default: `./package.json`. Backward-compatible: the legacy positional package.json arg still works when `--root` is not provided.
- `roles --root <dir>` scans `<dir>/` for source files instead of `./src/`. Default: `src`. Engine-class repos (e.g. Milo-Engine using `src/jobs/`) pass an explicit root.

If the `--root` path does not exist or is not a directory, both subcommands exit `2` with a friendly error.

### Wire into husky pre-commit

```sh
# .husky/pre-commit
npx rello-scripts floating-refs
npx rello-scripts roles   # only if the consumer adopts the roles gate
```

### Wire into package.json scripts

```json
{
  "scripts": {
    "check:floating-refs": "rello-scripts floating-refs",
    "check:roles": "rello-scripts roles",
    "db:apply-sql": "rello-scripts db-apply-sql"
  }
}
```

### Wire into GitHub Actions

```yaml
# .github/workflows/dep-pin-check.yml
- run: npx rello-scripts floating-refs
```

## Subcommand contracts (locked behavior)

### `floating-refs`

Accepts:
- `github:rello-platform/<pkg>#v<X.Y.Z>[<-prerelease>]` (semver tag)
- `github:rello-platform/<pkg>#<40-char-hex-sha>` (full commit SHA)

Rejects:
- `github:rello-platform/<pkg>` (bare ref, no `#`)
- `github:rello-platform/<pkg>#main` (branch ref)
- `github:rello-platform/<pkg>#<branch-name>` (any non-tag-non-sha ref)
- `github:rello-platform/<pkg>#<short-sha>` (under 40 hex chars)

Exit codes:
- `0` — all refs pinned correctly
- `1` — one or more refs floating / non-canonical
- `2` — `package.json` not found

### `roles`

Searches `src/` for the literals `Real Estate Agent`, `Loan Officer`, `Mortgage Loan Officer`, `Real Estate Broker` in `.ts` / `.tsx` / `.cts` / `.mts` files. Consults `scripts/check-hardcoded-roles.allowlist` for permitted paths (one path per line; `#` comments + blank lines stripped).

Exit codes:
- `0` — no hits, or every hit allowlisted
- `1` — one or more hardcoded role labels found outside the allowlist

### `db-apply-sql`

Applies every `prisma/sql/*.sql` file in glob (filename-sorted) order via `npx prisma db execute --file <f> --schema <schema>`. Fail-fast: any non-zero exit aborts the loop immediately.

Optional positional args:
- `$1` schema path (default: `prisma/schema.prisma`)
- `$2` sql directory (default: `prisma/sql`)

Exit codes:
- `0` — all files applied successfully, OR sql directory exists but is empty
- `1` — any `prisma db execute` invocation returned non-zero (propagated immediately)
- `2` — schema file not found OR sql directory not found

## Versioning

Tags follow semver. Consumers pin to a specific tag (`#v0.1.0`) or a 40-char SHA. Floating refs (`#main`, branch names, short SHAs) are rejected by the `floating-refs` gate the package exposes.

## Adding a new subcommand

New cross-consumer canonicalized scripts ship as new subcommands inside this package, NOT as new per-repo `.sh` files. Process:

1. Add the canonical script body under `scripts/<new-name>.sh`.
2. Wire the subcommand into `bin/rello-scripts` `SUBCOMMANDS` map.
3. Add a behavior-parity smoke test under `test/`.
4. Tag a new minor/patch version.
5. Coordinate consumer pin-bumps in a sequenced rollout (no parallel cutovers per PA-ANOMALY-009 lock).
