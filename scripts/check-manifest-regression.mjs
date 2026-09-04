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
 * ⚑ WHAT "BACKWARDS" MEANS HERE, stated narrowly on purpose. This gate answers
 * two questions and no others: (1) has a KEY the baseline had disappeared, and
 * (2) does every target the manifest names actually EXIST in the tree that
 * ships. It does not police semantics it cannot evaluate — a narrowed `engines`
 * range is a real regression and is deliberately NOT checked, because deciding
 * whether one semver range is narrower than another is a judgement this gate
 * would get wrong quietly. Better an honest gap than a check nobody trusts.
 *
 * WHAT IT CHECKS, against the last published state (default: the newest v* tag)
 *   1. `version` never DECREASES.
 *   2. No manifest entry point present in the baseline disappears
 *      (`main`, `module`, `types`, `typings`, `browser`, `bin` keys).
 *   3. No `exports` path or condition present in the baseline disappears.
 *   4. `private: true` is not newly added — it does not remove a key, and it
 *      stops the package being publishable at all.
 *   5. VALUE, not just presence: every path `main`/`module`/`types`/`browser`/
 *      `bin`/`exports` names must exist. Presence-only comparison passes
 *      `main` retargeted to a file that is not there, and an `exports` leaf
 *      retargeted to nothing with its keys identical — the motivating defect
 *      expressed by value instead of by key.
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

/**
 * Every filesystem target a manifest names, as {field, target} pairs.
 *
 * ⚑ WHY THIS EXISTS SEPARATELY FROM diffManifests. That function compares KEYS:
 * it asks whether something the baseline had is now gone. It never looks at
 * what a key POINTS AT, so `main` retargeted to a file that does not exist, or
 * an exports leaf retargeted to nothing, both pass it clean — the manifest is
 * structurally identical and semantically dead. The 2026-09-04 regression is
 * expressible either way; the gate only spoke one of the two languages.
 */
export function collectTargets(manifest) {
  const out = [];
  for (const field of ENTRY_FIELDS) {
    const v = manifest[field];
    if (typeof v === "string") out.push({ field, target: v });
  }
  if (manifest.bin && typeof manifest.bin === "string") {
    out.push({ field: "bin", target: manifest.bin });
  } else if (manifest.bin && typeof manifest.bin === "object") {
    for (const [name, v] of Object.entries(manifest.bin)) {
      if (typeof v === "string") out.push({ field: `bin.${name}`, target: v });
    }
  }
  for (const leaf of flattenExportsWithTargets(manifest.exports)) out.push(leaf);
  // A relative path is the only kind that names a file in this tree. Bare
  // specifiers and URLs are somebody else's problem by construction.
  return out.filter((t) => t.target.startsWith("./") || !/^[a-z]+:/i.test(t.target));
}

/** Like flattenExports, but keeps the target string alongside the leaf key. */
export function flattenExportsWithTargets(exportsValue, subpath = ".", conditions = []) {
  const out = [];
  if (exportsValue == null) return out;
  if (typeof exportsValue === "string") {
    out.push({ field: `exports["${subpath}"${conditions.length ? ` [${conditions.join(">")}]` : ""}]`, target: exportsValue });
    return out;
  }
  if (Array.isArray(exportsValue)) return out; // fallback array — not a single target
  if (typeof exportsValue !== "object") return out;
  for (const [key, value] of Object.entries(exportsValue)) {
    if (key.startsWith(".")) out.push(...flattenExportsWithTargets(value, key, conditions));
    else out.push(...flattenExportsWithTargets(value, subpath, [...conditions, key]));
  }
  return out;
}

/**
 * Which named targets are missing from `filesPresent`.
 *
 * Pure so the same function serves both questions: "does it exist in the work
 * tree" and "would it be in the published tarball". A target can pass the first
 * and fail the second — `files: ["README.md"]` publishes no code while every
 * path on disk is exactly where the manifest says.
 */
export function missingTargets(targets, filesPresent) {
  const norm = (p) => p.replace(/^\.\//, "").replace(/^\/+/, "");
  const have = new Set([...filesPresent].map(norm));
  return targets.filter((t) => !have.has(norm(t.target)));
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

  // `private: true` on a package that was publishable is a regression by any
  // reading: it does not change a single key's presence, and it stops the
  // package being publishable at all.
  if (!baseline.private && current.private === true) {
    problems.push({
      kind: "private-added",
      detail: '"private": true was added — this package was publishable and is no longer',
    });
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

  const { problems, ok: keysOk } = diffManifests(baseline, current);

  // ── VALUE, not presence ────────────────────────────────────────────────────
  //
  // diffManifests compares KEYS. It cannot see that `main` now points at a file
  // that is not there, or that `files` was narrowed until the tarball carries no
  // code — the manifest is structurally identical and semantically dead. Two
  // questions, asked separately:
  //
  //   (a) does the target exist in the WORK TREE?   — how a git-tag install
  //       resolves, which is how this platform installs @rello-platform/*
  //   (b) would the target be in the PUBLISHED TARBALL? — how a registry
  //       install resolves, which is how rello-ui and Rello-Slugs ship
  //
  // A package can pass (a) and fail (b): `files: ["README.md"]` leaves every
  // path exactly where the manifest says and publishes none of them.
  const targets = collectTargets(current);

  const onDisk = targets.filter((t) => {
    const abs2 = path.resolve(abs, t.target.replace(/^\.\//, ""));
    return fs.existsSync(abs2);
  });
  for (const t of targets) {
    if (!onDisk.includes(t)) {
      problems.push({
        kind: "target-missing",
        detail: `${t.field} points at "${t.target}", which does not exist in the tree`,
      });
    }
  }

  // (b) is only askable when npm can tell us, and only meaningful for a package
  // that is actually published. A failure to run npm pack is UNVERIFIED for that
  // half — never a pass — but it must not mask the (a) result already computed.
  let packedProblems = [];
  let packVerdict = "skipped: private or unpublishable";
  if (current.private !== true) {
    try {
      const out = execFileSync("npm", ["pack", "--dry-run", "--json"], {
        cwd: abs,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        maxBuffer: 32 * 1024 * 1024,
      });
      const parsed = JSON.parse(out);
      const files = (parsed?.[0]?.files ?? []).map((f) => f.path);
      if (files.length === 0) {
        packVerdict = "UNVERIFIED: npm pack reported no files";
      } else {
        packVerdict = `${files.length} files in the tarball`;
        packedProblems = missingTargets(targets, files).map((t) => ({
          kind: "target-not-published",
          detail:
            `${t.field} points at "${t.target}", which EXISTS but is not in the published ` +
            `tarball — check "files"`,
        }));
        problems.push(...packedProblems);
      }
    } catch (err) {
      packVerdict = `UNVERIFIED: npm pack failed (${err instanceof Error ? err.message.split("\n")[0] : String(err)})`;
    }
  }

  const ok = problems.length === 0;
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
          packVerdict,
          targetsChecked: targets.length,
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
