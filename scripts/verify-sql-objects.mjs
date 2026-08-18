#!/usr/bin/env node
/**
 * verify-sql-objects — assert that every Postgres object declared in
 * prisma/sql/*.sql actually EXISTS in the live database.
 *
 * WHY THIS EXISTS, AND WHY `prisma migrate diff` CANNOT REPLACE IT
 * ----------------------------------------------------------------
 * Prisma's schema describer omits objects it cannot model — predicated
 * (partial) indexes, non-btree access methods (hnsw/gin/gist), triggers,
 * functions, CHECK constraints, cross-schema views. `migrate diff` is
 * therefore structurally blind to this whole class IN BOTH DIRECTIONS: a
 * `prisma/sql/` file that was never applied and one that was applied and
 * later dropped produce BYTE-IDENTICAL diff output ("No difference
 * detected", exit 0). See ~/.claude/standards/db-schema-changes.md
 * § "Partial indexes are INVISIBLE to Prisma".
 *
 * That blindness is not hypothetical. `idx_decision_memory_embedding`
 * (prisma/sql/000_pgvector_setup.sql) — the HNSW index behind Milo's
 * decision-memory vector search — was created, then silently dropped by a
 * later `db push`, and every `migrate diff` after that reported a clean
 * schema. Nothing in the toolchain could see it. This script is the check
 * that can: it reads the declarations out of the files and asks the
 * catalogs directly.
 *
 * It answers a DIFFERENT question from Step 3 of the schema-change ritual.
 * `migrate diff` asks "does the DB match schema.prisma?"; this asks "does
 * the DB contain what prisma/sql/ declares?". Neither replaces the other.
 *
 * WHAT IT DOES
 * ------------
 *   1. Lexes every prisma/sql/*.sql (comment-, string- and dollar-quote
 *      aware, descending into DO $$ … $$ blocks, which is where this repo
 *      puts its ADD CONSTRAINT idempotency guards).
 *   2. Replays the CREATE / DROP / RENAME operations in apply order — the
 *      same filename-glob order db:apply-sql uses — to derive the set of
 *      objects the corpus declares should exist at the end.
 *   3. Queries pg_extension / pg_indexes / pg_views / pg_matviews /
 *      pg_tables / pg_proc / pg_trigger / pg_constraint / pg_type /
 *      pg_sequences / information_schema.columns and reports every declared
 *      object that is absent, with the file:line that declares it.
 *
 * EXIT CODES
 *   0  every declared object is present
 *   1  at least one declared object is MISSING
 *   2  UNVERIFIED — could not connect, or the lexer met DDL it does not
 *      model. Deliberately distinct from 0: an unparsed statement means the
 *      run certified less than it appears to, and a checker that passes on
 *      a database missing a declared object is worse than no checker.
 *
 * USAGE
 *   npm run db:verify-sql-objects
 *   npm run db:verify-sql-objects -- --inventory   # dump everything parsed
 *   npm run db:verify-sql-objects -- --url "postgres://…"
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

// ⚑ THE CONSUMER'S REPO, NOT THIS PACKAGE'S DIRECTORY.
// In Rello this file lived at <repo>/scripts/, so `dirname(import.meta.url)/..`
// WAS the repo root. Packaged, that same expression resolves to
// node_modules/@rello-platform/scripts — it would read the package's own
// (nonexistent) prisma/sql and .env and certify nothing while reporting
// success. The dispatcher spawns every subcommand with cwd = the consumer
// repo, so cwd is the correct root and the only one that travels.
const REPO_ROOT = process.cwd();
const SQL_DIR = join(REPO_ROOT, "prisma", "sql");
const DEFAULT_SCHEMA = "public";

// ─────────────────────────────────────────────────────────────────────────────
// Lexer
//
// Postgres-accurate enough for DDL extraction: line comments, nestable block
// comments, single-quoted literals with '' escapes, double-quoted identifiers
// with "" escapes, and dollar-quoted bodies ($$ … $$ / $tag$ … $tag$).
// Dollar-quoted bodies are emitted VERBATIM so a DO block can be re-lexed.
// ─────────────────────────────────────────────────────────────────────────────

const DOLLAR_TAG = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/;

/**
 * Split SQL text into statements, dropping comments.
 * @returns {{sql: string, line: number}[]} statements with 1-based start lines
 */
function splitStatements(text, startLine = 1) {
  const out = [];
  let buf = "";
  let bufStartLine = startLine;
  let line = startLine;
  let i = 0;
  const n = text.length;

  const append = (str) => {
    if (buf.trim() === "" && str.trim() !== "") bufStartLine = line;
    buf += str;
  };
  const flush = () => {
    if (buf.trim() !== "") out.push({ sql: buf.trim(), line: bufStartLine });
    buf = "";
  };

  while (i < n) {
    const c = text[i];
    const two = text.slice(i, i + 2);

    if (two === "--") {
      while (i < n && text[i] !== "\n") i++;
      continue;
    }

    if (two === "/*") {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (text.slice(i, i + 2) === "/*") { depth++; i += 2; continue; }
        if (text.slice(i, i + 2) === "*/") { depth--; i += 2; continue; }
        if (text[i] === "\n") line++;
        i++;
      }
      continue;
    }

    if (c === "'" || c === '"') {
      const q = c;
      const start = i;
      const startedAt = line;
      i++;
      while (i < n) {
        if (text[i] === q) {
          if (text[i + 1] === q) { i += 2; continue; }
          i++;
          break;
        }
        if (text[i] === "\n") line++;
        i++;
      }
      if (buf.trim() === "") bufStartLine = startedAt;
      buf += text.slice(start, i);
      continue;
    }

    if (c === "$") {
      const m = DOLLAR_TAG.exec(text.slice(i));
      if (m) {
        const tag = m[0];
        const close = text.indexOf(tag, i + tag.length);
        const end = close === -1 ? n : close + tag.length;
        const chunk = text.slice(i, end);
        if (buf.trim() === "") bufStartLine = line;
        buf += chunk;
        for (const ch of chunk) if (ch === "\n") line++;
        i = end;
        continue;
      }
    }

    if (c === ";") {
      flush();
      i++;
      continue;
    }

    if (c === "\n") line++;
    append(c);
    i++;
  }
  flush();
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Identifier helpers
// ─────────────────────────────────────────────────────────────────────────────

const IDENT = String.raw`(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)`;
const QUALIFIED = String.raw`(?:${IDENT}\s*\.\s*)?${IDENT}`;

function unquote(raw) {
  const s = raw.trim();
  if (s.startsWith('"') && s.endsWith('"')) return s.slice(1, -1).replace(/""/g, '"');
  // Postgres folds unquoted identifiers to lower case.
  return s.toLowerCase();
}

/** "public"."Foo" | Foo | public.Foo → {schema, name} */
function parseQualified(raw, fallbackSchema = DEFAULT_SCHEMA) {
  const parts = [];
  let rest = raw.trim();
  const one = new RegExp(`^(${IDENT})\\s*(?:\\.\\s*)?`);
  while (rest) {
    const m = one.exec(rest);
    if (!m) break;
    parts.push(m[1]);
    rest = rest.slice(m[0].length);
    if (!rest.startsWith('"') && !/^[A-Za-z_]/.test(rest)) break;
  }
  if (parts.length >= 2) {
    return { schema: unquote(parts[parts.length - 2]), name: unquote(parts[parts.length - 1]) };
  }
  return { schema: fallbackSchema, name: unquote(parts[0] ?? raw) };
}

/** Split a parenthesised list at depth-1 commas, honouring quotes/dollar-quotes. */
function splitTopLevel(body) {
  const items = [];
  let depth = 0;
  let cur = "";
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === "'" || c === '"') {
      const q = c;
      let j = i + 1;
      while (j < body.length) {
        if (body[j] === q) {
          if (body[j + 1] === q) { j += 2; continue; }
          j++;
          break;
        }
        j++;
      }
      cur += body.slice(i, j);
      i = j - 1;
      continue;
    }
    if (c === "(") depth++;
    if (c === ")") depth--;
    if (c === "," && depth === 0) { items.push(cur); cur = ""; continue; }
    cur += c;
  }
  if (cur.trim()) items.push(cur);
  return items.map((s) => s.trim()).filter(Boolean);
}

/** Extract the outermost (...) group starting at or after `from`. */
function outerParens(str, from = 0) {
  const open = str.indexOf("(", from);
  if (open === -1) return null;
  let depth = 0;
  for (let i = open; i < str.length; i++) {
    const c = str[i];
    if (c === "'" || c === '"') {
      const q = c;
      let j = i + 1;
      while (j < str.length) {
        if (str[j] === q) {
          if (str[j + 1] === q) { j += 2; continue; }
          j++;
          break;
        }
        j++;
      }
      i = j - 1;
      continue;
    }
    if (c === "(") depth++;
    else if (c === ")") {
      depth--;
      if (depth === 0) return { body: str.slice(open + 1, i), start: open, end: i };
    }
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Object keys
//
// Every object gets a stable key so CREATE/DROP/RENAME can be replayed as a
// set. Table-scoped objects (columns, constraints, triggers) are keyed by
// their table, because their names are only unique within it.
// ─────────────────────────────────────────────────────────────────────────────

const keyOf = {
  extension: (o) => `extension:${o.name}`,
  index: (o) => `index:${o.schema}.${o.name}`,
  view: (o) => `view:${o.schema}.${o.name}`,
  table: (o) => `table:${o.schema}.${o.name}`,
  function: (o) => `function:${o.schema}.${o.name}`,
  type: (o) => `type:${o.schema}.${o.name}`,
  sequence: (o) => `sequence:${o.schema}.${o.name}`,
  trigger: (o) => `trigger:${o.schema}.${o.table}.${o.name}`,
  constraint: (o) => `constraint:${o.schema}.${o.table}.${o.name}`,
  column: (o) => `column:${o.schema}.${o.table}.${o.name}`,
  enumvalue: (o) => `enumvalue:${o.schema}.${o.table}.${o.name}`,
};

const describe = (o) =>
  o.table ? `${o.kind} ${o.schema}.${o.table}.${o.name}` : `${o.kind} ${o.schema}.${o.name}`;

// ─────────────────────────────────────────────────────────────────────────────
// Statement classification
//
// Every recognised statement yields zero or more ops: {op:'create'|'drop',
// object} or {op:'rename', from, to}. Anything that looks like DDL but is not
// recognised is returned as an `unparsed` diagnostic and fails the run (exit
// 2) rather than being silently skipped.
// ─────────────────────────────────────────────────────────────────────────────

const re = {
  doBlock: new RegExp(String.raw`^DO\s+(?:LANGUAGE\s+\w+\s+)?(\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$)`, "i"),
  createExtension: new RegExp(String.raw`\bCREATE\s+EXTENSION\s+(?:IF\s+NOT\s+EXISTS\s+)?(${IDENT})`, "gi"),
  createIndex: new RegExp(
    String.raw`\bCREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?(${IDENT})\s+ON\s+(?:ONLY\s+)?(${QUALIFIED})`,
    "gi",
  ),
  createView: new RegExp(
    String.raw`\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:TEMP\s+|TEMPORARY\s+|RECURSIVE\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?(${QUALIFIED})`,
    "gi",
  ),
  createMatView: new RegExp(
    String.raw`\bCREATE\s+MATERIALIZED\s+VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?(${QUALIFIED})`,
    "gi",
  ),
  createTable: new RegExp(
    String.raw`\bCREATE\s+(?:(GLOBAL\s+|LOCAL\s+)?(TEMP|TEMPORARY|UNLOGGED)\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(${QUALIFIED})`,
    "gi",
  ),
  createFunction: new RegExp(
    String.raw`\bCREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(${QUALIFIED})\s*\(`,
    "gi",
  ),
  // NB: `\s` after the name, never `\b` — a quoted identifier ends in `"`, and
  // `" ` is not a word boundary, so `\b` here silently skips every
  // `CREATE TRIGGER "quoted_name" …`. (Same trap as createType above; it is
  // the second time this bit, hence the note on both.) Rello's three triggers
  // are unquoted so the guard, not a wrong answer, is what surfaced it — an
  // unmatched trigger produces no ops and exits 2 UNVERIFIED rather than
  // vanishing from the assertion set.
  createTrigger: new RegExp(
    String.raw`\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\s+(${IDENT})\s[\s\S]*?\bON\s+(${QUALIFIED})`,
    "gi",
  ),
  // NB: no trailing \b — a quoted identifier ends in `"`, and `" ` is not a
  // word boundary, so \b here would silently skip every `CREATE TYPE
  // "public"."Foo" AS ENUM (…)` in the corpus.
  createType: new RegExp(String.raw`\bCREATE\s+TYPE\s+(${QUALIFIED})\s+AS\b`, "gi"),
  // Enum MEMBERS. Postgres has no DROP VALUE, so these are add-only — but they
  // are still droppable by a `db push` that rewrites the type, and they are
  // exactly what Prisma's DSL cannot express when the enum is edited by SQL.
  // Six of these across Harvest-Home / Open-House-Hub / Newsletter-Studio were
  // the ONLY reason those three repos reported UNVERIFIED.
  alterTypeAddValue: new RegExp(
    String.raw`\bALTER\s+TYPE\s+(${QUALIFIED})\s+ADD\s+VALUE\s+(?:IF\s+NOT\s+EXISTS\s+)?'((?:[^']|'')*)'`,
    "gi",
  ),
  createSequence: new RegExp(
    String.raw`\bCREATE\s+(?:TEMP\s+|TEMPORARY\s+)?SEQUENCE\s+(?:IF\s+NOT\s+EXISTS\s+)?(${QUALIFIED})`,
    "gi",
  ),

  dropIndex: new RegExp(String.raw`\bDROP\s+INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+EXISTS\s+)?(${QUALIFIED})`, "gi"),
  dropView: new RegExp(String.raw`\bDROP\s+(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})`, "gi"),
  dropTable: new RegExp(String.raw`\bDROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})`, "gi"),
  dropType: new RegExp(String.raw`\bDROP\s+TYPE\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})`, "gi"),
  dropSequence: new RegExp(String.raw`\bDROP\s+SEQUENCE\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})`, "gi"),
  dropFunction: new RegExp(String.raw`\bDROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})`, "gi"),
  dropTrigger: new RegExp(
    String.raw`\bDROP\s+TRIGGER\s+(?:IF\s+EXISTS\s+)?(${IDENT})\s+ON\s+(${QUALIFIED})`,
    "gi",
  ),
  dropExtension: new RegExp(String.raw`\bDROP\s+EXTENSION\s+(?:IF\s+EXISTS\s+)?(${IDENT})`, "gi"),

  alterTable: new RegExp(String.raw`\bALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?(${QUALIFIED})\s+([\s\S]*)$`, "i"),
  alterIndexRename: new RegExp(
    String.raw`\bALTER\s+INDEX\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})\s+RENAME\s+TO\s+(${IDENT})`,
    "gi",
  ),
  alterViewRename: new RegExp(
    String.raw`\bALTER\s+(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})\s+RENAME\s+TO\s+(${IDENT})`,
    "gi",
  ),
  alterSequenceRename: new RegExp(
    String.raw`\bALTER\s+SEQUENCE\s+(?:IF\s+EXISTS\s+)?(${QUALIFIED})\s+RENAME\s+TO\s+(${IDENT})`,
    "gi",
  ),
  alterTypeRename: new RegExp(
    String.raw`\bALTER\s+TYPE\s+(${QUALIFIED})\s+RENAME\s+TO\s+(${IDENT})`,
    "gi",
  ),
};

// ALTER TABLE actions that neither create nor remove a named object. Anything
// outside this list (and outside the handled set below) is UNPARSED — the
// script refuses to certify a corpus it does not fully understand.
const IGNORABLE_ALTER_ACTIONS = [
  /^ALTER\s+(COLUMN\s+)?/i,
  /^VALIDATE\s+CONSTRAINT\b/i,
  /^OWNER\s+TO\b/i,
  /^SET\s+(SCHEMA|TABLESPACE|LOGGED|UNLOGGED|WITHOUT|WITH|\()/i,
  /^RESET\s*\(/i,
  /^CLUSTER\s+ON\b/i,
  /^SET\s+WITHOUT\s+CLUSTER\b/i,
  /^(ENABLE|DISABLE)\s+(ALWAYS\s+|REPLICA\s+)?(TRIGGER|RULE|ROW\s+LEVEL\s+SECURITY)\b/i,
  /^(NO\s+)?FORCE\s+ROW\s+LEVEL\s+SECURITY\b/i,
  /^INHERIT\b/i,
  /^NO\s+INHERIT\b/i,
  /^ATTACH\s+PARTITION\b/i,
  /^DETACH\s+PARTITION\b/i,
  /^REPLICA\s+IDENTITY\b/i,
];

// Recognised-but-not-an-object DDL, explicitly allowed so it does not read as
// a parser gap. ALTER DEFAULT PRIVILEGES / GRANT govern privileges, not the
// existence of objects; this checker asserts existence only.
const ALLOWED_NON_OBJECT_DDL = [
  /^ALTER\s+DEFAULT\s+PRIVILEGES\b/i,
  /^ALTER\s+SCHEMA\b/i,
  /^ALTER\s+SEQUENCE\s+[\s\S]*\b(OWNED\s+BY|RESTART|START\s+WITH|INCREMENT|MINVALUE|MAXVALUE|CACHE|CYCLE)\b/i,
  /^ALTER\s+FUNCTION\b/i,
  /^ALTER\s+EXTENSION\b/i,
];

// Looks like DDL: used to decide whether an unrecognised statement is a parser
// gap (fail) or ordinary DML/plpgsql (ignore).
const DDL_SHAPED = /\b(CREATE|ALTER|DROP)\s+(TABLE|INDEX|UNIQUE|VIEW|MATERIALIZED|FUNCTION|PROCEDURE|TRIGGER|TYPE|DOMAIN|SEQUENCE|EXTENSION|SCHEMA|POLICY|RULE|AGGREGATE|OPERATOR|COLLATION|SERVER|PUBLICATION|SUBSCRIPTION|CONSTRAINT)\b/i;

function collect(regex, sql, fn) {
  const ops = [];
  regex.lastIndex = 0;
  let m;
  while ((m = regex.exec(sql)) !== null) {
    const r = fn(m);
    if (r) ops.push(...(Array.isArray(r) ? r : [r]));
    if (m.index === regex.lastIndex) regex.lastIndex++;
  }
  return ops;
}

/**
 * Parse the body of a CREATE TABLE into columns + named table constraints.
 */
function parseTableBody(sql, afterNameIdx, schema, table) {
  const grp = outerParens(sql, afterNameIdx);
  if (!grp) return [];
  const ops = [];
  const startsWithConstraintKw =
    /^(PRIMARY\s+KEY|UNIQUE|CHECK|FOREIGN\s+KEY|EXCLUDE|CONSTRAINT|LIKE|INHERITS)\b/i;
  for (const item of splitTopLevel(grp.body)) {
    const named = new RegExp(String.raw`^CONSTRAINT\s+(${IDENT})`, "i").exec(item);
    if (named) {
      ops.push({ op: "create", object: { kind: "constraint", schema, table, name: unquote(named[1]) } });
      continue;
    }
    if (startsWithConstraintKw.test(item)) continue; // system-named table constraint
    const col = new RegExp(String.raw`^(${IDENT})\s`).exec(item);
    if (col) {
      ops.push({ op: "create", object: { kind: "column", schema, table, name: unquote(col[1]) } });
      // Inline named constraint on a column definition.
      const inline = new RegExp(String.raw`\bCONSTRAINT\s+(${IDENT})`, "gi");
      let im;
      while ((im = inline.exec(item)) !== null) {
        ops.push({ op: "create", object: { kind: "constraint", schema, table, name: unquote(im[1]) } });
      }
    }
  }
  return ops;
}

/**
 * Classify one statement. `nested` = inside a DO $$ … $$ body, where the
 * statement may carry a plpgsql control prefix (`IF … THEN ALTER TABLE …`).
 */
function classify(stmt, ctx) {
  const { sql } = stmt;
  const ops = [];

  // DO block: re-lex the dollar-quoted body and classify it in place.
  const doM = re.doBlock.exec(sql);
  if (doM) {
    const tag = doM[1];
    const open = sql.indexOf(tag);
    const close = sql.indexOf(tag, open + tag.length);
    const body = close === -1 ? sql.slice(open + tag.length) : sql.slice(open + tag.length, close);
    const before = sql.slice(0, open + tag.length);
    const bodyStartLine = stmt.line + (before.match(/\n/g)?.length ?? 0);
    for (const inner of splitStatements(body, bodyStartLine)) {
      ops.push(...classify(inner, { ...ctx, nested: true }));
    }
    return ops;
  }

  const at = { file: ctx.file, line: stmt.line, nested: !!ctx.nested };
  const tag = (o) => ({ ...o, ...at });

  // ── CREATE ───────────────────────────────────────────────────────────────
  ops.push(...collect(re.createExtension, sql, (m) => ({
    op: "create",
    object: tag({ kind: "extension", schema: DEFAULT_SCHEMA, name: unquote(m[1]) }),
  })));

  ops.push(...collect(re.createIndex, sql, (m) => {
    const tbl = parseQualified(m[2]);
    // An index lives in its table's schema; CREATE INDEX never qualifies the
    // index name itself.
    return { op: "create", object: tag({ kind: "index", schema: tbl.schema, name: unquote(m[1]), onTable: tbl.name }) };
  }));

  ops.push(...collect(re.createMatView, sql, (m) => {
    const q = parseQualified(m[1]);
    return { op: "create", object: tag({ kind: "view", schema: q.schema, name: q.name, materialized: true }) };
  }));
  ops.push(...collect(re.createView, sql, (m) => {
    if (/\bMATERIALIZED\s+VIEW\b/i.test(m[0])) return null;
    const q = parseQualified(m[1]);
    return { op: "create", object: tag({ kind: "view", schema: q.schema, name: q.name }) };
  }));

  ops.push(...collect(re.createTable, sql, (m) => {
    if (m[2]) return null; // TEMP / UNLOGGED — not a durable declaration
    const q = parseQualified(m[3]);
    const body = parseTableBody(sql, m.index + m[0].length, q.schema, q.name);
    return [
      { op: "create", object: tag({ kind: "table", schema: q.schema, name: q.name }) },
      ...body.map((b) => ({ ...b, object: tag(b.object) })),
    ];
  }));

  ops.push(...collect(re.createFunction, sql, (m) => {
    const q = parseQualified(m[1]);
    return { op: "create", object: tag({ kind: "function", schema: q.schema, name: q.name }) };
  }));

  ops.push(...collect(re.createTrigger, sql, (m) => {
    const t = parseQualified(m[2]);
    return { op: "create", object: tag({ kind: "trigger", schema: t.schema, table: t.name, name: unquote(m[1]) }) };
  }));

  ops.push(...collect(re.createType, sql, (m) => {
    const q = parseQualified(m[1]);
    return { op: "create", object: tag({ kind: "type", schema: q.schema, name: q.name }) };
  }));

  ops.push(...collect(re.alterTypeAddValue, sql, (m) => {
    const q = parseQualified(m[1]);
    return { op: "create", object: tag({ kind: "enumvalue", schema: q.schema, table: q.name, name: m[2].replace(/''/g, "'") }) };
  }));

  ops.push(...collect(re.createSequence, sql, (m) => {
    const q = parseQualified(m[1]);
    return { op: "create", object: tag({ kind: "sequence", schema: q.schema, name: q.name }) };
  }));

  // ── DROP ─────────────────────────────────────────────────────────────────
  const simpleDrop = (regex, kind) =>
    collect(regex, sql, (m) => {
      const q = parseQualified(m[1]);
      return { op: "drop", object: tag({ kind, schema: q.schema, name: q.name }) };
    });

  ops.push(...simpleDrop(re.dropIndex, "index"));
  ops.push(...simpleDrop(re.dropView, "view"));
  ops.push(...simpleDrop(re.dropTable, "table"));
  ops.push(...simpleDrop(re.dropType, "type"));
  ops.push(...simpleDrop(re.dropSequence, "sequence"));
  ops.push(...simpleDrop(re.dropFunction, "function"));
  ops.push(...collect(re.dropExtension, sql, (m) => ({
    op: "drop",
    object: tag({ kind: "extension", schema: DEFAULT_SCHEMA, name: unquote(m[1]) }),
  })));
  ops.push(...collect(re.dropTrigger, sql, (m) => {
    const t = parseQualified(m[2]);
    return { op: "drop", object: tag({ kind: "trigger", schema: t.schema, table: t.name, name: unquote(m[1]) }) };
  }));

  // ── RENAME (non-table objects) ───────────────────────────────────────────
  const renamePair = (regex, kind) =>
    collect(regex, sql, (m) => {
      const from = parseQualified(m[1]);
      return {
        op: "rename",
        from: tag({ kind, schema: from.schema, name: from.name }),
        to: tag({ kind, schema: from.schema, name: unquote(m[2]) }),
      };
    });
  ops.push(...renamePair(re.alterIndexRename, "index"));
  ops.push(...renamePair(re.alterViewRename, "view"));
  ops.push(...renamePair(re.alterSequenceRename, "sequence"));
  ops.push(...renamePair(re.alterTypeRename, "type"));

  // ── ALTER TABLE ──────────────────────────────────────────────────────────
  const alt = re.alterTable.exec(sql);
  if (alt) {
    const q = parseQualified(alt[1]);
    const rest = alt[2].trim();
    const unknown = [];

    // RENAME forms are single-action and cannot be comma-chained.
    let handled = false;
    let m;
    if ((m = new RegExp(String.raw`^RENAME\s+TO\s+(${IDENT})`, "i").exec(rest))) {
      ops.push({
        op: "rename-table",
        from: tag({ kind: "table", schema: q.schema, name: q.name }),
        to: tag({ kind: "table", schema: q.schema, name: unquote(m[1]) }),
      });
      handled = true;
    } else if ((m = new RegExp(String.raw`^RENAME\s+(?:COLUMN\s+)?(${IDENT})\s+TO\s+(${IDENT})`, "i").exec(rest))) {
      ops.push({
        op: "rename",
        from: tag({ kind: "column", schema: q.schema, table: q.name, name: unquote(m[1]) }),
        to: tag({ kind: "column", schema: q.schema, table: q.name, name: unquote(m[2]) }),
      });
      handled = true;
    } else if ((m = new RegExp(String.raw`^RENAME\s+CONSTRAINT\s+(${IDENT})\s+TO\s+(${IDENT})`, "i").exec(rest))) {
      ops.push({
        op: "rename",
        from: tag({ kind: "constraint", schema: q.schema, table: q.name, name: unquote(m[1]) }),
        to: tag({ kind: "constraint", schema: q.schema, table: q.name, name: unquote(m[2]) }),
      });
      handled = true;
    }

    if (!handled) {
      for (const action of splitTopLevel(rest)) {
        let am;
        if ((am = new RegExp(String.raw`^ADD\s+CONSTRAINT\s+(${IDENT})`, "i").exec(action))) {
          ops.push({ op: "create", object: tag({ kind: "constraint", schema: q.schema, table: q.name, name: unquote(am[1]) }) });
        } else if ((am = new RegExp(String.raw`^ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?(${IDENT})`, "i").exec(action))) {
          ops.push({ op: "create", object: tag({ kind: "column", schema: q.schema, table: q.name, name: unquote(am[1]) }) });
        } else if ((am = new RegExp(String.raw`^DROP\s+CONSTRAINT\s+(?:IF\s+EXISTS\s+)?(${IDENT})`, "i").exec(action))) {
          ops.push({ op: "drop", object: tag({ kind: "constraint", schema: q.schema, table: q.name, name: unquote(am[1]) }) });
        } else if ((am = new RegExp(String.raw`^DROP\s+(?:COLUMN\s+)?(?:IF\s+EXISTS\s+)?(${IDENT})`, "i").exec(action))) {
          ops.push({ op: "drop", object: tag({ kind: "column", schema: q.schema, table: q.name, name: unquote(am[1]) }) });
        } else if (/^ADD\s+(PRIMARY\s+KEY|UNIQUE|CHECK|FOREIGN\s+KEY|EXCLUDE)\b/i.test(action)) {
          // system-named — nothing stable to assert
        } else if (!IGNORABLE_ALTER_ACTIONS.some((r) => r.test(action))) {
          unknown.push(action);
        }
      }
    }

    if (unknown.length) {
      return [...ops, { op: "unparsed", at: tag({}), sql: `ALTER TABLE … ${unknown.join(", ")}` }];
    }
    return ops;
  }

  // ── Parser-gap guard ─────────────────────────────────────────────────────
  //
  // A statement that carries object-DDL keywords but yielded no ops is a hole
  // in this parser, not something to skip. Fail the run (exit 2 UNVERIFIED)
  // rather than certify a corpus we only partly understood.
  //
  // Deliberately conservative in one direction: ALLOWED_NON_OBJECT_DDL is
  // anchored at the head, so the same statement wrapped in plpgsql control
  // flow inside a DO block would still be reported. That is the safe way to
  // be wrong — it asks a human to look, rather than quietly dropping an
  // object from the assertion set. No statement in the corpus hits it today.
  if (ops.length === 0 && DDL_SHAPED.test(sql)) {
    const head = sql.replace(/^\(+/, "").trimStart();
    if (!ALLOWED_NON_OBJECT_DDL.some((r) => r.test(head))) {
      return [{ op: "unparsed", at: tag({}), sql: sql.replace(/\s+/g, " ").slice(0, 160) }];
    }
  }

  return ops;
}

// ─────────────────────────────────────────────────────────────────────────────
// Replay: build the declared end-state
// ─────────────────────────────────────────────────────────────────────────────

function buildDeclaredState(files) {
  /** @type {Map<string, object>} */
  const state = new Map();
  const unparsed = [];
  let statementCount = 0;

  for (const file of files) {
    const text = readFileSync(file.path, "utf8");
    const rel = relative(REPO_ROOT, file.path);
    for (const stmt of splitStatements(text)) {
      statementCount++;
      for (const op of classify(stmt, { file: rel })) {
        if (op.op === "unparsed") {
          unparsed.push({ file: rel, line: op.at.line, sql: op.sql });
          continue;
        }
        if (op.op === "create") {
          state.set(keyOf[op.object.kind](op.object), op.object);
          continue;
        }
        if (op.op === "drop") {
          state.delete(keyOf[op.object.kind](op.object));
          continue;
        }
        // A RENAME only RE-KEYS an object the corpus already declares; it never
        // introduces one.
        //
        // This is the line between a declaration and a migration step.
        // `IF NOT EXISTS(x) THEN CREATE x` asserts x must exist afterwards.
        // `IF EXISTS(old) THEN RENAME old TO new` asserts nothing about `new` —
        // it is a one-shot fixup for a legacy state, and when `old` belongs to
        // Prisma rather than to prisma/sql, this corpus has no standing to
        // claim `new` at all.
        //
        // Measured: 017_app_usage_metric_rename_to_app_metric.sql:54 renames
        // CONSTRAINT AppUsageMetric_appId_slug_key → AppMetric_appId_slug_key.
        // Prisma's @@unique emits a unique INDEX, never a CONSTRAINT, so that
        // guard has never fired and never will — prod carries the index and no
        // constraint of that name. Asserting it produced a false MISSING.
        //
        // This cannot soften the case the script exists for: an unconditional
        // CREATE (the HNSW index) is a declaration and is asserted regardless.
        if (op.op === "rename") {
          const fromKey = keyOf[op.from.kind](op.from);
          if (!state.has(fromKey)) continue;
          state.delete(fromKey);
          state.set(keyOf[op.to.kind](op.to), op.to);
          continue;
        }
        if (op.op === "rename-table") {
          // A table rename carries every table-scoped object with it.
          const oldKey = keyOf.table(op.from);
          if (!state.has(oldKey)) continue;
          state.delete(oldKey);
          state.set(keyOf.table(op.to), op.to);
          for (const [k, v] of [...state]) {
            if (v.table === op.from.name && v.schema === op.from.schema) {
              state.delete(k);
              const moved = { ...v, table: op.to.name };
              state.set(keyOf[moved.kind](moved), moved);
            }
          }
        }
      }
    }
  }
  return { state, unparsed, statementCount };
}

// ─────────────────────────────────────────────────────────────────────────────
// Live catalog
// ─────────────────────────────────────────────────────────────────────────────

async function loadLiveCatalog(q, schemas) {
  const live = new Set();
  const add = (k) => live.add(k);

  for (const r of await q(`SELECT extname FROM pg_extension`)) {
    add(`extension:${r.extname}`);
  }
  for (const r of await q(
    `SELECT schemaname, indexname FROM pg_indexes WHERE schemaname = ANY($1::text[])`, [schemas])) {
    add(`index:${r.schemaname}.${r.indexname}`);
  }
  for (const r of await q(
    `SELECT schemaname, viewname AS name FROM pg_views WHERE schemaname = ANY($1::text[])
     UNION ALL
     SELECT schemaname, matviewname AS name FROM pg_matviews WHERE schemaname = ANY($1::text[])`, [schemas])) {
    add(`view:${r.schemaname}.${r.name}`);
  }
  for (const r of await q(
    `SELECT schemaname, tablename FROM pg_tables WHERE schemaname = ANY($1::text[])`, [schemas])) {
    add(`table:${r.schemaname}.${r.tablename}`);
  }
  for (const r of await q(
    `SELECT n.nspname AS schema, p.proname AS name
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = ANY($1::text[])`, [schemas])) {
    add(`function:${r.schema}.${r.name}`);
  }
  for (const r of await q(
    `SELECT n.nspname AS schema, c.relname AS "table", t.tgname AS name
       FROM pg_trigger t
       JOIN pg_class c ON c.oid = t.tgrelid
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE NOT t.tgisinternal AND n.nspname = ANY($1::text[])`, [schemas])) {
    add(`trigger:${r.schema}.${r.table}.${r.name}`);
  }
  for (const r of await q(
    `SELECT n.nspname AS schema, c.relname AS "table", con.conname AS name
       FROM pg_constraint con
       JOIN pg_class c ON c.oid = con.conrelid
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY($1::text[])`, [schemas])) {
    add(`constraint:${r.schema}.${r.table}.${r.name}`);
  }
  for (const r of await q(
    `SELECT n.nspname AS schema, t.typname AS name
       FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = ANY($1::text[])`, [schemas])) {
    add(`type:${r.schema}.${r.name}`);
  }
  for (const r of await q(
    `SELECT schemaname, sequencename FROM pg_sequences WHERE schemaname = ANY($1::text[])`, [schemas])) {
    add(`sequence:${r.schemaname}.${r.sequencename}`);
  }
  for (const r of await q(
    `SELECT table_schema AS schema, table_name AS "table", column_name AS name
       FROM information_schema.columns WHERE table_schema = ANY($1::text[])`, [schemas])) {
    add(`column:${r.schema}.${r.table}.${r.name}`);
  }
  for (const r of await q(
    `SELECT n.nspname AS schema, t.typname AS "type", e.enumlabel AS name
       FROM pg_enum e
       JOIN pg_type t ON t.oid = e.enumtypid
       JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = ANY($1::text[])`, [schemas])) {
    add(`enumvalue:${r.schema}.${r.type}.${r.name}`);
  }
  return live;
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const out = { inventory: false, url: null, json: false, sqlDir: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--inventory") out.inventory = true;
    else if (argv[i] === "--json") out.json = true;
    else if (argv[i] === "--url") out.url = argv[++i];
    // --sql-dir exists so the failure path can be exercised against a scratch
    // database with a scoped corpus. Prod verification always uses the default.
    else if (argv[i] === "--sql-dir") out.sqlDir = argv[++i];
    // ⚑ NEVER SILENTLY IGNORE AN UNRECOGNISED FLAG. Measured 2026-08-18: a
    // survey passed `--sqlDir` (camelCase; the flag is `--sql-dir`). It was
    // dropped without a word, the run fell back to the default directory, and
    // the output compared one repo's declarations against another repo's
    // database — reporting "801 missing" with total confidence. A guard that
    // answers a different question than the one asked is worse than no guard.
    else {
      console.error(`ERROR: unrecognised argument '${argv[i]}'.`);
      console.error(`Usage: rello-scripts verify-sql-objects [--url <conn>] [--sql-dir <dir>] [--inventory] [--json]`);
      process.exit(2);
    }
  }
  return out;
}

function resolveUrl(explicit) {
  if (explicit) return { url: explicit, source: "--url" };
  const envPath = join(REPO_ROOT, ".env");
  if (existsSync(envPath)) {
    // Populate from .env without clobbering a real environment (Railway/CI).
    for (const line of readFileSync(envPath, "utf8").split("\n")) {
      const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
      if (!m) continue;
      let v = m[2].trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      if (process.env[m[1]] === undefined) process.env[m[1]] = v;
    }
  }
  // Prefer the UNPOOLED endpoint: catalog reads through the Neon pooler can be
  // served by a connection with a stale view of very recent DDL.
  if (process.env.DIRECT_URL) return { url: process.env.DIRECT_URL, source: "DIRECT_URL" };
  // Order matters: an unpooled/direct endpoint first, pooled last. The names
  // are not uniform across the platform — measured 2026-08-18, MarketIntel
  // uses DIRECT_DATABASE_URL and The-Oven has only DATABASE_URL. A resolver
  // that knows one name leaves those repos at permanent UNVERIFIED, which
  // reads green forever.
  if (process.env.DIRECT_DATABASE_URL) return { url: process.env.DIRECT_DATABASE_URL, source: "DIRECT_DATABASE_URL" };
  if (process.env.DATABASE_URL) return { url: process.env.DATABASE_URL, source: "DATABASE_URL" };
  return { url: null, source: null };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const sqlDir = args.sqlDir ? resolve(process.cwd(), args.sqlDir) : SQL_DIR;

  if (!existsSync(sqlDir)) {
    console.error(`UNVERIFIED: no SQL directory at ${sqlDir}`);
    process.exit(2);
  }
  const files = readdirSync(sqlDir)
    .filter((f) => f.endsWith(".sql"))
    .sort() // matches the filename-glob order db:apply-sql applies them in
    .map((f) => ({ name: f, path: join(sqlDir, f) }));

  const { state, unparsed, statementCount } = buildDeclaredState(files);
  const declared = [...state.values()];

  const byKind = declared.reduce((acc, o) => ((acc[o.kind] = (acc[o.kind] ?? 0) + 1), acc), {});
  const schemas = [...new Set(declared.map((o) => o.schema))].filter(Boolean);

  console.log(
    `verify-sql-objects — ${files.length} file(s) in ${relative(REPO_ROOT, sqlDir) || sqlDir}, ` +
      `${statementCount} statement(s)`,
  );
  console.log(
    `  declared objects: ${declared.length}  [` +
      Object.entries(byKind).sort().map(([k, v]) => `${k} ${v}`).join(", ") +
      `]`,
  );
  console.log(`  schemas: ${schemas.join(", ")}`);

  if (args.inventory) {
    for (const o of declared.sort((a, b) => describe(a).localeCompare(describe(b)))) {
      console.log(`    ${describe(o).padEnd(76)} ${o.file}:${o.line}${o.nested ? " (DO block)" : ""}`);
    }
  }

  if (unparsed.length) {
    console.error(`\nUNVERIFIED — ${unparsed.length} DDL statement(s) this parser does not model:`);
    for (const u of unparsed) console.error(`  ${u.file}:${u.line}  ${u.sql}`);
    console.error(
      `\nExtend scripts/verify-sql-objects.mjs to cover them. Do NOT relax the guard:\n` +
        `an unmodelled statement means this run certified less than it appears to.`,
    );
    process.exit(2);
  }

  const { url, source } = resolveUrl(args.url);
  if (!url) {
    console.error(`\nUNVERIFIED: no database URL (set DIRECT_URL or DATABASE_URL, or pass --url).`);
    process.exit(2);
  }
  console.log(`  database: ${source} → ${url.replace(/\/\/[^@]*@/, "//***@").split("?")[0]}`);

  let prisma;
  let live;
  try {
    // ⚑ RESOLVE @prisma/client FROM THE CONSUMER REPO, NOT FROM THIS FILE.
    // A bare `import("@prisma/client")` resolves relative to THIS module's
    // path. Packaged under node_modules/@rello-platform/scripts that usually
    // walks up into the consumer's node_modules and happens to work — but it
    // is luck, not design: it breaks under pnpm's isolated layout, under a
    // linked/workspace checkout, and anywhere the package is run by absolute
    // path. Anchoring the require at the consumer's cwd makes it deterministic,
    // and a failure here is UNVERIFIED (exit 2), never a pass.
    const requireFromConsumer = createRequire(join(REPO_ROOT, "package.json"));
    const { PrismaClient } = requireFromConsumer("@prisma/client");
    prisma = new PrismaClient({ datasourceUrl: url, log: [] });
    const q = (sql, params = []) => prisma.$queryRawUnsafe(sql, ...params);
    live = await loadLiveCatalog(q, schemas);
  } catch (err) {
    console.error(`\nUNVERIFIED: could not read the catalogs — ${err?.message ?? err}`);
    process.exit(2);
  } finally {
    await prisma?.$disconnect().catch(() => {});
  }

  const missing = declared.filter((o) => !live.has(keyOf[o.kind](o)));

  if (args.json) {
    console.log(JSON.stringify({ declared: declared.length, missing }, null, 2));
  }

  if (missing.length === 0) {
    console.log(`\n✓ PASS — all ${declared.length} declared object(s) exist in the database.`);
    process.exit(0);
  }

  console.error(`\n✗ FAIL — ${missing.length} declared object(s) MISSING from the database:\n`);
  const order = ["extension", "table", "column", "index", "constraint", "trigger", "function", "view", "type", "enumvalue", "sequence"];
  for (const o of missing.sort(
    (a, b) => order.indexOf(a.kind) - order.indexOf(b.kind) || describe(a).localeCompare(describe(b)),
  )) {
    console.error(`  MISSING  ${describe(o)}`);
    console.error(`           declared at ${o.file}:${o.line}${o.nested ? " (inside a DO block)" : ""}`);
  }
  console.error(
    `\nThese objects are invisible to \`prisma migrate diff\` — a clean diff is not\n` +
      `evidence they exist. Re-apply with \`npm run db:apply-sql\`, or restore the\n` +
      `object with direct DDL, then re-run this check.`,
  );
  process.exit(1);
}

main().catch((err) => {
  console.error(`UNVERIFIED: ${err?.stack ?? err}`);
  process.exit(2);
});
