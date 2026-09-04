#!/usr/bin/env node
/**
 * check-dist-fresh — assert that a package's COMMITTED `dist/` is byte-identical
 * to a fresh build of its own `src/`.
 *
 * WHY THIS EXISTS
 * ---------------
 * The platform installs its packages from GIT TAGS
 * (`github:rello-platform/<pkg>#vX.Y.Z`), so the artifact a consumer receives is
 * whatever `dist/` was committed at that tag. Nothing verifies that the
 * committed output was produced by the committed input. A tag can therefore
 * carry `src/` from one commit and `dist/` from an older one, and every
 * consumer installs the stale output with no signal anywhere — not in the
 * package repo, not at install, not at build, not at runtime. The consumer's
 * `tsc` typechecks happily against `dist/*.d.ts`, because the .d.ts is the
 * stale artifact's own honest description of itself.
 *
 * This is NOT "does the build succeed". A build that succeeds and a build that
 * REPRODUCES WHAT IS COMMITTED are different claims, and only the second one
 * says anything about what a consumer will receive.
 *
 * WHAT IT DOES
 * ------------
 *   1. Enumerates the package's tracked files (git), excluding `dist/`.
 *   2. Copies them to a temp dir, installs, and builds — TWICE.
 *   3. Compares the two fresh builds against EACH OTHER first. If they differ,
 *      the toolchain is non-deterministic and the question cannot be answered
 *      by byte-comparison: exit 2 UNVERIFIED, naming the unstable files.
 *      ⚑ This is deliberate. The alternative — normalising until the
 *      comparison passes — converts an unanswerable question into a false
 *      green, which is the failure shape this whole check exists to prevent.
 *      Measured 2026-09-04: `tsc` and `tsup` are both byte-stable across
 *      different absolute build paths, so no normalisation is needed today.
 *   4. Compares the (now-trusted) fresh build against the committed `dist/`.
 *
 * FAIL CLOSED. Every "cannot determine" is exit 2 and says UNVERIFIED — no
 * build script, no committed dist, install failure, build failure, missing git,
 * non-deterministic output. It must never exit 0 on "couldn't build" or "no
 * dist to compare"; that is the shape that let a staleness monitor run green
 * for 245 days.
 *
 * EXIT CODES
 *   0  FRESH       committed dist/ reproduces from committed src/
 *   1  STALE       committed dist/ does NOT match a fresh build
 *   2  UNVERIFIED  the question could not be answered — never a pass
 *
 * USAGE
 *   rello-scripts check-dist-fresh [--root <dir>] [--ref <git-ref>] [--json]
 *
 *   --ref <git-ref>   verify a specific ref (e.g. `v0.10.0`) instead of the
 *                     working tree. This is the form that answers "is this TAG
 *                     safe to consume", which is the question consumers have.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const EXIT_FRESH = 0;
export const EXIT_STALE = 1;
export const EXIT_UNVERIFIED = 2;

// ── Pure comparison core (unit-tested; see test/dist-fresh-cases.mjs) ────────

/**
 * Compare two file trees represented as Map<relativePath, sha256>.
 *
 * Pure and filesystem-free so the classification logic can be pinned by unit
 * tests without building anything — the same reason `check-tenant-scope-throws`
 * exports `scanSource`.
 *
 * `expected` is the committed dist; `actual` is the fresh build.
 *   missing — committed has it, a fresh build does not produce it
 *   extra   — a fresh build produces it, committed does not have it
 *   changed — both have it, contents differ
 */
export function diffTrees(expected, actual) {
  const missing = [];
  const extra = [];
  const changed = [];

  for (const [rel, hash] of expected) {
    if (!actual.has(rel)) missing.push(rel);
    else if (actual.get(rel) !== hash) changed.push(rel);
  }
  for (const rel of actual.keys()) {
    if (!expected.has(rel)) extra.push(rel);
  }

  missing.sort();
  extra.sort();
  changed.sort();
  return { missing, extra, changed, matches: !missing.length && !extra.length && !changed.length };
}

/**
 * Decide the verdict from a diff plus the determinism check.
 *
 * Kept separate from I/O so every branch is reachable in a unit test. A
 * non-deterministic toolchain is UNVERIFIED, never STALE: "the build does not
 * reproduce itself" is a different fact from "the committed output is old", and
 * reporting the second when the first is true sends someone to rebuild a
 * package that will never match.
 */
export function classify({ deterministic, distDiff }) {
  if (!deterministic) return EXIT_UNVERIFIED;
  return distDiff.matches ? EXIT_FRESH : EXIT_STALE;
}

// ── I/O helpers ─────────────────────────────────────────────────────────────

function sha256(file) {
  return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

/** Hash every file under `dir`, keyed by path relative to `dir`. */
export function hashTree(dir) {
  const out = new Map();
  if (!fs.existsSync(dir)) return out;
  const walk = (abs, rel) => {
    for (const entry of fs.readdirSync(abs, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const childAbs = path.join(abs, entry.name);
      const childRel = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(childAbs, childRel);
      else if (entry.isFile()) out.set(childRel, sha256(childAbs));
    }
  };
  walk(dir, "");
  return out;
}

function git(root, args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

/**
 * Machine-readable UNVERIFIED reasons.
 *
 * `tag-dist-gate` needs to tell the two EXEMPTABLE conditions ("this package
 * legitimately has no build step / no committed dist") apart from the ones that
 * must always block ("the build failed", "the output is not reproducible").
 * A single opaque exit 2 would force an exemption to cover all of them, which
 * is how an exemption written for a benign reason ends up hiding a real one.
 */
export const UNVERIFIED_REASONS = {
  NO_BUILD_SCRIPT: "no-build-script",
  NO_COMMITTED_DIST: "no-committed-dist",
  NOT_A_GIT_TREE: "not-a-git-tree",
  NO_PACKAGE_JSON: "no-package-json",
  REF_NOT_FOUND: "ref-not-found",
  ROOT_MISSING: "root-missing",
  EXPORT_FAILED: "export-failed",
  INSTALL_FAILED: "install-failed",
  BUILD_FAILED: "build-failed",
  NON_DETERMINISTIC: "non-deterministic",
  BAD_ARGUMENT: "bad-argument",
  INTERNAL: "internal",
};

/** The only two an exemption may ever cover. Everything else always blocks. */
export const EXEMPTABLE_REASONS = new Set([
  UNVERIFIED_REASONS.NO_BUILD_SCRIPT,
  UNVERIFIED_REASONS.NO_COMMITTED_DIST,
]);

let JSON_MODE = false;

function fail(msg, reason = UNVERIFIED_REASONS.INTERNAL, code = EXIT_UNVERIFIED) {
  if (JSON_MODE) {
    process.stdout.write(
      JSON.stringify({ verdict: "UNVERIFIED", reason, message: msg }, null, 2) + "\n",
    );
  } else {
    process.stderr.write(`${msg}\n`);
  }
  process.exit(code);
}

// ── Main ────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const opts = { root: ".", ref: null, json: false, keepTemp: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root") opts.root = argv[++i];
    else if (a === "--ref") opts.ref = argv[++i];
    else if (a === "--json") opts.json = true;
    else if (a === "--keep-temp") opts.keepTemp = true;
    else if (a === "--help" || a === "-h") opts.help = true;
    else fail(`UNVERIFIED: unknown argument '${a}'.`, UNVERIFIED_REASONS.BAD_ARGUMENT);
  }
  return opts;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(
      "Usage: rello-scripts check-dist-fresh [--root <dir>] [--ref <git-ref>] [--json]\n" +
        "  0 FRESH  1 STALE  2 UNVERIFIED (never a pass)\n",
    );
    process.exit(0);
  }

  JSON_MODE = opts.json;
  const root = path.resolve(process.cwd(), opts.root);
  if (!fs.existsSync(root)) fail(`UNVERIFIED: --root does not exist: ${opts.root}`, UNVERIFIED_REASONS.ROOT_MISSING);

  // git is load-bearing: it defines "tracked", which is what a tag carries.
  try {
    git(root, ["rev-parse", "--is-inside-work-tree"]);
  } catch {
    fail(`UNVERIFIED: not a git work tree: ${root}`, UNVERIFIED_REASONS.NOT_A_GIT_TREE);
  }

  const pkgPath = path.join(root, "package.json");
  if (!fs.existsSync(pkgPath)) fail(`UNVERIFIED: no package.json at ${root}`, UNVERIFIED_REASONS.NO_PACKAGE_JSON);
  const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  const buildScript = pkg.scripts?.build;
  const label = `${pkg.name ?? path.basename(root)}@${pkg.version ?? "?"}`;

  if (!buildScript) {
    fail(
      `UNVERIFIED: ${label} has no "scripts.build" — nothing to reproduce from.`,
      UNVERIFIED_REASONS.NO_BUILD_SCRIPT,
    );
  }

  const ref = opts.ref;
  const treeish = ref ?? "HEAD";
  if (ref) {
    try {
      git(root, ["rev-parse", "--verify", `${ref}^{commit}`]);
    } catch {
      fail(`UNVERIFIED: ref not found: ${ref}`, UNVERIFIED_REASONS.REF_NOT_FOUND);
    }
  }

  // Committed dist at the treeish. `git ls-tree` (not the disk) because the
  // question is about what a CONSUMER receives, and a consumer receives the
  // committed tree, not this working copy.
  let distFiles;
  try {
    distFiles = git(root, ["ls-tree", "-r", "--name-only", treeish, "dist"])
      .split("\n")
      .filter(Boolean);
  } catch {
    distFiles = [];
  }
  if (distFiles.length === 0) {
    fail(
      `UNVERIFIED: ${label} has no committed dist/ at ${treeish} — nothing to compare.\n` +
        `  If this package deliberately builds on install (npm 'prepare'), it is out of scope for this check.\n` +
        `  This is NOT a pass: a missing dist is exactly as unverified as a stale one.`,
      UNVERIFIED_REASONS.NO_COMMITTED_DIST,
    );
  }

  const tmpBase = fs.mkdtempSync(path.join(os.tmpdir(), "dist-fresh-"));
  const cleanup = () => {
    if (!opts.keepTemp) fs.rmSync(tmpBase, { recursive: true, force: true });
  };

  try {
    // Materialise the tree exactly as the tag carries it.
    const srcDir = path.join(tmpBase, "src-tree");
    fs.mkdirSync(srcDir, { recursive: true });
    const archive = spawnSync(
      "bash",
      ["-c", `git archive --format=tar ${JSON.stringify(treeish)} | tar -x -C ${JSON.stringify(srcDir)}`],
      { cwd: root, encoding: "utf8" },
    );
    if (archive.status !== 0) {
      cleanup();
      fail(
        `UNVERIFIED: could not export ${treeish}: ${(archive.stderr || "").trim()}`,
        UNVERIFIED_REASONS.EXPORT_FAILED,
      );
    }

    // The committed dist, straight out of git.
    const committed = new Map();
    for (const rel of distFiles) {
      const content = execFileSync("git", ["show", `${treeish}:${rel}`], {
        cwd: root,
        maxBuffer: 64 * 1024 * 1024,
      });
      committed.set(rel.replace(/^dist\//, ""), createHash("sha256").update(content).digest("hex"));
    }

    // Install once; build twice.
    const hasLock = fs.existsSync(path.join(srcDir, "package-lock.json"));
    const install = spawnSync("npm", [hasLock ? "ci" : "install", "--no-audit", "--no-fund"], {
      cwd: srcDir,
      encoding: "utf8",
    });
    if (install.status !== 0) {
      cleanup();
      fail(
        `UNVERIFIED: dependency install failed for ${label} — cannot build, so cannot compare.\n` +
          `  ${(install.stderr || "").trim().split("\n").slice(-3).join("\n  ")}`,
        UNVERIFIED_REASONS.INSTALL_FAILED,
      );
    }

    const builds = [];
    for (const attempt of [1, 2]) {
      fs.rmSync(path.join(srcDir, "dist"), { recursive: true, force: true });
      const built = spawnSync("npm", ["run", "build"], { cwd: srcDir, encoding: "utf8" });
      if (built.status !== 0) {
        cleanup();
        fail(
          `UNVERIFIED: build failed for ${label} (attempt ${attempt}) — cannot compare.\n` +
            `  ${(built.stderr || built.stdout || "").trim().split("\n").slice(-5).join("\n  ")}`,
          UNVERIFIED_REASONS.BUILD_FAILED,
        );
      }
      builds.push(hashTree(path.join(srcDir, "dist")));
    }

    // Determinism gate. Two builds of identical input must agree before either
    // can be evidence about the committed output.
    const selfDiff = diffTrees(builds[0], builds[1]);
    const deterministic = selfDiff.matches;
    const distDiff = diffTrees(committed, builds[0]);
    const code = classify({ deterministic, distDiff });

    const report = {
      package: pkg.name ?? null,
      version: pkg.version ?? null,
      ref: treeish,
      buildScript,
      committedFiles: committed.size,
      builtFiles: builds[0].size,
      deterministic,
      verdict: code === EXIT_FRESH ? "FRESH" : code === EXIT_STALE ? "STALE" : "UNVERIFIED",
      reason: code === EXIT_UNVERIFIED ? UNVERIFIED_REASONS.NON_DETERMINISTIC : null,
      missing: distDiff.missing,
      extra: distDiff.extra,
      changed: distDiff.changed,
      nonDeterministicFiles: deterministic ? [] : [...selfDiff.changed, ...selfDiff.missing, ...selfDiff.extra].sort(),
    };

    if (opts.json) {
      process.stdout.write(JSON.stringify(report, null, 2) + "\n");
    } else if (!deterministic) {
      process.stderr.write(
        `UNVERIFIED: ${label} does not build reproducibly — two builds of identical input differ.\n` +
          report.nonDeterministicFiles.map((f) => `  unstable: dist/${f}`).join("\n") +
          `\n  Byte-comparison cannot answer the staleness question here. Make the build\n` +
          `  deterministic (or normalise the specific source of variance EXPLICITLY);\n` +
          `  do NOT loosen the comparison until it passes.\n`,
      );
    } else if (code === EXIT_STALE) {
      process.stderr.write(
        `STALE: ${label} committed dist/ at ${treeish} is NOT what its src/ builds.\n` +
          report.changed.map((f) => `  differs: dist/${f}`).join("\n") +
          (report.changed.length ? "\n" : "") +
          report.missing.map((f) => `  committed but not produced: dist/${f}`).join("\n") +
          (report.missing.length ? "\n" : "") +
          report.extra.map((f) => `  produced but not committed: dist/${f}`).join("\n") +
          (report.extra.length ? "\n" : "") +
          `  Every consumer installing this ref receives the committed output, not this build.\n` +
          `  Fix: npm run build && git add dist && commit, then re-tag.\n`,
      );
    } else {
      process.stdout.write(
        `FRESH: ${label} — committed dist/ (${committed.size} files) reproduces byte-identically from src/ at ${treeish}.\n`,
      );
    }

    cleanup();
    process.exit(code);
  } catch (err) {
    cleanup();
    fail(`UNVERIFIED: ${err instanceof Error ? err.message : String(err)}`, UNVERIFIED_REASONS.INTERNAL);
  }
}

// Only run when invoked as a CLI, so the pure helpers can be imported by tests.
const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname);
if (invokedDirectly) main();
