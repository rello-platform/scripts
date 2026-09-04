#!/usr/bin/env node
/**
 * audit-published-tags — verify tags that ALREADY EXIST on the remote.
 *
 * WHY A POST-HOC CHECK, WHEN A HOOK ALREADY EXISTS
 * ------------------------------------------------
 * The pre-push hook is the right gate and it cannot be complete. A hook lives
 * in a working copy, so it can only ever cover working copies someone
 * installed it into. Measured 2026-09-04: four clones of already-gated repos
 * existed on one machine — api-client-pkg, rello-api-client, permissions,
 * Rello-Permissions — each with a full `v*` tag history, no `.husky`, and
 * `core.hooksPath` unset. Same origins as their gated siblings. Nothing about
 * them looked unusual.
 *
 * Three routes reach the remote without touching any local hook:
 *   - a clone nobody remembers making (the four above)
 *   - `git push --no-verify`
 *   - a tag created through the GitHub web UI or API, which never runs a hook
 *     on any machine at all
 *
 * A ruleset can restrict WHO creates a tag. It cannot verify that `dist/`
 * reproduces from `src/`, because that needs a check to RUN, and this platform
 * retired GitHub Actions everywhere except three carve-outs. So prevention
 * cannot be made complete, and the honest remaining move is to detect fast.
 *
 * ⚑ WHAT THIS IS. It fires AFTER the tag lands. That is its accepted cost and
 * it should never be described as prevention. The useful property is that it
 * fires at all, on every route, including the ones no local mechanism reaches.
 *
 * ⚑ AND IT MUST PAGE, NOT LOG. A detector nobody reads is where this whole
 * workstream started: a staleness monitor ran green for 245 days, and a deploy
 * watcher observed nothing for two weeks. `--json` exists so a caller can route
 * findings into a real alarm; the exit code is the contract.
 *
 * WHAT IT CHECKS — the same two gates, deliberately, so a tag cannot pass here
 * and fail at the hook or vice versa:
 *   1. `check-dist-fresh` at the tag: does committed dist/ reproduce from src/?
 *   2. `check-manifest-regression` at the tag against the newest tag STRICTLY
 *      BELOW it: did the manifest go backwards, and does every target exist?
 *
 * SCOPE — newest tag by default. Auditing every tag in history re-builds the
 * package once per tag, which for nine repos is hours and would guarantee this
 * never runs on a schedule. The newest tag is the one consumers pin, and
 * `--since <tag>` covers a backlog when one is wanted.
 *
 * EXIT CODES
 *   0  every audited tag passes both gates
 *   1  at least one published tag FAILS — a bad artifact is live
 *   2  UNVERIFIED — could not determine (no tags, no remote, build unrunnable)
 *
 * USAGE
 *   rello-scripts audit-published-tags [--root <dir>] [--since <tag>] [--json]
 */

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const EXIT_OK = 0;
export const EXIT_BAD_TAG = 1;
export const EXIT_UNVERIFIED = 2;

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DIST_FRESH = path.join(HERE, "check-dist-fresh.mjs");
const TAG_GATE = path.join(HERE, "tag-dist-gate.mjs");
const MANIFEST = path.join(HERE, "check-manifest-regression.mjs");

/** Parse a `v`-prefixed semver tag, or null. */
export function parseTag(t) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(String(t).trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

function cmp(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

/**
 * Which tags to audit, newest first.
 *
 * Exported pure because the SELECTION is where this goes quietly wrong: an
 * off-by-one that audits the tag before the newest would report green about an
 * artifact nobody installs, which is indistinguishable from working.
 */
export function selectTags(allTags, since = null) {
  const parsed = allTags
    .map((t) => ({ tag: t, v: parseTag(t) }))
    .filter((x) => x.v)
    .sort((a, b) => cmp(b.v, a.v));
  if (parsed.length === 0) return [];
  if (!since) return [parsed[0].tag];
  const floor = parseTag(since);
  if (!floor) return [parsed[0].tag];
  return parsed.filter((x) => cmp(x.v, floor) > 0).map((x) => x.tag);
}

/** The newest tag strictly below `tag`, or null — the manifest baseline. */
export function priorTag(allTags, tag) {
  const target = parseTag(tag);
  if (!target) return null;
  const below = allTags
    .map((t) => ({ tag: t, v: parseTag(t) }))
    .filter((x) => x.v && cmp(x.v, target) < 0)
    .sort((a, b) => cmp(b.v, a.v));
  return below.length ? below[0].tag : null;
}

function git(root, args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
}

async function main() {
  const argv = process.argv.slice(2);
  let root = ".";
  let since = null;
  let json = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--root") root = argv[++i];
    else if (argv[i] === "--since") since = argv[++i];
    else if (argv[i] === "--json") json = true;
    else if (argv[i] === "--help" || argv[i] === "-h") {
      process.stdout.write(
        "Usage: rello-scripts audit-published-tags [--root <dir>] [--since <tag>] [--json]\n" +
          "  0 all audited tags pass  1 a published tag FAILS  2 UNVERIFIED\n",
      );
      process.exit(0);
    } else {
      process.stderr.write(`UNVERIFIED: unknown argument '${argv[i]}'.\n`);
      process.exit(EXIT_UNVERIFIED);
    }
  }

  const abs = path.resolve(process.cwd(), root);
  const emit = (o) => process.stdout.write(JSON.stringify(o, null, 2) + "\n");

  if (!fs.existsSync(path.join(abs, ".git"))) {
    const msg = `UNVERIFIED: not a git repository: ${abs}`;
    json ? emit({ verdict: "UNVERIFIED", reason: "not-a-repo", message: msg }) : process.stderr.write(msg + "\n");
    process.exit(EXIT_UNVERIFIED);
  }

  // Audit what the REMOTE has, not what this checkout happens to hold. A local
  // clone can be missing tags entirely, and reporting green on a tag list that
  // is short is the same failure as reporting green on an empty one.
  const fetched = spawnSync("git", ["fetch", "--tags", "--quiet", "origin"], { cwd: abs, encoding: "utf8" });
  if (fetched.status !== 0) {
    const msg = `UNVERIFIED: cannot fetch tags from origin — the local tag list may be incomplete.`;
    json ? emit({ verdict: "UNVERIFIED", reason: "fetch-failed", message: msg }) : process.stderr.write(msg + "\n");
    process.exit(EXIT_UNVERIFIED);
  }

  let tags = [];
  try {
    tags = git(abs, ["tag", "--list", "v*"]).split("\n").filter(Boolean);
  } catch {
    /* handled below */
  }
  const selected = selectTags(tags, since);
  if (selected.length === 0) {
    const msg = `UNVERIFIED: no v* tags to audit in ${abs}. A package with no published tag has no artifact to verify — that is not a pass.`;
    json ? emit({ verdict: "UNVERIFIED", reason: "no-tags", message: msg }) : process.stderr.write(msg + "\n");
    process.exit(EXIT_UNVERIFIED);
  }

  // Same exemption file, same narrow reasons, as tag-dist-gate.
  const { parseExemptions } = await import(TAG_GATE);
  let exemptions = new Map();
  try {
    const raw = fs.readFileSync(path.join(abs, ".dist-fresh-exempt"), "utf8");
    const parsed = parseExemptions(raw);
    // parseExemptions returns { entries: Map, errors: string[] }. A malformed
    // exemption file is an ERROR, not an empty exemption set — an entry with no
    // written reason must not silently become "not exempt", because that turns
    // a configuration mistake into a permanent page.
    if (parsed.errors.length > 0) {
      const msg =
        `UNVERIFIED: .dist-fresh-exempt is malformed and cannot be trusted:\n` +
        parsed.errors.map((e) => `    ${e}\n`).join("");
      json
        ? emit({ verdict: "UNVERIFIED", reason: "exemptions-malformed", message: msg })
        : process.stderr.write(msg);
      process.exit(EXIT_UNVERIFIED);
    }
    exemptions = parsed.entries;
  } catch {
    /* no exemption file is the normal case */
  }
  let pkgName = null;
  try {
    pkgName = JSON.parse(fs.readFileSync(path.join(abs, "package.json"), "utf8")).name ?? null;
  } catch {
    /* reported as UNVERIFIED below if it matters */
  }

  const findings = [];
  for (const tag of selected) {
    const df = spawnSync(process.execPath, [DIST_FRESH, "--root", abs, "--ref", tag, "--json"], {
      encoding: "utf8",
    });
    let dfReport = null;
    try {
      dfReport = JSON.parse(df.stdout || "{}");
    } catch {
      dfReport = null;
    }

    const base = priorTag(tags, tag);
    let mfStatus = 0;
    let mfReport = null;
    if (base) {
      const mf = spawnSync(
        process.execPath,
        [MANIFEST, "--root", abs, "--against", base, "--json"],
        { encoding: "utf8" },
      );
      mfStatus = mf.status ?? 2;
      try {
        mfReport = JSON.parse(mf.stdout || "{}");
      } catch {
        mfReport = null;
      }
    }

    const exemptReason = dfReport?.reason ?? null;
    const exempt =
      df.status === 2 &&
      exemptions.has(pkgName) &&
      (exemptReason === "no-build-script" || exemptReason === "no-committed-dist");

    findings.push({
      tag,
      baseline: base,
      distFresh: {
        exit: df.status,
        verdict: dfReport?.verdict ?? (df.status === 0 ? "OK" : df.status === 1 ? "STALE" : "UNVERIFIED"),
        reason: dfReport?.reason ?? null,
      },
      manifest: base
        ? {
            exit: mfStatus,
            verdict: mfReport?.verdict ?? (mfStatus === 0 ? "OK" : mfStatus === 1 ? "REGRESSION" : "UNVERIFIED"),
            problems: mfReport?.problems ?? [],
          }
        : { exit: 0, verdict: "OK", problems: [], note: "first tag — no baseline to regress from" },
      // A published tag is bad if EITHER gate says so. UNVERIFIED counts as bad
      // here, not as neutral: an artifact that is already live and cannot be
      // verified is exactly as unsafe as one known to be broken.
      exempt,
      // A published tag is bad if EITHER gate says so. UNVERIFIED counts as bad
      // here, not as neutral: an artifact that is already live and cannot be
      // verified is exactly as unsafe as one known to be broken.
      //
      // ⚑ EXCEPT under the SAME narrow exemption the pre-push gate honours.
      // rello-platform-scripts is a CLI of .mjs and .sh files with no build step
      // and no committed dist/, so check-dist-fresh returns UNVERIFIED forever.
      // Without this the detector would page on every run about a repo that is
      // correctly configured — and a detector that always fires is one that gets
      // muted, which is the failure this whole layer exists to avoid. The
      // exemption is read from the SAME .dist-fresh-exempt file and covers the
      // SAME two reasons; a STALE verdict is never exemptable.
      bad: (df.status !== 0 && !exempt) || (base ? mfStatus !== 0 : false),
    });
  }

  const bad = findings.filter((f) => f.bad);

  if (json) {
    emit({
      package: (() => {
        try {
          return JSON.parse(fs.readFileSync(path.join(abs, "package.json"), "utf8")).name ?? null;
        } catch {
          return null;
        }
      })(),
      audited: selected,
      badCount: bad.length,
      verdict: bad.length === 0 ? "OK" : "BAD_TAG_PUBLISHED",
      findings,
    });
  } else if (bad.length === 0) {
    process.stdout.write(
      `[audit-published-tags] OK — ${selected.length} published tag(s) verified: ${selected.join(", ")}\n`,
    );
  } else {
    process.stderr.write(
      `\n[audit-published-tags] ✗ ${bad.length} PUBLISHED tag(s) fail their gates — these are already live:\n` +
        bad
          .map(
            (f) =>
              `    ${f.tag}: dist=${f.distFresh.verdict}${f.distFresh.reason ? ` (${f.distFresh.reason})` : ""}` +
              ` manifest=${f.manifest.verdict}\n` +
              f.manifest.problems.map((p) => `        ${p.kind}: ${p.detail}\n`).join(""),
          )
          .join("") +
        `\n  A pre-push hook cannot have stopped these: they may have come from an ungated\n` +
        `  clone, a --no-verify push, or the GitHub web UI. Consumers pinning them install\n` +
        `  the bad artifact. Re-cut the tag from a verified tree.\n\n`,
    );
  }

  process.exit(bad.length === 0 ? EXIT_OK : EXIT_BAD_TAG);
}

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]).endsWith("audit-published-tags.mjs");
if (invokedDirectly) main();
