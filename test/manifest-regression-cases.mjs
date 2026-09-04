#!/usr/bin/env node
/**
 * Unit tests for the pure cores of check-manifest-regression and
 * check-explicit-apikey.
 *
 * The load-bearing case for the manifest check is the one that is easy to get
 * wrong in the punitive direction: FIVE of the nine platform packages ship no
 * `exports` key at all. A baseline without one imposes no constraint, and adding
 * one later is widening. A check that treats absence as narrowing would fail
 * five repos on day one and be turned off by the end of the week.
 */

import assert from "node:assert/strict";
import {
  parseVersion,
  compareVersions,
  flattenExports,
  diffManifests,
  newestVersionTag,
  collectTargets,
  missingTargets,
} from "../scripts/check-manifest-regression.mjs";
import { scanSource, importedCtorNames } from "../scripts/check-explicit-apikey.mjs";
import { priorVersionTag } from "../scripts/tag-dist-gate.mjs";

/**
 * Every construction site the scanner counts must be bound to the package.
 * Test sources therefore carry the import, exactly as the real files do.
 */
const IMP = `import { RelloClient, createRelloClient } from "@rello-platform/api-client";\n`;
const withImport = (src) => IMP + src;

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

process.stdout.write("check-manifest-regression — pure core\n");

// ── versions ────────────────────────────────────────────────────────────────

t("parses plain and prerelease versions, rejects junk", () => {
  assert.deepEqual(parseVersion("2.25.0"), [2, 25, 0]);
  assert.deepEqual(parseVersion("1.0.0-rc.1"), [1, 0, 0]);
  assert.equal(parseVersion("latest"), null);
  assert.equal(parseVersion(undefined), null);
});

t("compares versions numerically, not lexically", () => {
  // The bug a string compare would hide: "2.9.0" > "2.25.0" lexically.
  assert.equal(compareVersions("2.25.0", "2.9.0"), 1);
  assert.equal(compareVersions("2.23.0", "2.25.0"), -1);
  assert.equal(compareVersions("1.2.3", "1.2.3"), 0);
  assert.equal(compareVersions("x", "1.0.0"), null);
});

t("🔴 THE REAL INCIDENT: 2.25.0 -> 2.23.0 is a regression", () => {
  const r = diffManifests({ version: "2.25.0" }, { version: "2.23.0" });
  assert.equal(r.ok, false);
  assert.equal(r.problems[0].kind, "version-decrease");
  assert.match(r.problems[0].detail, /2\.25\.0 -> 2\.23\.0/);
});

t("a version bump is fine", () => {
  assert.equal(diffManifests({ version: "2.25.0" }, { version: "2.26.0" }).ok, true);
});

t("an equal version is fine (a non-release commit)", () => {
  assert.equal(diffManifests({ version: "1.0.0" }, { version: "1.0.0" }).ok, true);
});

t("an unparseable version is reported, not silently passed", () => {
  const r = diffManifests({ version: "1.0.0" }, { version: "banana" });
  assert.equal(r.ok, false);
  assert.equal(r.problems[0].kind, "version-unparseable");
});

// ── exports ─────────────────────────────────────────────────────────────────

t("flattens subpaths and conditions into distinct leaves", () => {
  const leaves = flattenExports({
    ".": { import: "./dist/index.js", require: "./dist/index.cjs" },
    "./contracts": "./dist/contracts.js",
  });
  assert.equal(leaves.has(". [import]"), true);
  assert.equal(leaves.has(". [require]"), true);
  assert.equal(leaves.has("./contracts [default]"), true);
});

t("🔴 THE REAL INCIDENT: losing the `require` condition is narrowing", () => {
  const baseline = {
    version: "2.25.0",
    exports: {
      ".": {
        import: { types: "./dist/index.d.ts", default: "./dist/index.js" },
        require: { types: "./dist/index.d.cts", default: "./dist/index.cjs" },
      },
    },
  };
  const current = {
    version: "2.25.0",
    exports: { ".": { types: "./dist/index.d.ts", import: "./dist/index.js" } },
  };
  const r = diffManifests(baseline, current);
  assert.equal(r.ok, false);
  assert.ok(
    r.problems.some((p) => p.kind === "exports-narrowed" && /require/.test(p.detail)),
    "the removed require condition must be named",
  );
});

t("removing a whole subpath is narrowing", () => {
  const r = diffManifests(
    { version: "1.0.0", exports: { ".": "./a.js", "./extra": "./b.js" } },
    { version: "1.0.0", exports: { ".": "./a.js" } },
  );
  assert.equal(r.ok, false);
  assert.ok(r.problems.some((p) => /\.\/extra/.test(p.detail)));
});

t("🔴 ABSENCE IS NOT NARROWING — five of nine packages ship no exports key", () => {
  // Both sides absent: no constraint, no finding.
  assert.equal(diffManifests({ version: "1.0.0" }, { version: "1.0.0" }).ok, true);
});

t("ADDING an exports map is widening, not a regression", () => {
  const r = diffManifests(
    { version: "1.0.0" },
    { version: "1.0.0", exports: { ".": { import: "./a.js", require: "./a.cjs" } } },
  );
  assert.equal(r.ok, true);
});

t("adding a condition to an existing map is widening", () => {
  const r = diffManifests(
    { version: "1.0.0", exports: { ".": { import: "./a.js" } } },
    { version: "1.0.0", exports: { ".": { import: "./a.js", require: "./a.cjs" } } },
  );
  assert.equal(r.ok, true);
});

// ── entry fields and bins ───────────────────────────────────────────────────

t("🔴 THE REAL INCIDENT: losing `module` is a removed entry point", () => {
  const r = diffManifests(
    { version: "1.0.0", main: "./dist/index.cjs", module: "./dist/index.js" },
    { version: "1.0.0", main: "./dist/index.js" },
  );
  assert.equal(r.ok, false);
  assert.ok(r.problems.some((p) => p.kind === "entry-removed" && /module/.test(p.detail)));
});

t("an entry field ABSENT in the baseline imposes nothing", () => {
  const r = diffManifests({ version: "1.0.0", main: "./a.js" }, { version: "1.0.0", main: "./a.js" });
  assert.equal(r.ok, true);
});

t("a removed bin name is a regression", () => {
  const r = diffManifests(
    { version: "1.0.0", bin: { "rello-scripts": "bin/x", other: "bin/y" } },
    { version: "1.0.0", bin: { "rello-scripts": "bin/x" } },
  );
  assert.equal(r.ok, false);
  assert.ok(r.problems.some((p) => p.kind === "bin-removed"));
});

t("newestVersionTag sorts by semver, not string order", () => {
  assert.equal(newestVersionTag(["v2.9.0", "v2.25.0", "v2.10.0"]), "v2.25.0");
  assert.equal(newestVersionTag(["nightly", "notatag"]), null);
  assert.equal(newestVersionTag([]), null);
});

// ── check-explicit-apikey ───────────────────────────────────────────────────

process.stdout.write("\ncheck-explicit-apikey — pure core\n");

t("an explicit apiKey on the same line is explicit", () => {
  const f = scanSource("a.ts", withImport(`const c = new RelloClient({ apiKey: key });`));
  assert.equal(f.length, 1);
  assert.equal(f[0].explicit, true);
});

t("an explicit apiKey a few lines below is still explicit", () => {
  const f = scanSource("a.ts", withImport(["new RelloClient({", "  baseUrl: url,", "  apiKey: key,", "});"].join("\n")));
  assert.equal(f[0].explicit, true);
});

t("🔴 an omitted apiKey is IMPLICIT — the site that silently takes RELLO_API_KEY", () => {
  const f = scanSource("a.ts", withImport(`const c = new RelloClient({ baseUrl: url });`));
  assert.equal(f[0].explicit, false);
});

t("an empty config is implicit", () => {
  assert.equal(scanSource("a.ts", withImport("new RelloClient({})"))[0].explicit, false);
});

t("createRelloClient is recognised too", () => {
  const f = scanSource("a.ts", withImport("createRelloClient({ baseUrl })"));
  assert.equal(f.length, 1);
  assert.equal(f[0].explicit, false);
});

t("commented-out constructions are not counted", () => {
  // Counting prose was this class of guard's own first bug, twice.
  const src = ["// new RelloClient({})", "/* new RelloClient({}) */", " * new RelloClient({})"].join("\n");
  assert.deepEqual(scanSource("a.ts", withImport(src)), []);
});

t("a block comment spanning lines is skipped entirely", () => {
  const src = ["/*", "new RelloClient({})", "*/", "new RelloClient({ apiKey: k })"].join("\n");
  const f = scanSource("a.ts", withImport(src));
  assert.equal(f.length, 1);
  assert.equal(f[0].explicit, true);
});

t("🔴 the ES6 SHORTHAND `apiKey,` is explicit — this scanner's own first bug", () => {
  // The-Home-Scout writes `createRelloClient({ appSlug, apiKey })`. A regex
  // requiring `apiKey:` reported that correctly-explicit site as implicit,
  // which is how the platform count came out wrong on the first pass.
  const f = scanSource("a.ts", withImport("createRelloClient({\n  appSlug: A,\n  apiKey,\n});"));
  assert.equal(f[0].explicit, true);
});

t("shorthand immediately before the closing brace is explicit", () => {
  assert.equal(scanSource("a.ts", withImport("new RelloClient({\n  apiKey\n})"))[0].explicit, true);
});

t("🔴 a comment saying \"pass apiKey explicitly\" does NOT make a site explicit", () => {
  // Three spokes carry exactly this comment. A substring match would read the
  // comments this workstream exists to remove as proof the work was done.
  const f = scanSource("a.ts", withImport("new RelloClient({\n  // remember to pass apiKey\n  baseUrl,\n})"));
  assert.equal(f[0].explicit, false);
});

t("line numbers are 1-indexed so a finding is navigable", () => {
  const f = scanSource("a.ts", withImport(["", "", "new RelloClient({})"].join("\n")));
  assert.equal(f[0].line, 4); // +1 for the import line
});

t("🔴 a LOCAL class named RelloClient is not this package — HomeReady rello.ts:164", () => {
  // HomeReady declares `class RelloClient {}` of its own and constructs it with
  // positional args. It cannot use the RELLO_API_KEY fallback because it is not
  // this package. Counting it inflated the denominator by one.
  const src = `class RelloClient {}\nconst c = new RelloClient(apiKey, tenantId);`;
  assert.deepEqual(scanSource("a.ts", src), []);
});

t("🔴 a LOCAL factory shadowing the name is not this package — MarketIntel", () => {
  // MarketIntel imports the real one under an alias and exports its own wrapper
  // by the original name. Twelve calls to the wrapper were counted as twelve
  // package construction sites; the package is constructed once, inside it.
  const src = [
    `import { createRelloClient as createSharedClient } from "@rello-platform/api-client";`,
    `export function createRelloClient(config) { return {}; }`,
    `const a = createRelloClient().withTenant(t);`,
    `const b = createRelloClient().withTenant(t);`,
    `const real = createSharedClient({ appSlug: S });`,
  ].join("\n");
  const f = scanSource("a.ts", src);
  assert.equal(f.length, 1, "only the aliased package call counts");
  assert.equal(f[0].explicit, false, "and it is implicit");
});

t("importedCtorNames resolves aliases and ignores unrelated imports", () => {
  assert.deepEqual(importedCtorNames(`import { RelloClient } from "@rello-platform/api-client";`), [
    "RelloClient",
  ]);
  assert.deepEqual(
    importedCtorNames(`import { createRelloClient as mk } from "@rello-platform/api-client";`),
    ["mk"],
  );
  assert.deepEqual(importedCtorNames(`import { RelloClient } from "some-other-pkg";`), []);
  assert.deepEqual(importedCtorNames(`import { getRelloBaseUrl } from "@rello-platform/api-client";`), []);
});

t("a multi-line import clause is resolved — every real file uses that form", () => {
  const src = [
    `import {`,
    `  createRelloClient as createSharedClient,`,
    `  type RelloClientConfig as SharedConfig,`,
    `} from '@rello-platform/api-client';`,
    `const c = createSharedClient({ appSlug: S });`,
  ].join("\n");
  assert.deepEqual(importedCtorNames(src), ["createSharedClient"]);
  assert.equal(scanSource("a.ts", src).length, 1);
});

process.stdout.write("\ntag-dist-gate — manifest baseline selection\n");

t("🔴 THE INERT-GATE TRAP: the tag being pushed is never its own baseline", () => {
  // At pre-push the tag ALREADY exists locally. A baseline of "newest v* tag"
  // would compare the manifest to itself, pass unconditionally, and print green
  // forever — a gate that runs and cannot fail.
  assert.equal(priorVersionTag(".", "v0.9.0", ["v0.7.0", "v0.8.0", "v0.9.0"]), "v0.8.0");
});

t("baseline is the newest tag strictly below, not merely the previous one", () => {
  assert.equal(priorVersionTag(".", "v2.26.0", ["v2.9.0", "v2.25.0", "v2.10.0"]), "v2.25.0");
});

t("a first release has no baseline — no constraint, not 'could not tell'", () => {
  assert.equal(priorVersionTag(".", "v1.0.0", []), null);
  assert.equal(priorVersionTag(".", "v1.0.0", ["v1.0.0"]), null);
});

t("a tag below every existing one has no baseline", () => {
  assert.equal(priorVersionTag(".", "v0.1.0", ["v0.7.0", "v0.8.0"]), null);
});

t("a non-semver tag yields no baseline rather than a wrong one", () => {
  assert.equal(priorVersionTag(".", "nightly", ["v1.0.0"]), null);
});

process.stdout.write("\ncheck-manifest-regression — VALUE, not presence\n");

t("🔴 collectTargets sees every path the manifest names", () => {
  const m = {
    main: "./dist/index.js",
    module: "./dist/index.mjs",
    types: "./dist/index.d.ts",
    bin: { "a-tool": "bin/a.js" },
    exports: { ".": { import: "./dist/i.js", require: "./dist/i.cjs" }, "./sub": "./dist/sub.js" },
  };
  const fields = collectTargets(m).map((x) => x.field);
  assert.ok(fields.includes("main"));
  assert.ok(fields.includes("module"));
  assert.ok(fields.includes("types"));
  assert.ok(fields.includes("bin.a-tool"));
  assert.equal(collectTargets(m).length, 7);
});

t("🔴 AGENT 5's CASE: an exports leaf retargeted to nothing, keys IDENTICAL", () => {
  // diffManifests passes this clean — every key it compares is unchanged. Only
  // looking at the VALUE catches it.
  const before = { version: "1.0.0", exports: { ".": { import: "./dist/i.js" } } };
  const after = { version: "1.0.0", exports: { ".": { import: "./dist/gone.js" } } };
  assert.equal(diffManifests(before, after).ok, true, "key comparison is blind to this");

  const missing = missingTargets(collectTargets(after), ["dist/i.js"]);
  assert.equal(missing.length, 1);
  assert.match(missing[0].target, /gone\.js/);
});

t("🔴 AGENT 5's CASE: main retargeted to a file that is not there", () => {
  const m = { main: "./dist/nope.js" };
  assert.equal(missingTargets(collectTargets(m), ["dist/index.js"]).length, 1);
});

t("🔴 AGENT 5's CASE: files narrowed so the tarball carries no code", () => {
  // The target EXISTS on disk and is absent from the published file list. This
  // is the case that passes an existence check and still ships nothing.
  const m = { main: "./dist/index.js", exports: { ".": "./dist/index.js" } };
  const onDisk = ["dist/index.js", "README.md"];
  const packed = ["README.md"];
  assert.equal(missingTargets(collectTargets(m), onDisk).length, 0, "exists in the tree");
  assert.equal(missingTargets(collectTargets(m), packed).length, 2, "absent from the tarball");
});

t("🟢 CONTROL: targets that exist report nothing", () => {
  const m = { main: "./dist/index.js", exports: { ".": { import: "./dist/index.js" } } };
  assert.equal(missingTargets(collectTargets(m), ["dist/index.js"]).length, 0);
});

t("leading ./ is normalised on both sides, not compared literally", () => {
  assert.equal(missingTargets([{ field: "main", target: "./a.js" }], ["a.js"]).length, 0);
  assert.equal(missingTargets([{ field: "main", target: "a.js" }], ["./a.js"]).length, 0);
});

t("🔴 private: true added is a regression; already-private is not", () => {
  assert.equal(diffManifests({ version: "1.0.0" }, { version: "1.0.0", private: true }).ok, false);
  assert.equal(
    diffManifests({ version: "1.0.0", private: true }, { version: "1.0.0", private: true }).ok,
    true,
    "a package that was always private has not regressed",
  );
});

process.stdout.write(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
