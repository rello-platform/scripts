# Changelog

Versions before 0.19.0 are recorded in their tag messages and commit subjects
(`git log --format='%h %s' v0.4.0..v0.18.0`); this file starts with the first
fix pass whose defects were catalogued by ledger id.

## v0.20.0 — 2026-09-16 — `check-dist-fresh` reproduces from `compile` (C-33)

- `resolveBuildScript(pkg)` (exported): prefers `scripts.compile`, falls back to `scripts.build`, `null` when neither. The gate runs `npm run <that name>` and names it in its report (`buildScriptName`) and fix line.
- Why: pacote (npm's git fetcher) runs a nested, lockfile-less `npm install` inside every git dependency whose manifest carries `build | prepare | prepack | postinstall | install | preinstall` (`pacote/lib/git.js #prepareDir`). On 2026-09-16 13:32Z one such install resolved `rolldown@latest` during a registry 404 and failed PathfinderPro's and Rello's builds on a docs-only merge. Packages rename `build → compile` (outside that list); this release lets the tag gate follow the rename. Until a package converts, `build` still verifies.

## v0.19.0 — 2026-09-15 — the three-defect fix pass (ledger C-03 / C-04 / C-05)

`check-stale-pins` only. No consumer is bumped by this release; the rollout is
a separate dispatch.

- **A-08 (C-03) — `--write-baseline` merges, it no longer overwrites.** The
  v0.18.0 writer emitted a fixed `{version, recordedAt}` per entry and a
  tool-default `_comment`; one run on MarketIntel-NEW deleted
  `ageDaysAtArming` / `latestAtArming` / `why` and the hand-written rationale
  (md5 `9ecb79d3…` → `10340948…`). Now: an entry already recorded at the same
  version is untouched (its `recordedAt` is the debt's age); an entry at a
  different version is re-recorded (version + recordedAt only, every other key
  kept); a new stale pin is added; entries the run did not collect are left
  alone; `_comment` and every other top-level key survive; an unparseable
  ledger is refused (exit 2), never replaced. Measured on the real MI ledger:
  the diff is additions only.
- **A-09 (C-05) — SHA pins go through the same net-new discriminator as tags.**
  The SHA branch set `HAS_FAIL=1` directly on "≥ 2 minors behind", so a SHA
  pin that aged in place ambushed the next pusher and no ledger entry could
  absorb it (pre-flight §4: exit 1 with and without one). `classify_fail` is
  now one function for both branches: baselined at that SHA → `DEBT
  [baselined]`; identical to the base branch → `DEBT [aged in place]`; added
  or changed by this push → `FAIL`; base unreadable → `FAIL` (fail-closed).
  `--write-baseline` records SHA pins. The allowlist path is untouched — a
  test carries Rello's real EX-1 entry shape. Distance is still what makes a
  SHA stale (a SHA has no tag date).
- **A-01 (C-04) — the summary states what the run found.** The exit-0 line
  asserted "all pins within 1 minor of canonical-latest" — the retired
  distance axis — beside DEBT lines twelve minors behind. Both final lines now
  carry counts read from the report itself (`FAIL: n · DEBT: n · WARN: n ·
  OK: n`); `OK` is printed only when FAIL = 0 and says why the DEBT lines do
  not block. Test C4 now runs in a real git fixture with a readable base; its
  aged-in-place cell documents that a full major behind is absorbed as DEBT
  today — that is A-02, still open.
- This repo's own `.husky/pre-push` now runs `tag-dist-gate` on `v*` tag
  pushes (dogfood; the exemption in `.dist-fresh-exempt` applies).

Suite: 144 checks (was 120), each fix red-first and mutation-verified.
