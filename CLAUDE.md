# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A metadata/provenance system for the Caras Lab's extracellular electrophysiology
data. It has three parts:

- **`design_docs/schema.sql`** — the canonical PostgreSQL 14+ DDL (schema `lab`).
  This is the single source of truth for the data model; nothing else should
  redefine it.
- **`@CarasLabDB/`** — a MATLAB class-folder wrapper (`CarasLabDB` class) that
  connects to that database and exposes typed insert/retrieve methods for
  every table.
- **`web/lab-dashboard.html`** — a standalone, self-contained HTML/JS
  dashboard (Chart.js via CDN) that visualizes the schema's data model with
  seeded synthetic data (`window.LAB_DATA`, generated in-page by a
  mulberry32 PRNG). It has no backend/API calls — it does not talk to the
  live Postgres database.

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
  `artifact`, and `event_input`. Corrections are made by inserting a new row
  whose `supersedes` column points at the row it replaces. `event_active` /
  `artifact_active` views filter to non-superseded (current) rows; a partial
  unique index on `supersedes` keeps correction chains linear (no forks).
- Two timestamps per event: `occurred_at` (when it happened) vs. `recorded_at`
  (when the row was inserted) — they routinely differ.

Any schema change must preserve this pattern: never add a mutable column
where append + supersede would do, and never let a new detail table skip the
`(event_id, event_type)` composite-FK trick.

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
- All SQL is built by hand and values are escaped via the private static
  `sqlLiteral` helper (quote-doubling, typed casts for `timestamptz`/`jsonb`).
  **Table/column identifiers are always supplied internally, never from
  end-user input** — preserve that invariant in any new method.
- `pSet`/`pIsProvided` implement "omit unset Name=Value args from the INSERT
  so the DB default/NULL applies" — MATLAB's `missing` string / `NaN` / `NaT`
  / `[]` all mean "not provided."
- Event inserts go through `pInsertEvent`, which writes the base `event` row
  and its detail row in one transaction (manual `AutoCommit` toggle +
  commit/rollback), matching the schema's paired base+detail design.
- `supersedeEvent`/`supersedeArtifact` implement the correction workflow:
  read the old row(s), carry every column forward except explicit overrides,
  set `supersedes`, insert as new.

See `examples/carasLabDB_demo.m` for the intended usage flow end-to-end
(connect → reference data → subject/session → recording event → artifact →
analysis event consuming it → retrieval → supersede correction). It's a
walkthrough script, not an automated test, and assumes a reachable database.

## MATLAB coding conventions (enforced, not optional)

- Target **MATLAB R2025a or later**.
- Parse all function inputs with the `arguments` block syntax (Name=Value
  style throughout this codebase).
- R2025a validates `arguments` default values eagerly, so
  `double {mustBeInteger} = NaN` fails even when the argument is omitted —
  use `double {mustBeInteger, mustBeScalarOrEmpty} = []` for optional
  integer scalars (see `NChannels` in multiple files for the pattern).
- Split large methods into their own file under `@CarasLabDB/`, signature
  declared in `CarasLabDB.m`'s `methods` block — do not grow
  `CarasLabDB.m` itself with large method bodies.
- Any official MathWorks toolbox may be assumed available (this project
  relies on Database Toolbox).

## Running things

There is no build/lint/test tooling in this repo (no CI config, no MATLAB
test suite, no package.json). Practical ways to exercise the code:

- **Database schema**: `createdb lab && psql -d lab -f design_docs/schema.sql`
- **MATLAB class**: add the repo root to the MATLAB path (so `@CarasLabDB` is
  visible as a class folder), then adapt `examples/carasLabDB_demo.m` — it
  needs a real reachable Postgres instance with the schema applied.
- **Web dashboard**: static file server, e.g. `python -m http.server 8777
  --directory web` (already configured as the `lab-web` launch config in
  `.claude/launch.json`), then open `http://localhost:8777/lab-dashboard.html`.
  It renders entirely from in-page synthetic data — no server-side changes
  are needed to iterate on it.
