# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A metadata/provenance system for the Caras Lab's extracellular electrophysiology
data. It has five parts:

- **`design_docs/schema.sql`** — the canonical PostgreSQL 14+ DDL (schema `lab`).
  This is the single source of truth for the data model; nothing else should
  redefine it. It installs the latest schema version; `design_docs/migrations/`
  upgrades existing databases, and `design_docs/grants.sql` holds the roles
  and privileges every deployment guide applies.
- **`@CarasLabDB/`** — a MATLAB class-folder wrapper (`CarasLabDB` class) that
  connects to that database and exposes typed insert/retrieve methods for
  every table.
- **`web/lab-dashboard.html`** — a standalone HTML/JS dashboard that
  visualizes the schema's data model with seeded synthetic data
  (`window.LAB_DATA`, generated in-page by a mulberry32 PRNG). It has no
  backend/API calls — it does not talk to the live Postgres database. Its one
  network dependency is Chart.js from a CDN; without it the page shows a
  notice in place of the charts and everything else works. Keep it that way:
  no backend, no other external resources. Timestamps are shown in the
  viewer's time zone (`fmtDate` / `fmtDateTime` / `localDay`).
- **`web/live/`** — a *live* variant of that dashboard. It reuses the exact
  markup and render logic from the offline demo, but a loader fetches
  `/api/data` (served by `web/live/server.py`, which runs `web/live/lab_data.sql`
  against the `lab` schema) and assigns the result to `window.LAB_DATA` instead
  of generating it. The SQL emits the whole `LAB_DATA` shape as one JSON object
  — one array per table, each event with its detail row as `detail`, each
  artifact with its latest `verification`. `web/live/lab-dashboard-live.html`
  is *generated* from the offline demo (swap the synthetic `<script>` for the
  loader, wrap the app IIFE as `window.__initDashboard`); regenerate it if the
  offline demo's app logic changes, rather than editing it by hand. The
  script writes CRLF line endings; the repository stores the file with LF.
  `server.py` serves only the page and `/api/data`, caches the export for 5 s
  and gzips it.
- **`mcp-server/`** — a Python **read-only** Model Context Protocol server
  (`src/caraslabdb_mcp/`) that gives an LLM agent typed `get*` tools mirroring
  `@CarasLabDB`'s read surface (reference tables, subjects/sessions, events and
  their detail rows, artifacts, verifications, `fn_artifact_lineage`,
  provenance edges, `fn_check_integrity`). Its one hard invariant is that it cannot write: no write
  tools, every query inside a rolled-back `SET TRANSACTION READ ONLY`
  transaction, and a `SELECT`-only role. No tool accepts a table/column name or
  raw SQL, and every list tool is bounded by `limit` (default 200, max 1000).
  The schema's table and column names are hard-coded — the event-detail
  tables/columns in `src/caraslabdb_mcp/schema_map.py`, the rest in the
  per-tool filter signatures under `src/caraslabdb_mcp/tools/` — so a schema
  change must be mirrored there, and `db.SCHEMA_VERSION` bumped. See
  `design_docs/mcp-server.md`.

Read `design_docs/overview.md` first for the conceptual model, then
`design_docs/database-design.md` for the table-by-table rationale — both are
short and are the intended entry point, not just reference material.

## Core design: events, not files

The schema is organized around an **append-only event log**, not mutable
records:

- **`event`** is a base table; each of the 8 event types (`birth`, `surgery`,
  `recording`, `behavior`, `husbandry`, `endpoint`, `histology`, `analysis`)
  has its own detail table (class-table inheritance). Type correctness is
  enforced declaratively via `UNIQUE(event_id, event_type)` + a composite FK
  on each detail table — not by trigger.
- **`artifact`** rows are files on the NAS (path + checksum), each pointing at
  the `event` that produced it. **`event_input`** records which artifacts an
  event consumed. Together these form the provenance DAG, walkable via the
  recursive `fn_artifact_lineage(artifact_id, 'up'|'down')` SQL function.
- **Immutability.** `UPDATE`/`DELETE` are blocked by triggers
  (`fn_forbid_mutation()`) on `event`, every `*_event` detail table,
  `artifact`, `event_input`, and the logs `artifact_verification`,
  `maintenance_log`, `row_history` and `schema_version`. Corrections are made
  by inserting a new row whose `supersedes` column points at the row it
  replaces. `event_active` / `artifact_active` views filter to non-superseded
  (current) rows; a partial unique index on `supersedes` keeps correction
  chains linear (no forks). An artifact correction may describe the same file
  as the row it replaces (that is how a corrected event's files are
  re-pointed); only one *active* row per file is allowed.
- The mutable tables (reference, project, `subject`, `session`) are edited in
  place, and the `fn_log_row_change` triggers record every UPDATE/DELETE in
  `row_history`.
- Two timestamps per event: `occurred_at` (when it happened) vs. `recorded_at`
  (when the row was inserted) — they routinely differ.

Any schema change must preserve this pattern: never add a mutable column
where append + supersede would do, and never let a new detail table skip the
`(event_id, event_type)` composite-FK trick. A schema change also needs: a new
numbered script in `design_docs/migrations/` that inserts its
`lab.schema_version` row; the same change in `schema.sql` with its seeded
version bumped (a fresh install and an upgraded database must give identical
`pg_dump --schema-only` output); `CarasLabDB.SchemaVersionExpected` and the MCP
server's `db.SCHEMA_VERSION` bumped; `grants.sql` updated if the new table
needs anything beyond read/insert; and assertions in `tests/schema_test.sql`.

## The MATLAB interface (`@CarasLabDB`)

`CarasLabDB.m` is the class definition; large methods are split into their own
files under `@CarasLabDB/` and declared in the `methods` signature block near
the top of `CarasLabDB.m` (the standard MATLAB class-folder pattern — do not
inline a large method back into `CarasLabDB.m`, and do not add a new large
method without also adding its signature to that block).

Key behaviors baked into the class:

- Connects via the **native `postgresql()`** Database Toolbox interface (no
  ODBC/JDBC config).
- Resolves a **"current person"** at construction (`PersonId`/`PersonEmail`/
  `PersonName`) and auto-populates `created_by`/`recorded_by` on inserts
  unless overridden per call.
- `UseActiveViews` (default `true`) controls whether `get*` methods read
  `*_active` views or full history; overridable per call with `ActiveOnly=`.
- All SQL is built by hand and values are escaped via the static
  `sqlLiteral` helper (quote-doubling, typed casts for `timestamptz`/`jsonb`,
  non-integer numbers as the shortest decimal that round-trips the double,
  timestamps to microseconds).
  **Table/column identifiers are always supplied internally, never from
  end-user input** — preserve that invariant in any new method.
- `pSet`/`pIsProvided` implement "omit unset Name=Value args from the INSERT
  so the DB default/NULL applies" — MATLAB's `missing` string / `NaN` / `NaT`
  / `[]` all mean "not provided."
- Event inserts go through `pInsertEvent`, which writes the base `event` row
  and its detail row in one transaction (manual `AutoCommit` toggle +
  commit/rollback), matching the schema's paired base+detail design.
- At connection the class sets the session time zone to the workstation's
  zone (unzoned datetimes read back are then local) and reads the schema
  version, warning on a mismatch.
- `supersedeEvent`/`supersedeArtifact` implement the correction workflow:
  read the old row(s) as exact text (`pRowsAsText`, via
  `jsonb_each_text(to_jsonb(row))`), carry every column forward except
  explicit overrides, set `supersedes`, insert as new. Carried values never
  pass through a MATLAB double or datetime. `supersedeEvent` also copies the
  event's `event_input` edges and supersedes each active artifact it produced
  with one pointing at the new event, all in one transaction.

See `examples/carasLabDB_demo.m` for the intended usage flow end-to-end
(connect → reference data → subject/session → recording event → artifact →
analysis event consuming it → retrieval → supersede correction). It's a
walkthrough script, not an automated test, and assumes a reachable database.

## MATLAB coding conventions (enforced, not optional)

- Target **MATLAB R2024b or later** (developed on R2025a; the database-free code and GUI were checked on R2024b).
- Parse all function inputs with the `arguments` block syntax (Name=Value
  style throughout this codebase).
- `arguments` default values are validated eagerly (R2024b and later), so
  `double {mustBeInteger} = NaN` fails even when the argument is omitted —
  use `double {mustBeInteger, mustBeScalarOrEmpty} = []` for optional
  integer scalars (see `NChannels` in multiple files for the pattern).
- Split large methods into their own file under `@CarasLabDB/`, signature
  declared in `CarasLabDB.m`'s `methods` block — do not grow
  `CarasLabDB.m` itself with large method bodies.
- Any official MathWorks toolbox may be assumed available (this project
  relies on Database Toolbox).
- Use `getprefs` and `setprefs` to store user-specific configuration for all GUIs.
- All GUIs should be efficient and intuitive --- avoid unnecessary clicks.
- All GUIs should include keyboard shortcuts for common actions (e.g., Ctrl+S to save), including Ctrl+? to display a help dialog with the current keyboard shortcuts. Use similar keyboard shortcuts across all GUIs for consistency.
- Use `uidatepicker​` entry fields in the Matlab GUI.

## Running things

CI (`.github/workflows/tests.yml`) applies the schema to PostgreSQL, runs
`tests/schema_test.sql`, checks that a v1 database plus the migrations matches
a fresh install, runs `lab_data.sql` and checks the JSON shape, checks that the
live dashboard page is up to date with its generator, and runs the MCP
server's pytest suite. There is no MATLAB test suite and no package.json.
Practical ways to exercise the code:

- **Database schema**: `createdb lab && psql -d lab -f design_docs/schema.sql`,
  then `psql -X -v ON_ERROR_STOP=1 -d lab -f tests/schema_test.sql` (rolls
  itself back)
- **MCP server**: `cd mcp-server && pip install -e .[test] && python -m pytest
  tests` (set `CARASLABDB_TEST_DB` to a scratch database to include the
  integration tests)
- **MATLAB class**: add the repo root to the MATLAB path (so `@CarasLabDB` is
  visible as a class folder), then adapt `examples/carasLabDB_demo.m` — it
  needs a real reachable Postgres instance with the schema applied.
- **Web dashboard**: static file server, e.g. `python -m http.server 8777
  --directory web` (already configured as the `lab-web` launch config in
  `.claude/launch.json`), then open `http://localhost:8777/lab-dashboard.html`.
  It renders entirely from in-page synthetic data — no server-side changes
  are needed to iterate on it.
