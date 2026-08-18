# @rello-platform/scripts

Canonical CLI for cross-consumer Rello platform scripts (gates + operational tooling). Single source of truth for the three canonicalized scripts that previously lived as byte-identical local copies across consumer repos:

- `floating-refs` — gate that rejects floating or non-canonical `@rello-platform/*` refs in `package.json` (formerly `scripts/check-floating-refs.sh`).
- `roles` — gate that rejects hardcoded lead-facing role labels in `src/` (formerly `scripts/check-hardcoded-roles.sh`).
- `db-apply-sql` — operational tooling that applies `prisma/sql/*.sql` files via `prisma db execute` (formerly `scripts/db-apply-sql.sh`).
- `pre-delete-grep-gate` — pre-commit gate enforcing PLATFORM-CLASS-LEVEL-RULES.md Rule J: deletion-bearing commits cite pre-flight grep evidence in the message body. Ships at warn (v0.3.0); promotion to error gated on Kelly authorization OR 14-day soak.
- `schema-change-reminder` — pre-commit advisory: when `prisma/schema.prisma` is staged, prompts the author to confirm `prisma migrate diff --exit-code` was run and verification lines are pasted in the commit body. Always advisory (never blocks).
- `check-stale-pins` — pre-push gate (v0.4.0) that rejects `@rello-platform/*` pins ≥2 minors behind their canonical-latest **git tag**. Fail-open when offline. See PLATFORM-PACKAGE-PIN-CONVENTION-AND-VERSION-SYNC Phase 4. Since v0.5.0 it also runs the `check-lockfile-ssh` gate against the adjacent `package-lock.json`.
- `check-lockfile-ssh` — gate (v0.5.0) that rejects `"resolved": "git+ssh://…"` entries in `package-lock.json` (Railway build containers have no ssh key — any cache miss fails `npm ci` with `Permission denied (publickey)`). `--fix` rewrites github.com entries in place to `git+https://github.com/<org>/<repo>.git#<sha>`, sha preserved. See DISCOVERED-PLATFORM-GITHUB-PIN-SSH-LOCKFILE-RAILWAY-CACHE-LUCK-260610 (AMENDED).

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
    "@rello-platform/scripts": "github:rello-platform/scripts#v0.5.0"
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

npx rello-scripts check-stale-pins                    # defaults to scanning ./package.json (v0.4.0)
npx rello-scripts check-stale-pins --root path/to/dir # scans <dir>/package.json

npx rello-scripts check-lockfile-ssh                  # defaults to scanning ./package-lock.json (v0.5.0)
npx rello-scripts check-lockfile-ssh --fix            # rewrite git+ssh github entries to git+https in place
npx rello-scripts check-lockfile-ssh --root path/to/dir [--fix]   # scans <dir>/package-lock.json
```

### `--root <path>` (v0.2.0)

Both `floating-refs` and `roles` accept an optional `--root <path>` flag for repos with non-standard layouts:

- `floating-refs --root <dir>` resolves to `<dir>/package.json`. Default: `./package.json`. Backward-compatible: the legacy positional package.json arg still works when `--root` is not provided.
- `roles --root <dir>` scans `<dir>/` for source files instead of `./src/`. Default: `src`. Engine-class repos (e.g. Milo-Engine using `src/jobs/`) pass an explicit root.

If the `--root` path does not exist or is not a directory, both subcommands exit `2` with a friendly error.

### Wire into husky pre-commit

```sh
# .husky/pre-commit
npx lint-staged
npx rello-scripts floating-refs
npx rello-scripts roles   # only if the consumer adopts the roles gate

# v0.3.0 — Rule J + schema-change discipline:
npx rello-scripts pre-delete-grep-gate
npx rello-scripts schema-change-reminder
```

### Wire into husky pre-push (v0.4.0 staleness gate)

`check-stale-pins` is a **pre-push** gate (not pre-commit) — it makes a network
call per `@rello-platform/*` dep, so it belongs on push, not on every commit.
Add it alongside the existing tsc/build/test steps. Because the script is
**fail-open** (exit 0 on WARN / offline / rate-limit; exit 1 only on a real
FAIL), a bare invocation under `set -e` blocks a push ONLY when a pin is ≥2
minors behind with network available — exactly the intended behavior:

```sh
# .husky/pre-push   (after tsc / build / test)
npx rello-scripts check-stale-pins
```

Since v0.5.0 this invocation ALSO runs the `check-lockfile-ssh` gate against the
`package-lock.json` next to the scanned `package.json` (when one exists) — so a
repo that already wires `check-stale-pins` inherits the ssh-lockfile guard with
a pin bump and **zero hook edits**. Unlike the staleness check, the lockfile
gate is local-only (no network) and is **not** fail-open: a `git+ssh://`
resolved entry blocks the push even offline.

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

As of **v0.3.1** the gate parses `dependencies`, `devDependencies`,
`optionalDependencies`, and `peerDependencies` structurally (via Node) and
validates every `@rello-platform/*` value — not just `github:`-prefixed ones.
The pre-v0.3.1 prefix-only grep silently ignored `git+https://`, npm-caret, and
wildcard shapes.

Accepts:
- `github:rello-platform/<pkg>#v<X.Y.Z>[<-prerelease>]` (semver tag)
- `github:rello-platform/<pkg>#<40-char-hex-sha>` (full commit SHA)
- `"*"` / `"workspace:*"` / `"workspace:^"` — **only** when a local npm-workspace
  member package with that exact `name` exists (workspaces globs in the same
  `package.json`, expanded and read). A wildcard/workspace value with **no**
  matching member is a violation. See `DISCOVERED-PINCONV-ASSET-WHITELIST-IS-
  WORKSPACE-PKG-NOT-VIOLATION-260524` (Rello's `@rello-platform/asset-whitelist`).

Rejects:
- `github:rello-platform/<pkg>` (bare ref, no `#`)
- `github:rello-platform/<pkg>#main` (branch ref)
- `github:rello-platform/<pkg>#<branch-name>` (any non-tag-non-sha ref)
- `github:rello-platform/<pkg>#<short-sha>` (under 40 hex chars)
- `git+https://github.com/rello-platform/<pkg>.git#...` / `git+ssh://` / `https://`
- `^X.Y.Z` / `~X.Y.Z` / `X.Y.Z` (npm range / exact registry semver)
- `npm:@scope/x@1` (npm alias) / `file:../x` / `link:../x`
- `"*"` / `"workspace:*"` with no matching local workspace member

Exit codes:
- `0` — all refs pinned correctly
- `1` — one or more refs floating / non-canonical
- `2` — `package.json` not found, malformed, or unparseable

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

### `pre-delete-grep-gate` (v0.3.0)

Pre-commit gate enforcing PLATFORM-CLASS-LEVEL-RULES.md Rule J. When the staged commit deletes ≥1 file, the gate grep-checks the prepared commit message (`.git/COMMIT_EDITMSG`) for one of:

- `Rule J: <evidence>`
- `Pre-Delete grep: <evidence>`
- `pre-flight grep: <evidence>`

Severity ramp:
- v0.3.0 ships at **warn** — prints message but exits 0.
- Promotion to **error** (exit 1) gated on Kelly authorization OR 14-day soak (whichever later) per `feedback-pre-launch-no-interrupting-gates`.

Suppress: `RELLO_SKIP_PREDELETE_GREP=1`. Skipped in CI (`CI=true`).

Exit codes (current — warn mode):
- `0` — no deletes, OR deletes + grep evidence, OR deletes + missing evidence (warn)

### `schema-change-reminder` (v0.3.0)

Pre-commit advisory. When `prisma/schema.prisma` is staged, the script grep-checks the commit message for evidence that the schema-change ritual (`~/.claude/standards/db-schema-changes.md`) ran:

- `prisma migrate diff` AND `No difference detected`, OR
- `Verification:` AND both `tsc --noEmit` AND `migrate diff`.

If absent, prints a one-screen reminder. **Always advisory — never blocks.** Schema-change discipline is a 7-step ritual; one CLI hook can't verify all 7 — it can only prompt.

Suppress: `RELLO_SKIP_SCHEMA_REMINDER=1`. Skipped in CI.

### `check-stale-pins` (v0.4.0)

Version-staleness gate. For every `@rello-platform/*` dep in the consumer's
`package.json`, it determines canonical-latest from the dep repo's newest git
**tag** (`gh api repos/rello-platform/<repo>/tags`, `sort -V`) — **not**
`gh release list`, because releases lag tags (e.g. `permissions` latest release
`v0.35.0` vs latest tag `v0.41.0`). The repo name is read from the **pin value**
(`github:rello-platform/<repo>#…`), not the package key — so `@rello-platform/ui`
correctly resolves to repo `rello-ui`.

Classification (per spec §4 + Build-KA Phase 4 lock):

| Class | Condition | Effect |
|---|---|---|
| `OK`   | current, or ahead of latest tag | — |
| `WARN` | exactly 1 minor behind | surfaced, does **not** block |
| `FAIL` | ≥2 minors behind, **or** a full major behind | exit 1, blocks push |

Prerelease tags (`v1.2.3-rc.1`) are ignored for staleness counting.

**SHA-pinned deps** carry no semver, so the gate resolves them with
`gh api repos/rello-platform/<repo>/compare/<base>...<sha>` (≤3 calls):
ahead/identical to latest tag → `OK`; diverged → `WARN`; behind latest but at/
ahead of the second-newest minor tag → `WARN` (1 behind); behind that too →
`FAIL` (≥2 behind).

**Skips:** workspace/wildcard refs (`"*"`, `"workspace:*"`) and non-canonical
forms (caret/registry/`git+https` with no resolvable repo) — pin *form* is the
`floating-refs` gate's job, so those are reported `WARN`/`SKIP`, never `FAIL`.

**Fail-open offline:** if `gh`/network is unreachable or rate-limited, the dep
is reported `UNKNOWN` (WARN-class) and never `FAIL`s — a pre-push hook must not
block an offline developer. The gate uses `GH_TOKEN`/`GITHUB_TOKEN` (read
automatically by `gh`) for an authenticated rate budget when present.

#### Intentional-hold exceptions (allowlist)

A pin that is *intentionally* held behind canonical-latest (e.g. a CJS-boundary
hold, or a SHA pinned ahead of the latest tag) must be allowlisted so it
classifies `OK` instead of `FAIL`. **Note:** a `// stale-pin-ok` comment inside
`package.json` is **not** supported — `package.json` is strict JSON and a comment
breaks `npm install`. Two JSON-legal mechanisms exist instead:

1. **Sidecar file** `scripts/stale-pin-exceptions.json` (recommended):

   ```json
   {
     "@rello-platform/api-client": "CJS-held at v1.9.0; api-client v2.6.0+ is ESM-only. See DISCOVERED-PINCONV-PHASE2-INTENTIONAL-PIN-EXCEPTIONS-260524."
   }
   ```
   (Also accepts `{ "exceptions": { … } }` or `{ "exceptions": [ {"package": "…", "reason": "…"} ] }`.)

2. **Inline field** `relloStalePinExceptions` inside `package.json` — the
   JSON-legal "annotation next to the dep":

   ```json
   { "relloStalePinExceptions": { "@rello-platform/api-client": "<reason>" } }
   ```

A dep present in either is reported `OK (allowlisted: <reason>)` and never
`FAIL`s. The sidecar wins on conflict. Always record a real reason — the
allowlist is for *documented intentional* holds, never to silence a genuine
staleness finding (bump the pin instead).

**Embedded lockfile gate (v0.5.0):** after the per-dep walk, the gate runs
`check-lockfile-ssh` against the `package-lock.json` adjacent to the scanned
`package.json` (skipped when no lockfile exists). This runs even when there are
no `@rello-platform/*` deps (any git dep can carry a `git+ssh` resolved entry)
and is **not** covered by the fail-open-offline carve-out — it is local-only.
A finding exits `1` with the `--fix` remediation named.

Exit codes:
- `0` — all deps OK/WARN/SKIP/UNKNOWN/allowlisted (offline always lands here) and (v0.5.0) no `git+ssh` lockfile entries
- `1` — one or more deps are `FAIL` (≥2 minors / a major behind) and not allowlisted, **or** (v0.5.0) the adjacent `package-lock.json` carries `git+ssh://` resolved entries (or is unparseable)
- `2` — `package.json` not found or unparseable, or `--root` path invalid

### `check-lockfile-ssh` (v0.5.0)

SSH-lockfile guard. The platform pin convention `github:rello-platform/<pkg>#vX.Y.Z`
makes npm record `"resolved": "git+ssh://git@github.com/…"` in
`package-lock.json`. Local installs mask it (a global ssh→https git rewrite),
but **Railway build containers have no ssh key and no rewrite** — a live
`git ls-remote ssh://git@github.com/…` during `npm ci` fails
`Permission denied (publickey)` → exit 128 → deploy FAILED. Pre-existing ssh
entries only build via npm build-cache luck; any cache eviction, fresh service,
or net-new git dep fails deterministically (proven fatal 2026-06-10 by
`vault-crypto` across Newsletter-Studio, the-drumbeat, Open-House-Hub).

The durable fix is a hand-edit of the lockfile `resolved` field only — pacote
fetches verbatim from `resolved`. A `git+https` spec in `package.json` is NOT
viable: npm's hosted-git-info re-canonicalizes it back to the `github:`
shortcut + ssh `resolved`, and the `floating-refs` gate rejects that spec form
anyway. And because **`npm install` re-stamps `git+ssh`** on any install
touching a git dep, the guard lives in the hook chain (this gate) so the loop
is self-healing: install re-stamps → gate fails → `--fix` re-heals → commit.

Behavior:

- **Check mode** (default): FAIL (exit 1) if `package-lock.json` contains any
  `"resolved": "git+ssh://…"` entry. The message names each offender (lockfile
  package path + URL) and the `--fix` remediation.
- **`--fix`**: rewrites github.com offenders in place to
  `git+https://github.com/<org>/<repo>.git#<sha>` (sha/ref fragment preserved
  verbatim) via exact-string replacement of each quoted `resolved` value —
  npm's lockfile formatting is untouched, and the rewrite is parse-verified
  before the file is written. Non-github `git+ssh` entries are NOT
  auto-fixable and still exit 1 (named for manual review).
- Walks both lockfile shapes: v2/v3 flat `packages` map and v1 nested
  `dependencies` tree (recursive).
- Local-only: no network, no fail-open carve-out.
- Also invoked automatically by `check-stale-pins` (see above), so consumer
  repos inherit this gate wherever that one already runs — pin bump only,
  zero hook edits.

Exit codes:
- `0` — no `git+ssh` resolved entries (or `--fix` rewrote every offender)
- `1` — `git+ssh` resolved entries present (check mode), or unfixable non-github entries remain after `--fix`
- `2` — `package-lock.json` not found or unparseable, or `--root` path invalid

Spec: DISCOVERED-PLATFORM-GITHUB-PIN-SSH-LOCKFILE-RAILWAY-CACHE-LUCK-260610
(AMENDED 2026-06-10 — "the durable guard must live in the hook chain").

## Versioning

Tags follow semver. Consumers pin to a specific tag (`#v0.1.0`) or a 40-char SHA. Floating refs (`#main`, branch names, short SHAs) are rejected by the `floating-refs` gate the package exposes.

## Adding a new subcommand

New cross-consumer canonicalized scripts ship as new subcommands inside this package, NOT as new per-repo `.sh` files. Process:

1. Add the canonical script body under `scripts/<new-name>.sh`.
2. Wire the subcommand into `bin/rello-scripts` `SUBCOMMANDS` map.
3. Add a behavior-parity smoke test under `test/`.
4. Tag a new minor/patch version.
5. Coordinate consumer pin-bumps in a sequenced rollout (no parallel cutovers per PA-ANOMALY-009 lock).

## Local verification (pre-push hook)

CI (`ci.yml`) was retired 2026-05-24 (GH-Actions retirement workstream). Verification
now runs locally via the committed `.husky/pre-push` hook (`npm test` — the behavior
harness + floating-refs dogfood the workflow ran). The hook is not auto-installed
(no lifecycle script, matching the existing `.husky/pre-commit`). Enable once per clone:

```sh
git config core.hooksPath .husky
```

## `verify-sql-objects`

Asserts that every Postgres object declared in the consumer's `prisma/sql/*.sql`
actually **exists in the live database**.

```bash
npx rello-scripts verify-sql-objects            # resolves the URL from .env
npx rello-scripts verify-sql-objects --url "postgres://…"
npx rello-scripts verify-sql-objects --inventory   # dump everything parsed
```

| exit | meaning |
|------|---------|
| 0 | every declared object is present |
| 1 | an object is **missing** — a push dropped it; restore with `db-apply-sql` |
| 2 | **UNVERIFIED** — no DB URL, unreachable, or DDL this parser does not model. Never a pass. |

**Why it exists.** `prisma db push` silently drops every object Prisma's DSL
cannot model: predicated (partial) indexes, `hnsw`/`gin`/`gist`, triggers,
functions, CHECK constraints, cross-schema views, enum members. It is the
counterpart to `db-apply-sql` — that one applies the DDL, this one proves it is
still there.

**`prisma migrate diff` cannot do this job, and the reason is subtle.** For an
object declared in `prisma/sql/` but not in `schema.prisma`, diff reports drift
while the object EXISTS, and reports "No difference detected" once it has been
dropped. The signal disappears at the moment the damage is done, so a clean diff
is not evidence — it is equally consistent with the object being gone. Only a
catalog query separates the two.

URL resolution order: `DIRECT_URL`, `DIRECT_DATABASE_URL`, `DATABASE_URL` —
read from the consumer's `.env` in Node (never shell-sourced, so a malformed
line cannot abort a caller running under `set -e`), with real environment
variables taking precedence.
