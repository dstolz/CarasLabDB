# CarasLabDB

A metadata and provenance system for the Caras Lab's extracellular
electrophysiology data. It records **what happened** in the lab — births,
surgeries, recordings, behavior, analyses — as an append-only event log, and
treats the files on the NAS as *artifacts* produced by those events. The raw and
derived data are never the source of truth about an experiment; the event log
is.

## Why an event log instead of files?

- **Provenance.** Every derived file traces back through the analysis that
  produced it, its inputs, and the recording and subject it came from — a
  walkable directed acyclic graph (`event → artifact → analysis → artifact`).
- **Reproducibility.** Analysis events carry the pipeline name, code version,
  parameters, and input artifacts needed to rerun them.
- **Auditability.** Events are immutable. `UPDATE`/`DELETE` are blocked by
  database triggers; mistakes are corrected by appending a *superseding* event
  that points at the row it replaces, and a row entered in error is
  *retracted* (withdrawn with a reason) rather than deleted. History is
  retained; queries filter to the active version. The database records which
  login wrote every row.

A file being renamed, moved, or re-derived does not change what happened in the
lab. Separating the two makes provenance tractable and makes reruns a matter of
reading an analysis event rather than reverse-engineering a folder.

## Components

| Component | Role |
|---|---|
| `design_docs/schema.sql` | Canonical PostgreSQL 14+ DDL (schema `lab`) — the single source of truth for the data model |
| `@CarasLabDB/` | MATLAB class wrapping the database with typed insert/retrieve helpers for every table |
| `@CarasLabDBApp/` | MATLAB GUI (programmatic `uifigure` app) for interactive metadata entry and browsing |
| `web/lab-dashboard.html` | Standalone HTML/JS dashboard visualizing the data model with seeded synthetic data (no backend) |
| `web/live/` | Live version of the dashboard: same UI, backed by the real database through a small `/api/data` server |
| `mcp-server/` | **Read-only** Model Context Protocol server exposing typed `get*` query tools over the `lab` schema to an LLM agent |
| `tools/` | Python scripts: `backup_lab.py` / `restore_lab.py` (backup and restore of the database and its roles) and `verify_artifacts.py` (checks the files on the NAS against their checksums) |

## The data model

The schema is built around an **append-only event log**:

- **`event`** is a base table. Each of the 8 event types — `birth`, `surgery`,
  `recording`, `behavior`, `husbandry`, `endpoint`, `histology`, `analysis` —
  has its own detail table (class-table inheritance). Type correctness is
  enforced declaratively with `UNIQUE(event_id, event_type)` plus a composite
  foreign key on each detail table.
- **`artifact`** rows are files on the NAS (relative path + checksum), each
  pointing at the `event` that produced it. **`event_input`** records which
  artifacts an event consumed. Together they form the provenance DAG, walkable
  via the recursive `fn_artifact_lineage(artifact_id, 'up'|'down')` function.
- **Immutability** is enforced by triggers on `event`, every `*_event` detail
  table, `artifact`, `event_input`, `tag_assignment`, `variable_value`,
  `retraction` and the audit logs. Corrections use a `supersedes` link; a row
  entered in error is withdrawn with `lab.fn_retract` and stays in the
  database; the `event_active` / `artifact_active` views filter to current
  rows (neither superseded nor retracted). The descriptive tables (`subject`,
  `session`, the project and reference tables, the tag vocabulary, the
  variable definitions) are edited in place, and every edit is kept in
  `lab.row_history`.
- **Attribution.** Every lab member connects with their own database login.
  The database stamps that login on every event, artifact, verification,
  tag, variable value and retraction it stores, and `lab.person.db_login`
  maps the login to a person (`lab.fn_current_person()`).
- Every event carries two timestamps: `occurred_at` (when it happened) and
  `recorded_at` (when the row was inserted) — they routinely differ.
- **Tags** — hashtag-style `namespace:value` labels (`stage:raw`, `cohort:a`,
  `qc:fail`; a bare `auditory_cortex` is `tag:auditory_cortex`) on events,
  artifacts, subjects, sessions and projects. Each namespace carries a policy
  (mutable or permanent, one value or many, open or closed vocabulary). Tag
  assignments are an append-only log written through `lab.fn_tag`; current tags
  are a view. See `design_docs/tagging.md`.
- **Variables** — user-defined named values (`probe depth` = 1200 um on a
  session, `housing` = `pair` on an animal) with units and full history,
  written through `lab.fn_set_variable`; `lab.variable_current` holds the
  latest values, and a correction carries them forward automatically. See
  `design_docs/variables.md`.

Read `design_docs/overview.md` first for the conceptual model, then
`design_docs/database-design.md` for the table-by-table rationale.

## The MATLAB interface

`@CarasLabDB` is a thin, opinionated wrapper over the schema:

- Connects via the **native `postgresql()`** Database Toolbox interface — no
  ODBC DSN or JDBC `.jar` configuration required.
- Resolves a **"current person"** at construction (from the login's
  `lab.person.db_login`, or `PersonEmail=` etc.) and auto-populates the
  `created_by` / `recorded_by` provenance columns on inserts. A database at a
  schema version the class was not written for is an error unless
  `AllowSchemaMismatch=true`.
- Read helpers default to the `*_active` views; set `UseActiveViews=false`
  globally or `ActiveOnly=false` per call to see full history.
- `supersedeEvent` / `supersedeArtifact` implement the correction workflow:
  carry every column of the old row forward exactly as stored except explicit
  overrides, set `supersedes`, insert as new. `supersedeEvent` also carries
  the event's inputs over and re-points the files it produced at the
  correction, in the same transaction, and copy the tags across.
  `retractEvent` / `retractArtifact` withdraw a row entered in error.
- `setTag` / `addTag` / `removeTag` label rows, `findByTags` and the `Tags=` /
  `AnyTags=` / `NotTags=` options on the `get*` methods filter by them.
- `setVariable` / `getVariables` / `getVariableValues` / `unsetVariable` set
  and read variables; `checkIntegrity()` returns the database's integrity
  report; `addHusbandryBatch` enters a day's weigh-ins in one transaction;
  `addArtifactFromFile` registers a file, computing its size and SHA-256.

```matlab
db  = CarasLabDB(Username="jdoe", Password=secret, ...   % your own login
                 Server="nas-main.lab", DatabaseName="lab", ...
                 PersonEmail="dstolz@umd.edu");

% Every subject belongs to a project, so create (or look up) one first.
pid = db.addProject(Name="Gerbil AC plasticity");

db.addSubject(SubjectId="G-0421", ProjectId=pid, ...
                    SpeciesCode="meriones_unguiculatus", Sex="M");
sid = db.addSession(SubjectId="G-0421", Label="2026-07-02_pen1", ...
                    StorageRootId=1, RelativePath="G-0421/2026-07-02_pen1");
eid = db.addRecordingEvent(SubjectId="G-0421", SessionId=sid, ...
                    OccurredAt=datetime("now","TimeZone","local"), ...
                    AcquisitionSystemCode="intan_rhx", SampleRateHz=30000, ...
                    NChannels=64, DurationS=1800);

% Checksums are stored as hex of the declared algorithm's exact width
% (sha256/blake3 = 64 chars, md5 = 32) and normalised to lower case; the
% database rejects anything else, so a placeholder value will not insert.
sha = "96856fa7376e06ee8614e194b4ca38a6372e1f7a32861a99b0ab10e680391bd7";
aid = db.addArtifact(ProducedByEventId=eid, StorageRootId=1, ...
                    RelativePath="G-0421/2026-07-02_pen1/raw.dat", ...
                    Checksum=sha, Role="raw", Format="dat", SizeBytes=1.2e10);
T   = db.getArtifacts(SubjectId="G-0421");
L   = db.artifactLineage(aid, Direction="up");
```

The GUI (`@CarasLabDBApp`) is a `uifigure` front end over the same class: search
and browse subjects, sessions, events and artifacts (including by tag, e.g.
`stage:raw -qc:fail`); add and correct events; edit a row's tags (Ctrl+T) and
variables (Ctrl+L); retract a row (Ctrl+Delete); enter the day's husbandry
for all animals in one grid (Ctrl+H); show the integrity report (Ctrl+I); run
vetted read-only custom SQL. Ctrl+? lists the shortcuts. Because the schema is append-only, "editing" an
event creates a superseding correction rather than mutating in place.

**Requirements:** MATLAB R2024b or later with the Database Toolbox.

## Getting started

**Apply the schema and privileges** (for a quick local trial; a real
deployment applies both as a dedicated non-superuser owner role and gives
every member their own login, see `design_docs/deployment-windows.md`):

```sh
createdb lab && psql -X -v ON_ERROR_STOP=1 -d lab -f design_docs/schema.sql
psql -X -v ON_ERROR_STOP=1 -d lab -f design_docs/grants.sql
```

The schema is at version 5. To upgrade an existing database instead, apply
the scripts in `design_docs/migrations/` in order, as the owner, after a
backup (`tools/backup_lab.py`).

**Run the tests:** `tests/schema_test.sql` checks the schema's constraints and
triggers against a freshly loaded database, `tests/roles_test.sql` what
members of `lab_rw` and `lab_ro` may do (run as a superuser after
`grants.sql`), `tests/seed_v1.sql` + `tests/migrated_data_test.sql` the
migrations on a database holding data, `tests/check_verify_artifacts.py` the
file verifier, `tests/check_lab_data.py` the live dashboard's export, and
`mcp-server/tests/` the MCP server. CI runs them on PostgreSQL 14, 15, 16
and 17 (`.github/workflows/tests.yml`). The MATLAB tests in `tests/matlab/`
run locally only (`design_docs/testing-locally.md` §2.7).

```sh
psql -X -v ON_ERROR_STOP=1 -d lab_test -f tests/schema_test.sql
psql -X -v ON_ERROR_STOP=1 -d lab_test -f tests/roles_test.sql
cd mcp-server && pip install -e .[test] && CARASLABDB_TEST_DB=lab_test python -m pytest tests
```

**Use the MATLAB class:** add the repo root to the MATLAB path (so `@CarasLabDB`
and `@CarasLabDBApp` are visible as class folders), then adapt
`examples/carasLabDB_demo.m` — a connect → reference data → subject/session →
recording event → artifact → analysis event → retrieval → supersede walkthrough.
It needs a reachable Postgres instance with the schema applied.
`examples/carasLabDBApp_demo.m` launches the GUI.

**View the dashboard (synthetic):** serve the `web/` directory statically and
open `lab-dashboard.html`. It renders entirely from in-page synthetic data — no
backend required. Its charts load Chart.js from a CDN; without network access
the page shows a notice in their place and everything else still works.

```sh
python -m http.server 8777 --directory web
# then open http://localhost:8777/lab-dashboard.html
```

**View the dashboard (live):** the same UI backed by the real database. With the
schema applied to database `lab`, run the bundled server as a login that
inherits `lab_ro` and open the page it prints. It has no authentication: in
production it stays bound to 127.0.0.1 behind a reverse proxy that provides
HTTPS and login. See `web/live/README.md` for connection settings and details.

```sh
PGDATABASE=lab PGUSER=lab_dashboard python web/live/server.py --port 8778
# then open http://127.0.0.1:8778/
```

**Back up and check:** `tools/backup_lab.py` backs up the database and its
roles (run as a PostgreSQL superuser; `--check HOURS` for monitoring),
`tools/restore_lab.py` restores a backup into a new database and checks it
against the backup's manifest, and `tools/verify_artifacts.py` checks the
files on the NAS against their checksums. `SELECT * FROM
lab.fn_check_integrity();` lists anything that needs attention. The
deployment guides schedule all four.

**Query the schema from an LLM agent:** `mcp-server/` is a **read-only** MCP
server that exposes typed `get*` tools (subjects, sessions, events, artifacts,
lineage, tags, variables) over the `lab` schema — no insert, update or supersede surface, and no
tool takes a table name or raw SQL. It connects as a login that inherits
`lab_ro` (`lab_mcp` below). Install it and register it with your own MCP
client; see `mcp-server/README.md` and `design_docs/mcp-server.md`.

```sh
cd mcp-server && pip install -e .
claude mcp add caraslabdb -e PGDATABASE=lab -e PGUSER=lab_mcp -- python -m caraslabdb_mcp.server
```

See `design_docs/deployment-requirements.md` for the server-side requirements
summary written for IT staff (plus the deployment-related design concerns),
`design_docs/testing-locally.md` for a full local-testing guide,
`design_docs/mcp-server.md` for the MCP server's design and setup,
`design_docs/deployment-windows.md` for the lab's production deployment (a
MECM-managed Windows 11 server: roles, TLS, the dashboard behind a reverse
proxy, scheduled backups and checks, restore and upgrade runbooks), and
`design_docs/deployment-linux.md` / `design_docs/deployment-synology.md` for
the Linux and Synology alternatives.

## Repository layout

```
design_docs/         Schema DDL and design documentation
  schema.sql           Canonical PostgreSQL DDL (schema `lab`), latest version
  grants.sql           Roles and privileges (lab_rw, lab_ro)
  migrations/          Upgrade scripts for existing databases
  overview.md          Conceptual model — read this first
  database-design.md   Table-by-table rationale
  tagging.md           Tags: syntax, policy flags, filters, corrections
  variables.md         User-defined variables: names, units, history, queries
  testing-locally.md   Local testing guide
  mcp-server.md        Read-only MCP server: design and setup
  deployment-requirements.md   Server-side requirements summary for IT
  deployment-windows.md        Production deployment (Windows 11, MECM-managed)
  deployment-linux.md
  deployment-synology.md
@CarasLabDB/         MATLAB class: typed DB interface
@CarasLabDBApp/      MATLAB GUI (uifigure)
web/                 Standalone dashboard (synthetic data)
  live/                Live dashboard: /api/data server + query
mcp-server/          Read-only MCP server (Python): typed query tools for LLM agents
tools/               Backup, restore and file verification (Python)
examples/            End-to-end demo scripts
tests/               Schema, role and migration assertions (psql), tool checks (Python)
  matlab/              MATLAB unit and GUI tests (run locally)
CLAUDE.md            Repo conventions for Claude Code / coding agents
```
