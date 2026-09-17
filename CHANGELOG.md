# Changelog

Versions before 0.19.0 are recorded in their tag messages and commit subjects
(`git log --format='%h %s' v0.4.0..v0.18.0`); this file starts with the first
fix pass whose defects were catalogued by ledger id.

## v0.20.2 — 2026-09-17 — `check-stale-pins`: the header now matches the code on aged-in-place majors (A-02)

`check-stale-pins` only. No consumer is bumped by this release.

- **A-02 — the header promised what the code does not do, and the code was right.** The header said a full major behind "FAILs at any age," but a major behind is FAIL-*class* and passes through the same net-new discriminator as every other FAIL: a major that AGED IN PLACE (identical on the base branch) is absorbed as DEBT, and only a major this push ADDED or CHANGED blocks. That is correct — blocking the next pusher for a stale major they did not introduce is the v0.6.0 distance-gate defect again. Fixed the header + the `classify_tag` comment to state the real rule (aged-in-place major → DEBT, loud; added/changed major → FAIL), and broadened the DEBT definition to name the aged-in-place case (it had only listed the baselined one).
- A major DEBT line now carries `— MAJOR behind — bump deliberately; breaking changes likely`, so a reader does not treat an aged-in-place major like a routine minor.
- Test C4b asserted this as "current behaviour (A-02 open) … flip to exit 1 when A-02 lands." It now asserts it as the DESIGNED behaviour (exit 0, a DEBT line carrying the MAJOR note, summary `FAIL: 0 · DEBT: 1`). No behaviour change to the gate — this release makes the documentation and the test tell the truth the code already told.

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
