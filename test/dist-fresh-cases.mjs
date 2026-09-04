#!/usr/bin/env node
/**
 * Unit tests for check-dist-fresh's pure core.
 *
 * `diffTrees` and `classify` are exported so the CLASSIFICATION is pinned
 * without building anything — the same reason Rello's check-tenant-scope-throws
 * exports `scanSource`. The end-to-end behaviour (real builds, real repos) is
 * exercised separately; this file pins the decisions those runs depend on.
 *
 * The load-bearing case is the one that is easy to get wrong: a
 * NON-DETERMINISTIC build must classify UNVERIFIED, never STALE. "the build
 * does not reproduce itself" and "the committed output is old" are different
 * facts, and reporting the second when the first is true sends someone to
 * rebuild a package that will never match.
 */

import assert from "node:assert/strict";
import {
  diffTrees,
  classify,
  EXIT_FRESH,
  EXIT_STALE,
  EXIT_UNVERIFIED,
} from "../scripts/check-dist-fresh.mjs";

let pass = 0;
let fail = 0;
const t = (name, fn) => {
  try {
    fn();
    pass++;
    process.stdout.write(`  ok  ${name}\n`);
  } catch (err) {
    fail++;
    process.stdout.write(`  FAIL ${name}\n       ${err.message}\n`);
  }
};

const tree = (obj) => new Map(Object.entries(obj));

process.stdout.write("check-dist-fresh — pure core\n");

// ── diffTrees ───────────────────────────────────────────────────────────────

t("identical trees match", () => {
  const a = tree({ "index.js": "h1", "index.d.ts": "h2" });
  const r = diffTrees(a, tree({ "index.js": "h1", "index.d.ts": "h2" }));
  assert.equal(r.matches, true);
  assert.deepEqual([r.missing, r.extra, r.changed], [[], [], []]);
});

t("a changed file is `changed`, not missing+extra", () => {
  const r = diffTrees(tree({ "index.js": "old" }), tree({ "index.js": "new" }));
  assert.deepEqual(r.changed, ["index.js"]);
  assert.deepEqual(r.missing, []);
  assert.deepEqual(r.extra, []);
  assert.equal(r.matches, false);
});

t("committed-but-not-produced is `missing` (the stale-dist shape)", () => {
  // The real rate-types condition: dist carries a file src no longer emits.
  const r = diffTrees(tree({ "index.js": "h", "gone.js": "h" }), tree({ "index.js": "h" }));
  assert.deepEqual(r.missing, ["gone.js"]);
  assert.equal(r.matches, false);
});

t("produced-but-not-committed is `extra` (src advanced, dist not rebuilt)", () => {
  const r = diffTrees(tree({ "index.js": "h" }), tree({ "index.js": "h", "new.js": "h" }));
  assert.deepEqual(r.extra, ["new.js"]);
  assert.equal(r.matches, false);
});

t("an EMPTY committed tree never silently matches a real build", () => {
  const r = diffTrees(tree({}), tree({ "index.js": "h" }));
  assert.equal(r.matches, false);
  assert.deepEqual(r.extra, ["index.js"]);
});

t("two empty trees match (degenerate, but must not throw)", () => {
  assert.equal(diffTrees(tree({}), tree({})).matches, true);
});

t("results are sorted, so output is stable across filesystem ordering", () => {
  const r = diffTrees(tree({ b: "1", a: "1", c: "1" }), tree({}));
  assert.deepEqual(r.missing, ["a", "b", "c"]);
});

t("nested paths compare by full relative path", () => {
  const r = diffTrees(tree({ "a/index.js": "h" }), tree({ "b/index.js": "h" }));
  assert.deepEqual(r.missing, ["a/index.js"]);
  assert.deepEqual(r.extra, ["b/index.js"]);
});

// ── classify ────────────────────────────────────────────────────────────────

t("deterministic + matching => FRESH", () => {
  assert.equal(classify({ deterministic: true, distDiff: { matches: true } }), EXIT_FRESH);
});

t("deterministic + differing => STALE", () => {
  assert.equal(classify({ deterministic: true, distDiff: { matches: false } }), EXIT_STALE);
});

t("NON-deterministic => UNVERIFIED even when the dist happens to match", () => {
  // The trap: a matching comparison against an unstable build is luck, not
  // evidence. Reporting FRESH here would be a green that means nothing.
  assert.equal(classify({ deterministic: false, distDiff: { matches: true } }), EXIT_UNVERIFIED);
});

t("NON-deterministic => UNVERIFIED, never STALE", () => {
  assert.equal(classify({ deterministic: false, distDiff: { matches: false } }), EXIT_UNVERIFIED);
});

t("UNVERIFIED is distinct from both other outcomes", () => {
  assert.notEqual(EXIT_UNVERIFIED, EXIT_FRESH);
  assert.notEqual(EXIT_UNVERIFIED, EXIT_STALE);
  assert.equal(EXIT_FRESH, 0);
  assert.equal(EXIT_STALE, 1);
  assert.equal(EXIT_UNVERIFIED, 2);
});

t("no outcome value is reachable by testing `!== 1`", () => {
  // The exit-code corollary from unknown-is-not-absent.md: a caller testing for
  // the bad case by elimination reads UNVERIFIED as a pass. Pinning the three
  // distinct codes is what makes `require exit 0` the only correct caller.
  const codes = new Set([EXIT_FRESH, EXIT_STALE, EXIT_UNVERIFIED]);
  assert.equal(codes.size, 3);
});

process.stdout.write(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
