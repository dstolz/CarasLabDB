# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A metadata/provenance system for the Caras Lab's extracellular electrophysiology
data. It has six parts:

- **`design_docs/schema.sql`** — the canonical PostgreSQL 14+ DDL (schema `lab`).
  This is the single source of truth for the data model; nothing else should
  redefine it. It installs the latest schema version; `design_docs/migrations/`
  upgrades existing databases, and `design_docs/grants.sql` holds the roles
  and privileges every deployment guide applies. Current schema version: 5
  (`design_docs/migrations/005_variables_retraction_logins.sql`). It includes
  the tag tables (`tag_namespace`, `tag`, `tag_assignment`), the variable
  tables (`variable`, `variable_value`) and `retraction`;
  `design_docs/tagging.md` and `design_docs/variables.md` are the user-facing
  guides.
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
  artifact with its file's latest `verification`, the tag vocabulary as
  `tagNamespaces`/`tags` and the whole tag log as `tagAssignments`, the
  variable definitions as `variables` and the whole value log as
  `variableValues` (values as text, exactly as stored), and `retractions`.
  Current tags, current variable values and "active" are derived in the
  browser, in the same way as `tag_current`, `variable_current` and the
  `*_active` views. The `integrity` summary is not in `lab_data.sql`: it comes
  from `web/live/lab_integrity.sql`, which `server.py` runs on its own
  5-minute cache and splices into the payload (`server.py --dump` prints the
  full payload). `web/live/lab-dashboard-live.html`
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
  provenance edges, `fn_check_integrity`, and the tag tools `get_tag_namespaces`,
  `get_tags`, `get_entity_tags`, `find_by_tags` plus `tags`/`any_tags`/`none_tags`
  filters on the entity tools). Its one hard invariant is that it cannot write: no write
  tools, every query inside a rolled-back `SET TRANSACTION READ ONLY`
  transaction, and a `SELECT`-only role. No tool accepts a table/column name or
  raw SQL, and every list tool is bounded by `limit` (default 200, max 1000).
  The schema's table and column names are hard-coded — the event-detail
  tables/columns in `src/caraslabdb_mcp/schema_map.py`, the rest in the
  per-tool filter signatures under `src/caraslabdb_mcp/tools/` — so a schema
  change must be mirrored there, and `db.SCHEMA_VERSION` bumped. See
  `design_docs/mcp-server.md`.
- **`tools/`** — Python scripts, cross-platform, standard library only except
  that the verifier needs psycopg: `backup_lab.py` (database + roles +
  manifest, verified, prunes only after success, `--check HOURS` for
  monitoring, `--copy-to` for an off-machine copy), `restore_lab.py` (roles +
  database into a NEW database, checked against the manifest),
  `verify_artifacts.py` (hashes the files under mounted storage roots and
  appends `artifact_verification` rows; needs a login inheriting `lab_rw`).

Read `design_docs/overview.md` first for the conceptual model, then
`design_docs/database-design.md` for the table-by-table rationale — both are
short and are the intended entry point, not just reference material.

**Production target:** a MECM-managed (Microsoft Endpoint Configuration
Manager) Windows 11 machine used as the lab's server;
`design_docs/deployment-windows.md` is the primary deployment guide (Linux and
Synology guides are alternatives). Role model (`grants.sql`): the schema is
owned by a dedicated non-superuser admin role that also applies migrations;
`lab_rw` and `lab_ro` are group roles, never logins; each lab member has
their own login `IN ROLE lab_rw`, and the dashboard and MCP server each have a
login inheriting `lab_ro`. Never document or code a shared `lab_rw` login.

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
  `maintenance_log`, `row_history`, `schema_version`, `tag_assignment`,
  `variable_value` and `retraction`.
  Corrections are made
  by inserting a new row whose `supersedes` column points at the row it
  replaces. `event_active` / `artifact_active` views filter to current rows
  (neither superseded nor retracted); a partial unique index on `supersedes` keeps correction
  chains linear (no forks). An artifact correction may describe the same file
  as the row it replaces (that is how a corrected event's files are
  re-pointed); only one *active* row per file is allowed.
- **Retraction** withdraws an event or artifact entered in error:
  `lab.fn_retract('event'|'artifact', id, reason)` appends a `retraction`
  row; the row stays, leaves the `*_active` views, and superseding it later
  restores it (the successor is active). Not a substitute for a correction.
- The mutable tables (reference, project, `subject`, `session`) are edited in
  place, and the `fn_log_row_change` triggers record every UPDATE/DELETE in
  `row_history`.
- Two timestamps per event: `occurred_at` (when it happened) vs. `recorded_at`
  (when the row was inserted) — they routinely differ.
- **Who wrote a row.** `recorded_by` / `created_by` / `verified_by` /
  `applied_by` / `retracted_by` / `set_by` name a person. The database also
  stamps the login: `event.recorded_login`, `artifact.created_login`,
  `artifact_verification.verified_login`, `tag_assignment.applied_login`,
  `retraction.retracted_login`, `variable_value.set_login` are set to
  `session_user` by the `trg_*_stamp_login` triggers whatever the client
  sends (NULL on rows older than schema version 4). Clients never send them
  and do not carry them forward in a correction. `lab.person.db_login` maps a
  login to a person (`lab.fn_current_person()`); the database fills the
  person column from it when the client names nobody, and the MATLAB class
  uses it to resolve the current person. Only the admin may set `db_login`
  (`grants.sql`). Onboarding = a login `IN ROLE lab_rw` + a person row with
  `db_login`; offboarding = `ALTER ROLE ... NOLOGIN`, never `DROP ROLE` (the
  name is in the log). `lab_rw` cannot change `subject.subject_id`,
  `UPDATE lab.person`, set `db_login`, or `INSERT lab.event_type`.
- **Corrections and the graph.** Provenance edges are immutable, so after a
  correction they still name superseded rows. `fn_artifact_lineage(id, dir,
  follow_corrections := true)` therefore resolves every node to its current
  version by default (`fn_event_current` / `fn_artifact_current`,
  `fn_event_versions` / `fn_artifact_versions`); pass `false` for the rows as
  recorded. `event_version` / `artifact_version` are the full-history views
  with `superseded_by`, `is_current` and `is_retracted`. Verification belongs to the *file*:
  `artifact_verification_latest` gives each artifact row the latest check of
  its (root, path, checksum) across every row describing it, so a correction
  does not lose a failed check. `trg_artifact_matches_event` requires an
  artifact's subject/session to agree with its producing event's.
- **Trigger functions pin `search_path`** (`SET search_path = pg_catalog,
  pg_temp`) and refer to `lab` objects by qualified name. This is a security
  boundary: a subject rename cascades into the append-only tables as their
  owner, and an unpinned trigger function would resolve names with the
  caller's search path. Any new trigger function must do the same
  (`tests/roles_test.sql` asserts it). Checks that are triggers rather than
  constraints (tag policy, one active row per file, acyclic provenance) take
  a transaction-level advisory lock so they hold under concurrent writers.
- **Renaming a subject** is `lab.fn_rename_subject` only. `grants.sql` gives
  `lab_rw` column-level `UPDATE` on `lab.subject` without `subject_id`, and
  `trg_subject_id_guard` refuses the change for any role that may not execute
  that function.
- **Tags** (`namespace:value`, e.g. `stage:raw`; a colon-less *bare* tag is
  stored as `tag:<x>` in the reserved `tag` namespace) follow the same pattern:
  `tag_assignment` is an append-only log of `add`/`remove` rows, and current
  tags are the `tag_current` view (latest row per entity and tag, kept if an
  `add`) — never a mutable "tags" column. The vocabulary (`tag_namespace`
  with its mutability / cardinality / open_vocabulary / applies_to policy, and
  `tag`) is mutable and in `row_history`; a namespace's policy is frozen once
  it is in use. **`lab.fn_tag` is the write path** (it canonicalises,
  auto-registers in open namespaces, and replaces the value of a mutable
  single-valued namespace); `fn_tag_match` is the one definition of filter
  semantics, and `fn_tag_filter_problems` the check every client runs first
  so a mistyped token is an error rather than a silently wrong result.
  "Latest" in `tag_current` is insertion order (`assignment_id`), never
  `applied_at`. **No derived `entity_id` column on `tag_assignment`:** the
  subject-rename hatch in `fn_forbid_mutation` passes only if every column
  except `subject_id` is unchanged under the cascade, so a stored copy of the
  id would make `fn_rename_subject` fail for tagged subjects — `entity_id` is
  computed in the views and functions. A correction does not inherit tags: the
  MATLAB class copies them forward, and `fn_check_integrity` warns
  `tag_not_carried_forward` otherwise.
- **Variables** (user-defined named values, e.g. `probe depth` = 1200 um on
  a session) use the same pattern as tags: mutable definitions (`variable`,
  in `row_history`; name never changes, `value_type` and `units` frozen once
  it has a value) and an append-only value log (`variable_value`, `set` /
  `unset` rows); `variable_current` is the latest value per entity and
  variable, `entity_variables` all of an entity's values as one jsonb object.
  **`lab.fn_set_variable` is the write path** (defines on first use; setting
  again is an update); `fn_unset_variable` clears; `fn_variable_number` /
  `fn_variable_text` read one value inside a query. No stored `entity_id`,
  for the tag reason above. A correction's variables are carried forward **by
  trigger** (`trg_event_carry_variables` / `trg_artifact_carry_variables`),
  not by the client — do not also copy them in MATLAB.
- `lab.fn_check_integrity()` has 13 checks (see `database-design.md` §4.2);
  a new invariant that a constraint cannot enforce gets a check there.

Any schema change must preserve this pattern: never add a mutable column
where append + supersede would do, and never let a new detail table skip the
`(event_id, event_type)` composite-FK trick. A schema change also needs: a new
numbered script in `design_docs/migrations/` that inserts its
`lab.schema_version` row; the same change in `schema.sql` with its seeded
version bumped (a fresh install and an upgraded database must give identical
`pg_dump --schema-only` output — so a column added to an existing table goes
last in its `CREATE TABLE`, where `ALTER TABLE ADD COLUMN` puts it, and a
`SELECT *` view over that table is re-created in the migration);
`CarasLabDB.SchemaVersionExpected` and the MCP server's `db.SCHEMA_VERSION`
bumped; `grants.sql` updated if the new table needs anything beyond
read/insert; assertions in `tests/schema_test.sql`; and, for anything a role
may or may not do, in `tests/roles_test.sql`. Function and view bodies in a
migration must be byte-identical to `schema.sql`.

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
  `PersonName`, or else the person mapped to the login by
  `lab.fn_current_person()`) and auto-populates `created_by`/`recorded_by` on
  inserts unless overridden per call.
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
  and its detail row in one transaction (via `pTransact`), matching the
  schema's paired base+detail design.
- At connection the class sets the session time zone to the workstation's
  zone (unzoned datetimes read back are then local) and reads the schema
  version; a mismatch is an error unless `AllowSchemaMismatch=true`. It warns
  when no current person resolves.
- Tags: `addTag`/`removeTag`/`setTag`/`registerTag`/`addTagNamespace`/
  `getEntityTags`/`findByTags` (own files) and `getTagNamespaces`/`getTags`/
  `updateTagNamespace`/`retireTag` (inline) write through `lab.fn_tag` or the
  vocabulary tables; `Tags=`/`AnyTags=`/`NotTags=` on the `get*` methods call
  `lab.fn_tag_match` via `pTagWhere`. Static `normalizeTag`/`parseTag`/
  `displayTag` mirror `fn_canonical_tag` locally (keep them in step with it);
  the kind-to-(table, pk) map `pTagEntity` is fixed, like the other
  identifiers.
- `pTransact(fn)` runs a multi-statement write as one transaction (manual
  `AutoCommit` toggle + commit/rollback); use it for any new method that writes more than
  one statement. `pInsertEvent`, `supersedeArtifact`, `addArtifact(Supersedes=)`
  and multi-tag `addTag`/`removeTag` go through it. It marks the transaction
  (`SET LOCAL caraslabdb.txn`) and reads the mark back before `COMMIT`: when a
  statement fails, the Database Toolbox rolls back by itself, starts another
  transaction and, for a `fetch`, runs the statement again, so without the
  check a transaction could commit its second half without its first
  (`CarasLabDB:transactionInterrupted`). Never catch a database error inside
  a `pTransact` body and continue.
- Three ways to send SQL, and which to use (see
  `design_docs/matlab-database-toolbox-notes.md`): `pSelect` for a read (it
  drops a trailing semicolon, which would make the driver's `SELECT * FROM
  (...) as temp LIMIT 0` probe a syntax error in the server log); `pWrite`
  for a statement that writes and returns rows (`INSERT`/`UPDATE ...
  RETURNING`, `SELECT lab.fn_...()`), which always runs inside `pTransact`;
  `pExec` for a statement that returns nothing.
  `VariableTests/fetchedWritesAreInTransactionsAndReadsAreBare` checks it.
- `supersedeEvent`/`supersedeArtifact` implement the correction workflow:
  read the old row(s) as exact text (`pRowsAsText`, via
  `jsonb_each_text(to_jsonb(row))`), carry every column forward except
  explicit overrides, set `supersedes`, insert as new. Carried values never
  pass through a MATLAB double or datetime. `supersedeEvent` also copies the
  event's `event_input` edges (unless `CarryInputs=false`) and supersedes each
  active artifact it produced with one pointing at the new event — moved to
  the new subject/session when the correction changes them — all in one
  transaction. `Supersedes=` on an `add*Event` method carries provenance the
  same way. Any insert that sets `supersedes` also copies the predecessor's
  current tags onto the successor (`pCarryTags`), skipping retired tags with
  a warning. The database-stamped `*_login` columns are never carried, and
  variables are not copied by the class (the database's trigger does it).
- Variables: `setVariable(kind, id, name, value, Units=, Label=,
  Description=, Note=)`, `getVariables(kind, id, History=)` and
  `defineVariable` (own files); `unsetVariable`, `getVariableValues(name,
  Kind=)`, `getVariableDefinitions`, `updateVariableDefinition`,
  `retireVariable` (inline). Writes go through `lab.fn_set_variable` /
  `fn_unset_variable` / `fn_define_variable`; static `normalizeVariableName`
  mirrors `fn_canonical_variable`.
- Retraction and housekeeping: `retractEvent(id, reason)` /
  `retractArtifact(id, reason)` (through `lab.fn_retract`), `checkIntegrity()`
  (`lab.fn_check_integrity()`), `addHusbandryBatch(T, OccurredAt=)` (one
  weigh-in sheet in one transaction), `addArtifactFromFile(path,
  ProducedByEventId=, StorageRootId=, RootPath=)` (computes size and SHA-256).
- The GUI (`@CarasLabDBApp`, a programmatic `uifigure` app, not App
  Designer) adds per-row editors for tags (Ctrl+T) and variables (Ctrl+L), a
  retract action (Ctrl+Delete), a daily husbandry entry grid (Ctrl+H) and an
  integrity view (Ctrl+I); Ctrl+? lists the shortcuts. Its settings persist
  through `getpref`/`setpref` (`loadPrefs`/`savePrefs`).

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
- Use `getpref` and `setpref` to store user-specific configuration for all GUIs.
- All GUIs should be efficient and intuitive --- avoid unnecessary clicks.
- All GUIs should include keyboard shortcuts for common actions (e.g., Ctrl+S to save), including Ctrl+? to display a help dialog with the current keyboard shortcuts. Use similar keyboard shortcuts across all GUIs for consistency.
- Use `uidatepicker​` entry fields in the Matlab GUI.

## Running things

CI (`.github/workflows/tests.yml`) runs on PostgreSQL 14, 15, 16 and 17. It
applies the schema, runs `tests/schema_test.sql`, applies `grants.sql` twice
and runs `tests/roles_test.sql` (as members of `lab_rw` / `lab_ro`), checks
that a v1 database plus the migrations matches a fresh install, upgrades a v1
database that holds rows (`tests/seed_v1.sql`,
`tests/migrated_data_test.sql`), runs the artifact verifier end to end
(`tests/check_verify_artifacts.py`), runs `lab_data.sql` and checks the JSON
shape, checks that the live dashboard page is up to date with its generator,
and runs the MCP server's pytest suite. The `matlab` job runs
`tests/matlab/` in MATLAB R2024b, R2025a and the latest release on Linux
(`matlab-actions`, free for a public repository) against a PostgreSQL
service, under Xvfb for the GUI tests; `tests/run_matlab_tests.m` is its
entry point and fails the job if a test fails or a database test did not
run. It does not run on Windows. A separate job parses every MATLAB file
with GNU Octave (`tests/check_matlab_syntax.py`), which is a syntax check and
nothing more -- Octave cannot run this code. There is no package.json. Practical ways
to exercise the code:

- **Database schema**: `createdb lab && psql -d lab -f design_docs/schema.sql`,
  then `psql -X -v ON_ERROR_STOP=1 -d lab -f tests/schema_test.sql` (rolls
  itself back). After `psql -d lab -f design_docs/grants.sql`, run
  `tests/roles_test.sql` the same way, as a superuser (it creates and rolls
  back throw-away logins).
- **Artifact verifier**: `python tools/verify_artifacts.py --root
  <storage_root name>=<mount path>` (connection from the `PG*` environment;
  needs psycopg). It only reads files and appends verification rows.
- **Backup / restore**: as a PostgreSQL superuser, `python
  tools/backup_lab.py -d lab <dir>` (`--check 26` to test freshness,
  `--copy-to <dir>` for a second copy), then `python tools/restore_lab.py
  <dir>/lab_<stamp>.dump lab_restored` (never overwrites; exit 0 when the row
  counts match the manifest).
- **MCP server**: `cd mcp-server && pip install -e .[test] && python -m pytest
  tests` (set `CARASLABDB_TEST_DB` to a scratch database to include the
  integration tests)
- **MATLAB tests**: `runtests("tests/matlab")` — `TagTests` (tags,
  corrections, transactions, the demo script), `VariableTests` (variables,
  retraction, husbandry batch, file registration) and `TagGuiTests` (the
  app's browse filters, tag editor and variables editor, driven with
  `matlab.uitest`). The shared fixture `tests/matlab/LabScratchDb.m`
  creates and drops a scratch `lab_mtest` database; it is opt-in through
  `CARASLABDB_MTEST_ADMIN` (see its help), and without it only the
  database-free tests run. `RecordingConnection` is the fake connection of
  the database-free tests. The GUI tests drive modal windows from a timer
  callback, where `matlab.uitest` does not wait for the app: steps there use
  `typeIn`/`pressOn`/`chooseIn`/`dismissAlert`, not the plain gestures. See
  `design_docs/testing-locally.md` §2.7.
- **MATLAB class**: add the repo root to the MATLAB path (so `@CarasLabDB` is
  visible as a class folder), then adapt `examples/carasLabDB_demo.m` — it
  needs a real reachable Postgres instance with the schema applied.
- **Web dashboard**: static file server, e.g. `python -m http.server 8777
  --directory web` (already configured as the `lab-web` launch config in
  `.claude/launch.json`), then open `http://localhost:8777/lab-dashboard.html`.
  It renders entirely from in-page synthetic data — no server-side changes
  are needed to iterate on it.
