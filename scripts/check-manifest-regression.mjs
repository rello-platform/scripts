#!/usr/bin/env node
/**
 * check-manifest-regression — a package's manifest must never go backwards.
 *
 * WHY THIS EXISTS
 * ---------------
 * On 2026-09-04 a rollout script cherry-picked a hook commit onto `origin/main`
 * and, on conflict, fell back to `git checkout <commit> -- package.json`. That
 * commit had been made on a clone BEHIND origin, so a stale manifest was taken
 * wholesale. `@rello-platform/api-client` went from version 2.25.0 back to
 * 2.23.0 and lost the dual ESM/CJS `exports` map that v2.25.0 had shipped for
 * CommonJS consumers.
 *
 * ⚑ THE TAG GATE WAS GREEN THROUGHOUT, HONESTLY. `check-dist-fresh` asks
 * whether the committed `dist/` reproduces from the committed `src/`. It did —
 * both were correct. The manifest that decides which of those files a consumer
 * actually RESOLVES had gone backwards underneath, and that is a different
 * question. A green from one gate says nothing about the other; this is the
 * second gate.
 *
 * No consumer was harmed, only because consumers pin tags and no tag was cut
 * from the bad main. The exposure was entirely forward — the next tag would
 * have shipped it silently.
 *
 * WHAT IT CHECKS, against the last published state (default: the newest v* tag)
 *   1. `version` never DECREASES.
 *   2. No manifest entry point present in the baseline disappears
 *      (`main`, `module`, `types`, `typings`, `browser`, `bin` keys).
 *   3. No `exports` path or condition present in the baseline disappears.
 *
 * ⚑ ABSENCE IS NOT NARROWING. Five of the nine platform packages legitimately
 * ship no `exports` key at all. A baseline without one imposes no constraint,
 * and adding one later is widening, not regression. The check only ever asks
 * whether something the baseline HAD is now gone.
 *
 * FAIL CLOSED — exit 2 UNVERIFIED for "cannot determine": no package.json, no
 * baseline ref, unparseable manifest, no tags to compare against. Never exit 0
 * on "couldn't tell", which is the shape that let a staleness monitor run green
 * for 245 days.
 *
 * EXIT CODES
 *   0  OK          the manifest is unchanged or strictly wider
 *   1  REGRESSION  version went backwards, or something was removed
 *   2  UNVERIFIED  the question could not be answered — never a pass
 *
 * USAGE
 *   rello-scripts check-manifest-regression [--root <dir>] [--against <ref>] [--json]
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export const EXIT_OK = 0;
export const EXIT_REGRESSION = 1;
export const EXIT_UNVERIFIED = 2;

// ── Pure core (unit-tested; see test/manifest-regression-cases.mjs) ──────────

/** Parse a semver-ish version into comparable parts. Returns null if unusable. */
export function parseVersion(v) {
  if (typeof v !== "string") return null;
  const m = /^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(v.trim());
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

/** -1 a<b, 0 equal, 1 a>b, null if either is unparseable. */
export function compareVersions(a, b) {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa || !pb) return null;
  for (let i = 0; i < 3; i++) {
    if (pa[i] !== pb[i]) return pa[i] < pb[i] ? -1 : 1;
  }
  return 0;
}

/**
 * Flatten an `exports` value into the set of resolvable paths.
 *
 * Each leaf becomes `"<subpath> [<condition chain>]"`, so both a removed subpath
 * ("./contracts") and a removed condition ("require" under ".") are visible as a
 * missing member. A string shorthand is the unconditional leaf.
 */
export function flattenExports(exportsValue, subpath = ".", conditions = []) {
  const out = new Set();
  if (exportsValue == null) return out;

  if (typeof exportsValue === "string") {
    out.add(`${subpath} [${conditions.join(">") || "default"}]`);
    return out;
  }
  if (Array.isArray(exportsValue)) {
    // Fallback array — treat as one leaf; losing the whole array is the removal
    // that matters, not which alternative won.
    out.add(`${subpath} [${conditions.join(">") || "default"}]`);
    return out;
  }
  if (typeof exportsValue !== "object") return out;

  for (const [key, value] of Object.entries(exportsValue)) {
    if (key.startsWith(".")) {
      // A subpath key. Only valid at the top level, but tolerate nesting.
      for (const leaf of flattenExports(value, key, conditions)) out.add(leaf);
    } else {
      // A condition key ("import", "require", "types", "default", …).
      for (const leaf of flattenExports(value, subpath, [...conditions, key])) out.add(leaf);
    }
  }
  return out;
}

/** Manifest entry-point fields whose disappearance is a regression. */
const ENTRY_FIELDS = ["main", "module", "types", "typings", "browser"];

/**
 * Compare a baseline manifest to a current one.
 *
 * Pure and filesystem-free so every branch is reachable in a unit test — the
 * same reason check-tenant-scope-throws exports `scanSource`.
 */
export function diffManifests(baseline, current) {
  const problems = [];

  // 1 — version must never decrease.
  const cmp = compareVersions(current.version, baseline.version);
  if (cmp === null) {
    problems.push({
      kind: "version-unparseable",
      detail: `cannot compare versions: baseline="${baseline.version}" current="${current.version}"`,
    });
  } else if (cmp < 0) {
    problems.push({
      kind: "version-decrease",
      detail: `version went BACKWARDS: ${baseline.version} -> ${current.version}`,
    });
  }

  // 2 — an entry point the baseline had must not vanish.
  for (const field of ENTRY_FIELDS) {
    if (baseline[field] != null && current[field] == null) {
      problems.push({
        kind: "entry-removed",
        detail: `"${field}" was "${baseline[field]}" and is now absent`,
      });
    }
  }

  // `bin` keys: losing an executable name breaks callers.
  const binNames = (m) => {
    if (!m.bin) return new Set();
    if (typeof m.bin === "string") return new Set([m.name ?? "<default>"]);
    return new Set(Object.keys(m.bin));
  };
  const baseBins = binNames(baseline);
  const curBins = binNames(current);
  for (const b of baseBins) {
    if (!curBins.has(b)) {
      problems.push({ kind: "bin-removed", detail: `bin "${b}" was present and is now absent` });
    }
  }

  // 3 — exports must not narrow. ABSENCE IN THE BASELINE IS NOT A CONSTRAINT:
  // five of nine platform packages ship no `exports` at all, and adding one is
  // widening. Only leaves the baseline HAD and the current tree lacks count.
  const baseLeaves = flattenExports(baseline.exports);
  const curLeaves = flattenExports(current.exports);
  for (const leaf of baseLeaves) {
    if (!curLeaves.has(leaf)) {
      problems.push({ kind: "exports-narrowed", detail: `exports entry removed: ${leaf}` });
    }
  }

  return { problems, ok: problems.length === 0 };
}

// ── I/O ─────────────────────────────────────────────────────────────────────

function fail(msg, reason) {
  if (JSON_MODE) {
    process.stdout.write(JSON.stringify({ verdict: "UNVERIFIED", reason, message: msg }, null, 2) + "\n");
  } else {
    process.stderr.write(`${msg}\n`);
  }
  process.exit(EXIT_UNVERIFIED);
}

let JSON_MODE = false;

function git(root, args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
}

/** Newest v* tag by semver, or null. */
export function newestVersionTag(tags) {
  const parsed = tags
    .map((t) => ({ tag: t, v: parseVersion(t.replace(/^v/, "")) }))
    .filter((x) => x.v);
  if (parsed.length === 0) return null;
  parsed.sort((a, b) => {
    for (let i = 0; i < 3; i++) if (a.v[i] !== b.v[i]) return b.v[i] - a.v[i];
    return 0;
  });
  return parsed[0].tag;
}

function main() {
  const argv = process.argv.slice(2);
  let root = ".";
  let against = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--root") root = argv[++i];
    else if (argv[i] === "--against") against = argv[++i];
    else if (argv[i] === "--json") JSON_MODE = true;
    else if (argv[i] === "--help" || argv[i] === "-h") {
      process.stdout.write(
        "Usage: rello-scripts check-manifest-regression [--root <dir>] [--against <ref>] [--json]\n" +
          "  0 OK  1 REGRESSION  2 UNVERIFIED (never a pass)\n",
      );
      process.exit(0);
    } else fail(`UNVERIFIED: unknown argument '${argv[i]}'.`, "bad-argument");
  }

  const abs = path.resolve(process.cwd(), root);
  if (!fs.existsSync(abs)) fail(`UNVERIFIED: --root does not exist: ${root}`, "root-missing");

  try {
    git(abs, ["rev-parse", "--is-inside-work-tree"]);
  } catch {
    fail(`UNVERIFIED: not a git work tree: ${abs}`, "not-a-git-tree");
  }

  const pkgPath = path.join(abs, "package.json");
  if (!fs.existsSync(pkgPath)) fail(`UNVERIFIED: no package.json at ${abs}`, "no-package-json");

  let current;
  try {
    current = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  } catch (err) {
    fail(`UNVERIFIED: current package.json is unparseable: ${err.message}`, "current-unparseable");
  }

  // Baseline = the last PUBLISHED state. Consumers install tags, so a tag is
  // what "backwards" is measured against.
  let ref = against;
  if (!ref) {
    let tags = [];
    try {
      tags = git(abs, ["tag", "--list", "v*"]).split("\n").filter(Boolean);
    } catch {
      /* handled below */
    }
    ref = newestVersionTag(tags);
    if (!ref) {
      fail(
        `UNVERIFIED: ${current.name ?? path.basename(abs)} has no v* tag to compare against.\n` +
          `  A package with no published state has no manifest to regress FROM. That is not a\n` +
          `  pass — pass --against <ref> if you know what the baseline should be.`,
        "no-baseline-tag",
      );
    }
  }

  let baseline;
  try {
    baseline = JSON.parse(git(abs, ["show", `${ref}:package.json`]));
  } catch (err) {
    fail(`UNVERIFIED: cannot read package.json at ${ref}: ${err.message}`, "baseline-unreadable");
  }

  const { problems, ok } = diffManifests(baseline, current);
  const label = `${current.name ?? path.basename(abs)}`;

  if (JSON_MODE) {
    process.stdout.write(
      JSON.stringify(
        {
          package: current.name ?? null,
          baselineRef: ref,
          baselineVersion: baseline.version,
          currentVersion: current.version,
          verdict: ok ? "OK" : "REGRESSION",
          problems,
        },
        null,
        2,
      ) + "\n",
    );
  } else if (ok) {
    process.stdout.write(
      `[check:manifest-regression] OK — ${label} ${baseline.version} -> ${current.version} ` +
        `(vs ${ref}); nothing removed or narrowed.\n`,
    );
  } else {
    process.stderr.write(
      `\n[check:manifest-regression] ✗ ${label} manifest REGRESSED against ${ref}:\n` +
        problems.map((p) => `    ${p.kind}: ${p.detail}\n`).join("") +
        `\n  A consumer resolves this manifest, not the source. dist/ reproducing from src/\n` +
        `  says nothing about it — that is a different gate and it will be green.\n` +
        `  If the change is deliberate, bump the version and re-run; if it is a stale\n` +
        `  manifest taken from a clone behind origin, restore it from ${ref}.\n\n`,
    );
  }

  process.exit(ok ? EXIT_OK : EXIT_REGRESSION);
}

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]).endsWith("check-manifest-regression.mjs");
if (invokedDirectly) main();
