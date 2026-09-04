#!/usr/bin/env node
/**
 * check-explicit-apikey — count RelloClient construction sites that rely on the
 * implicit `RELLO_API_KEY` fallback.
 *
 * WHY A STATIC SCAN IS THE AUTHORITATIVE NUMBER
 * ---------------------------------------------
 * `@rello-platform/api-client` falls back to the `RELLO_API_KEY` env var when a
 * caller does not pass `apiKey`. That does not make a MISSING key silent — the
 * constructor already throws when nothing resolves. It makes a WRONG key silent:
 * a spoke that means to use its own `<SPOKE>_TO_RELLO_API_KEY` and forgets to
 * pass it authenticates as whatever `RELLO_API_KEY` holds, constructs
 * identically, and fails later as a 401 in a different file.
 *
 * v2.26.0 warns at runtime with the construction site attached, and exposes
 * `getImplicitApiKeyUses()`. But a `console.warn` in a Trigger.dev worker goes
 * where nobody reads — this platform has been bitten by that exact shape. The
 * number that actually shrinks has to come from somewhere that does not depend
 * on a log being read, or on the code path even running.
 *
 * Construction sites are statically visible. That is how "24 of 34 across 5
 * repos" was measured before any of this shipped, and this is that measurement,
 * made repeatable and greppable. The runtime half still earns its place: it
 * catches a client built from a factory or a runtime-assembled config, which a
 * scanner cannot see.
 *
 * ⚑ WHAT THIS CANNOT SEE, stated because a clean number would otherwise
 * mislead: a client constructed from a config object assembled elsewhere
 * (`new RelloClient(cfg)`) is reported as IMPLICIT if `apiKey` does not appear
 * near the call, even when `cfg` carries one. That is deliberate — the error
 * points at the safe side, and an over-count shrinks when the site is made
 * explicit at the call. Cross-check a surprising finding against the runtime
 * `getImplicitApiKeyUses()` before treating it as real.
 *
 * EXIT CODES
 *   0  every construction site passes apiKey explicitly
 *   1  at least one site relies on the implicit fallback
 *   2  UNVERIFIED — nothing scanned, or the source root is missing
 *
 * USAGE
 *   rello-scripts check-explicit-apikey [--root <dir>] [--json]
 */

import fs from "node:fs";
import path from "node:path";

export const EXIT_OK = 0;
export const EXIT_IMPLICIT = 1;
export const EXIT_UNVERIFIED = 2;

/** How many lines after the call to look for `apiKey` in the config literal. */
const CONFIG_WINDOW = 10;

/** The package whose construction sites we are counting. */
const PACKAGE = "@rello-platform/api-client";

/** The two exported constructors. Either may be imported under an alias. */
const EXPORTED_CTORS = ["RelloClient", "createRelloClient"];

/**
 * Resolve the LOCAL names bound to the package's constructors in this file.
 *
 * ⚑ WHY NAME-MATCHING IS NOT ENOUGH, and it is not a hypothetical: MarketIntel
 * imports `createRelloClient as createSharedClient` and then declares its OWN
 * `export function createRelloClient(...)` wrapper. HomeReady declares a local
 * `class RelloClient`. A scanner keyed on the bare name counted 12 calls to
 * MarketIntel's local factory and one call to a class that has nothing to do
 * with this package — inflating both halves of the fraction with sites that
 * cannot possibly use the RELLO_API_KEY fallback.
 *
 * Returns [] when the file does not import the package at all, which is the
 * common case and makes the scan cheap.
 */
export function importedCtorNames(src) {
  const names = [];
  // `import { a, b as c } from "@rello-platform/api-client"` — including the
  // multi-line form every one of these files actually uses.
  const re = new RegExp(
    String.raw`import\s*(?:type\s+)?\{([^}]*)\}\s*from\s*['"]` +
      PACKAGE.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") +
      String.raw`['"]`,
    "g",
  );
  let m;
  while ((m = re.exec(src))) {
    for (const clause of m[1].split(",")) {
      const c = clause.trim().replace(/^type\s+/, "");
      if (!c) continue;
      const [imported, local] = c.split(/\s+as\s+/).map((x) => x.trim());
      if (EXPORTED_CTORS.includes(imported)) names.push(local || imported);
    }
  }
  return [...new Set(names)];
}

/**
 * Scan one file's source for RelloClient construction sites.
 *
 * Exported pure so the scan logic is unit-testable without a filesystem walk —
 * the same reason check-tenant-scope-throws exports `scanSource`.
 */
export function scanSource(file, src) {
  const findings = [];

  // Only identifiers actually bound to the package's constructors count.
  const ctors = importedCtorNames(src);
  if (ctors.length === 0) return findings;
  const alt = ctors.map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  const CONSTRUCTION = new RegExp(String.raw`(?:new\s+(?:${alt})|\b(?:${alt}))\s*\(`);

  const lines = src.split("\n");
  let inBlockComment = false;

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const t = raw.trim();

    if (inBlockComment) {
      if (t.includes("*/")) inBlockComment = false;
      continue;
    }
    if (t.startsWith("/*")) {
      if (!t.includes("*/")) inBlockComment = true;
      continue;
    }
    // Prose legitimately quotes the pattern to explain it. Counting prose was
    // this class of guard's own first bug, twice.
    if (t.startsWith("//") || t.startsWith("*")) continue;

    if (!CONSTRUCTION.test(raw)) continue;

    // Strip comment lines from the window BEFORE looking for the property.
    // Three spokes carry comments that literally say "pass apiKey explicitly",
    // and a naive substring match reads those as the property being present —
    // the comments this workstream exists to remove would have hidden the very
    // sites it is counting.
    const window = lines
      .slice(i, i + CONFIG_WINDOW + 1)
      .map((l) => l.replace(/\/\/.*$/, ""))
      .filter((l) => {
        const s = l.trim();
        return !s.startsWith("*") && !s.startsWith("/*");
      })
      .join("\n");
    // Both forms count: `apiKey: value` and the ES6 shorthand `apiKey,` / `apiKey }`.
    // Requiring a colon was this scanner's own first bug — it reported
    // The-Home-Scout's correctly-explicit shorthand site as implicit.
    const explicit = /\bapiKey\s*(?::|,|\})/.test(window);
    findings.push({ file, line: i + 1, explicit, text: t.slice(0, 100) });
  }
  return findings;
}

function walk(dir, acc = []) {
  if (!fs.existsSync(dir)) return acc;
  for (const entry of fs.readdirSync(dir)) {
    if (entry === "node_modules" || entry === ".next" || entry === "dist" || entry === ".git") continue;
    const abs = path.join(dir, entry);
    const st = fs.statSync(abs);
    if (st.isDirectory()) walk(abs, acc);
    else if (/\.tsx?$/.test(entry) && !/\.test\.tsx?$/.test(entry)) acc.push(abs);
  }
  return acc;
}

function main() {
  const argv = process.argv.slice(2);
  let root = ".";
  let json = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--root") root = argv[++i];
    else if (argv[i] === "--json") json = true;
    else if (argv[i] === "--help" || argv[i] === "-h") {
      process.stdout.write(
        "Usage: rello-scripts check-explicit-apikey [--root <dir>] [--json]\n" +
          "  0 all explicit  1 implicit sites remain  2 UNVERIFIED\n",
      );
      process.exit(0);
    } else {
      process.stderr.write(`UNVERIFIED: unknown argument '${argv[i]}'.\n`);
      process.exit(EXIT_UNVERIFIED);
    }
  }

  const abs = path.resolve(process.cwd(), root);
  const srcDir = fs.existsSync(path.join(abs, "src")) ? path.join(abs, "src") : abs;
  if (!fs.existsSync(srcDir)) {
    process.stderr.write(`UNVERIFIED: no source directory at ${srcDir}\n`);
    process.exit(EXIT_UNVERIFIED);
  }

  const files = walk(srcDir);
  if (files.length === 0) {
    // A guard that examined nothing must not report green.
    process.stderr.write(`UNVERIFIED: scanned 0 source files under ${srcDir}\n`);
    process.exit(EXIT_UNVERIFIED);
  }

  const findings = [];
  for (const f of files) findings.push(...scanSource(path.relative(abs, f), fs.readFileSync(f, "utf8")));

  const implicit = findings.filter((f) => !f.explicit);
  const total = findings.length;

  if (json) {
    process.stdout.write(
      JSON.stringify(
        { root: abs, totalSites: total, implicitSites: implicit.length, implicit },
        null,
        2,
      ) + "\n",
    );
  } else if (total === 0) {
    process.stdout.write(`[check:explicit-apikey] no RelloClient construction sites under ${srcDir}.\n`);
  } else if (implicit.length === 0) {
    process.stdout.write(
      `[check:explicit-apikey] OK — all ${total} construction site(s) pass apiKey explicitly.\n`,
    );
  } else {
    process.stderr.write(
      `\n[check:explicit-apikey] ${implicit.length} of ${total} construction site(s) rely on the implicit RELLO_API_KEY fallback:\n` +
        implicit.map((f) => `    ${f.file}:${f.line}\n`).join("") +
        `\n  Each silently authenticates as whatever RELLO_API_KEY holds. Pass the key this\n` +
        `  caller actually intends, then set requireExplicitApiKey: true so it cannot regress.\n` +
        `  The fallback is removed in api-client v3.0.0.\n\n`,
    );
  }

  process.exit(implicit.length === 0 ? EXIT_OK : EXIT_IMPLICIT);
}

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]).endsWith("check-explicit-apikey.mjs");
if (invokedDirectly) main();
