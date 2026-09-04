#!/usr/bin/env node
/**
 * tag-dist-gate — pre-push gate: a `v*` tag may not carry a stale `dist/`.
 *
 * WHY A PRE-PUSH HOOK IS THE RIGHT PLACE
 * --------------------------------------
 * The platform installs packages from git tags, so the moment a `v*` tag
 * reaches the remote it is consumable by every repo — a check that runs later
 * (in a consumer's build) has already lost. git feeds a pre-push hook every ref
 * update on stdin, `refs/tags/v*` included, so this can refuse the tag at the
 * moment of push, before it can be consumed. And it adds no
 * `.github/workflows/` file: hooks are the mechanism the platform migrated TO
 * when it retired GH Actions.
 *
 * ⚑ WHAT IT IS NOT. This is a gate, not a guarantee. `--no-verify` bypasses it,
 * a clone that never ran `npm install` has no hook wired, and a tag created
 * through the GitHub UI or API never touches a local hook at all. It closes the
 * ordinary path. It does not close the deliberate or the remote one, and it
 * should never be described as though it does.
 *
 * SCOPE — TAGS ONLY, DELIBERATELY
 * -------------------------------
 * Ordinary branch pushes pass through untouched, silently and at zero cost.
 * `dist/` staleness only matters at the artifact a consumer installs, and a
 * branch push is not one. Gating every push would add a full install+build×2 to
 * routine work, which is how a hook gets `--no-verify`d within a week — leaving
 * the platform worse off than before it existed.
 *
 * EXIT-CODE DISCIPLINE
 * --------------------
 * Requires exit 0 from `check-dist-fresh`. Exit 1 (STALE) blocks. Exit 2
 * (UNVERIFIED) ALSO blocks — "we could not tell" is not "fine", and a gate that
 * treats it as fine is the shape that let a staleness monitor run green for 245
 * days. There is no blanket `|| true` anywhere in this file.
 *
 * EXEMPTIONS — BY NAME, WITH A REASON, AND NARROW
 * ----------------------------------------------
 * A package that legitimately has no build step or no committed `dist/` returns
 * exit 2 forever. Rather than let 2 mean "fine" globally, such a repo declares
 * an exemption in `.dist-fresh-exempt` at its root:
 *
 *     <package-name>: <written reason>
 *
 * Both halves are required — an entry with no reason is itself an error, so an
 * exemption cannot be added without saying why. Crucially the exemption is
 * NARROW: it covers only `no-build-script` and `no-committed-dist`. A STALE
 * verdict is never exemptable, and neither is a failed build, a failed install
 * or a non-deterministic one. An exemption written for a benign reason must not
 * be able to hide a real one.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECKER = path.join(HERE, "check-dist-fresh.mjs");
const MANIFEST_CHECKER = path.join(HERE, "check-manifest-regression.mjs");
const EXEMPT_FILE = ".dist-fresh-exempt";

/**
 * Extract the `v*` tags from pre-push stdin.
 *
 * git writes one line per ref update: `<local ref> <local sha> <remote ref>
 * <remote sha>`. A DELETION has an all-zero local sha and carries nothing to
 * verify, so it is skipped — refusing to delete a tag would be a gate on the
 * wrong direction.
 *
 * Pure and exported so the parsing is unit-testable without a git push, the
 * same reason `check-tenant-scope-throws` exports `scanSource`.
 */
export function parseTagRefs(stdinText) {
  const tags = [];
  for (const line of String(stdinText || "").split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 4) continue;
    const [localRef, localSha, remoteRef] = parts;
    if (!remoteRef.startsWith("refs/tags/v")) continue;
    if (/^0{40,}$/.test(localSha)) continue; // deletion
    tags.push({ tag: remoteRef.slice("refs/tags/".length), localRef, localSha });
  }
  return tags;
}

/**
 * Parse `.dist-fresh-exempt`. Returns { entries, errors }.
 *
 * A line must be `name: reason`. A name with an empty reason is an ERROR, not
 * an exemption — the whole point is that nobody can silence this without
 * writing down why.
 */
export function parseExemptions(text) {
  const entries = new Map();
  const errors = [];
  for (const raw of String(text || "").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const idx = line.indexOf(":");
    if (idx === -1) {
      errors.push(`malformed (expected '<package>: <reason>'): ${line}`);
      continue;
    }
    const name = line.slice(0, idx).trim();
    const reason = line.slice(idx + 1).trim();
    if (!name) errors.push(`missing package name: ${line}`);
    else if (!reason) errors.push(`exemption for '${name}' has no written reason`);
    else entries.set(name, reason);
  }
  return { entries, errors };
}

/**
 * Decide whether an UNVERIFIED result is covered by an exemption.
 * Narrow by construction: only the two benign reasons are ever exemptable.
 */
export function isExempt({ verdict, reason, packageName, exemptions }) {
  if (verdict !== "UNVERIFIED") return false;
  if (!exemptions.has(packageName)) return false;
  return reason === "no-build-script" || reason === "no-committed-dist";
}

/**
 * The newest `v*` tag STRICTLY BELOW `tag`, or null if this is the first.
 *
 * Exported for the same reason the parsers are: the trap it exists to avoid —
 * a baseline that includes the tag being pushed, making the gate inert — is
 * invisible in a passing run and only catchable by a test.
 */
export function priorVersionTag(root, tag, listTags = null) {
  const tags =
    listTags ??
    (() => {
      const r = spawnSync("git", ["tag", "--list", "v*"], { cwd: root, encoding: "utf8" });
      return r.status === 0 ? r.stdout.split("\n").filter(Boolean) : [];
    })();
  const target = parseV(tag);
  if (!target) return null;
  const below = tags
    .map((t) => ({ tag: t, v: parseV(t) }))
    .filter((x) => x.v && cmpV(x.v, target) < 0);
  if (below.length === 0) return null;
  below.sort((a, b) => cmpV(b.v, a.v));
  return below[0].tag;
}

function parseV(t) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(String(t).trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

function cmpV(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

function main() {
  const root = process.cwd();

  let stdinText = "";
  try {
    stdinText = fs.readFileSync(0, "utf8");
  } catch {
    stdinText = "";
  }

  const tags = parseTagRefs(stdinText);
  if (tags.length === 0) {
    // Ordinary branch push. Untouched, silent, free.
    process.exit(0);
  }

  const pkgPath = path.join(root, "package.json");
  const packageName = fs.existsSync(pkgPath)
    ? (JSON.parse(fs.readFileSync(pkgPath, "utf8")).name ?? path.basename(root))
    : path.basename(root);

  const exemptPath = path.join(root, EXEMPT_FILE);
  const { entries: exemptions, errors: exemptErrors } = parseExemptions(
    fs.existsSync(exemptPath) ? fs.readFileSync(exemptPath, "utf8") : "",
  );
  if (exemptErrors.length) {
    process.stderr.write(
      `[tag-dist-gate] ✗ ${EXEMPT_FILE} is malformed — refusing to push rather than guess:\n` +
        exemptErrors.map((e) => `    ${e}\n`).join(""),
    );
    process.exit(1);
  }

  let failed = 0;
  for (const { tag } of tags) {
    process.stdout.write(`[tag-dist-gate] verifying committed dist/ at ${tag} …\n`);

    const res = spawnSync(process.execPath, [CHECKER, "--root", root, "--ref", tag, "--json"], {
      encoding: "utf8",
    });

    let report = null;
    try {
      report = JSON.parse(res.stdout || "{}");
    } catch {
      report = null;
    }

    if (res.status === 0) {
      process.stdout.write(`[tag-dist-gate]   ✓ ${tag}: dist/ reproduces from src/\n`);
      continue;
    }

    const verdict = report?.verdict ?? (res.status === 1 ? "STALE" : "UNVERIFIED");
    const reason = report?.reason ?? null;

    if (isExempt({ verdict, reason, packageName, exemptions })) {
      process.stdout.write(
        `[tag-dist-gate]   ~ ${tag}: UNVERIFIED (${reason}) — EXEMPT: ${exemptions.get(packageName)}\n`,
      );
      continue;
    }

    failed++;
    if (verdict === "STALE") {
      process.stderr.write(
        `\n[tag-dist-gate] ✗ ${tag} — STALE dist/. This tag would ship output that its own src/ does not build.\n` +
          (report?.changed ?? []).map((f) => `      differs: dist/${f}\n`).join("") +
          (report?.missing ?? []).map((f) => `      committed but not produced: dist/${f}\n`).join("") +
          (report?.extra ?? []).map((f) => `      produced but not committed: dist/${f}\n`).join("") +
          `\n  Every consumer pinning ${tag} would install the committed bytes, not this build.\n` +
          `  Fix:  npm run build && git add dist && git commit --amend  (then re-tag)\n\n`,
      );
    } else {
      process.stderr.write(
        `\n[tag-dist-gate] ✗ ${tag} — UNVERIFIED${reason ? ` (${reason})` : ""}. NOT the same as fine.\n` +
          `  ${(report?.message ?? res.stderr ?? "").trim().split("\n").slice(0, 6).join("\n  ")}\n` +
          `\n  A tag whose dist/ cannot be verified is exactly as unsafe to publish as one\n` +
          `  known to be stale. If this package legitimately has no build step or no\n` +
          `  committed dist/, declare it in ${EXEMPT_FILE} as:\n` +
          `      ${packageName}: <why this package ships no built dist>\n` +
          `  That exemption covers ONLY those two conditions — never a stale or\n` +
          `  unreproducible build.\n\n`,
      );
    }
  }

  // ── Second gate: the manifest must not have gone backwards. ───────────────
  //
  // dist/ reproducing from src/ says NOTHING about this. The 2026-09-04
  // regression (api-client 2.25.0 -> 2.23.0, dual ESM/CJS exports map lost)
  // passed the dist check honestly — both trees were internally correct, and
  // the file deciding which of them a consumer resolves had gone stale
  // underneath. Two questions, two checks.
  for (const { tag } of tags) {
    const baseline = priorVersionTag(root, tag);

    // ⚑ THE INERT-GATE TRAP. At pre-push the tag being pushed ALREADY EXISTS
    // locally, so letting the checker pick "the newest v* tag" would compare
    // the manifest to itself and pass unconditionally — a gate that runs,
    // prints green, and cannot fail. The baseline is always the newest tag
    // STRICTLY BELOW the one being pushed.
    if (!baseline) {
      // A first release has nothing to regress FROM. That is genuinely "no
      // constraint", not "could not tell", and the gate verified it by listing
      // the repo's tags itself. Stated out loud rather than skipped silently.
      process.stdout.write(
        `[tag-dist-gate]   ~ ${tag}: first v* tag — no prior manifest to regress from.\n`,
      );
      continue;
    }

    process.stdout.write(`[tag-dist-gate] verifying manifest at ${tag} vs ${baseline} …\n`);
    const mres = spawnSync(
      process.execPath,
      [MANIFEST_CHECKER, "--root", root, "--against", baseline, "--json"],
      { encoding: "utf8" },
    );

    if (mres.status === 0) {
      process.stdout.write(`[tag-dist-gate]   ✓ ${tag}: manifest is unchanged or wider\n`);
      continue;
    }

    // Requires exit 0. REGRESSION blocks; UNVERIFIED blocks too. There is no
    // exemption for this one — a manifest is not optional the way a build step
    // is, and every package that can be tagged has one.
    failed++;
    let mreport = null;
    try {
      mreport = JSON.parse(mres.stdout || "{}");
    } catch {
      mreport = null;
    }
    const kind = mres.status === 1 ? "REGRESSED" : "UNVERIFIED";
    process.stderr.write(
      `\n[tag-dist-gate] ✗ ${tag} — manifest ${kind} against ${baseline}.\n` +
        (mreport?.problems ?? []).map((pr) => `      ${pr.kind}: ${pr.detail}\n`).join("") +
        (mreport?.problems?.length ? "" : `  ${(mres.stderr || "").trim().split("\n").slice(0, 6).join("\n  ")}\n`) +
        `\n  A consumer resolves this manifest, not the source. The dist/ check above is\n` +
        `  green and correct — it answers a different question.\n\n`,
    );
  }

  if (failed > 0) {
    process.stderr.write(`[tag-dist-gate] refusing to push ${failed} tag(s).\n`);
    process.exit(1);
  }
  process.stdout.write(`[tag-dist-gate] all ${tags.length} tag(s) verified.\n`);
  process.exit(0);
}

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) main();
