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
  that points at the row it replaces. History is retained; queries filter to the
  active (non-superseded) version.

A file being renamed, moved, or re-derived does not change what happened in the
lab. Separating the two makes provenance tractable and makes reruns a matter of
reading an analysis event rather than reverse-engineering a folder.

## Components

| Component | Role |
|---|---|
| `design_docs/schema.sql` | Canonical PostgreSQL 14+ DDL (schema `lab`) — the single source of truth for the data model |
| `@CarasLabDB/` | MATLAB class wrapping the database with typed insert/retrieve helpers for every table |
| `@CarasLabDBApp/` | MATLAB App Designer GUI for interactive metadata entry and browsing |
| `web/lab-dashboard.html` | Standalone HTML/JS dashboard visualizing the data model with seeded synthetic data (no backend) |
| `web/live/` | Live version of the dashboard: same UI, backed by the real database through a small `/api/data` server |
| `mcp-server/` | **Read-only** Model Context Protocol server exposing typed `get*` query tools over the `lab` schema to an LLM agent |

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
  table, `artifact`, and `event_input`. Corrections use a `supersedes` link; the
  `event_active` / `artifact_active` views filter to current rows.
- Every event carries two timestamps: `occurred_at` (when it happened) and
  `recorded_at` (when the row was inserted) — they routinely differ.

Read `design_docs/overview.md` first for the conceptual model, then
`design_docs/database-design.md` for the table-by-table rationale.

## The MATLAB interface

`@CarasLabDB` is a thin, opinionated wrapper over the schema:

- Connects via the **native `postgresql()`** Database Toolbox interface — no
  ODBC DSN or JDBC `.jar` configuration required.
- Resolves a **"current person"** at construction and auto-populates the
  `created_by` / `recorded_by` provenance columns on inserts.
- Read helpers default to the `*_active` views; set `UseActiveViews=false`
  globally or `ActiveOnly=false` per call to see full history.
- `supersedeEvent` / `supersedeArtifact` implement the correction workflow:
  carry every column of the old row forward except explicit overrides, set
  `supersedes`, insert as new.

```matlab
db  = CarasLabDB(Username="lab_rw", Password=secret, ...
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
and browse subjects, sessions, events and artifacts; add and correct events; run
vetted read-only custom SQL. Because the schema is append-only, "editing" an
event creates a superseding correction rather than mutating in place.

**Requirements:** MATLAB R2025a or later with the Database Toolbox.

## Getting started

**Apply the schema:**

```sh
createdb lab && psql -d lab -f design_docs/schema.sql
```

**Use the MATLAB class:** add the repo root to the MATLAB path (so `@CarasLabDB`
and `@CarasLabDBApp` are visible as class folders), then adapt
`examples/carasLabDB_demo.m` — a connect → reference data → subject/session →
recording event → artifact → analysis event → retrieval → supersede walkthrough.
It needs a reachable Postgres instance with the schema applied.
`examples/carasLabDBApp_demo.m` launches the GUI.

**View the dashboard (synthetic):** serve the `web/` directory statically and
open `lab-dashboard.html`. It renders entirely from in-page synthetic data — no
backend required.

```sh
python -m http.server 8777 --directory web
# then open http://localhost:8777/lab-dashboard.html
```

**View the dashboard (live):** the same UI backed by the real database. With the
schema applied to database `lab`, run the bundled server and open the page it
prints. See `web/live/README.md` for connection settings and details.

```sh
PGDATABASE=lab python web/live/server.py --port 8778
# then open http://127.0.0.1:8778/
```

**Query the schema from an LLM agent:** `mcp-server/` is a **read-only** MCP
server that exposes typed `get*` tools (subjects, sessions, events, artifacts,
lineage) over the `lab` schema — no insert, update or supersede surface, and no
tool takes a table name or raw SQL. Install it and register it with your own MCP
client; see `mcp-server/README.md` and `design_docs/mcp-server.md`.

```sh
cd mcp-server && pip install -e .
claude mcp add caraslabdb -e PGDATABASE=lab -e PGUSER=lab_ro -- python -m caraslabdb_mcp.server
```

See `design_docs/deployment-requirements.md` for the server-side requirements
summary written for IT staff (plus the deployment-related design concerns),
`design_docs/testing-locally.md` for a full local-testing guide,
`design_docs/mcp-server.md` for the MCP server's design and setup,
`design_docs/deployment-windows.md` for Windows deployment notes,
`design_docs/deployment-linux.md` for Linux deployment notes, and
`design_docs/deployment-synology.md` for deploying on a Synology NAS.

## Repository layout

```
design_docs/         Schema DDL and design documentation
  schema.sql           Canonical PostgreSQL DDL (schema `lab`)
  overview.md          Conceptual model — read this first
  database-design.md   Table-by-table rationale
  testing-locally.md   Local testing guide
  mcp-server.md        Read-only MCP server: design and setup
  deployment-requirements.md   Server-side requirements summary for IT
  deployment-windows.md
  deployment-linux.md
  deployment-synology.md
@CarasLabDB/         MATLAB class: typed DB interface
@CarasLabDBApp/      MATLAB App Designer GUI
web/                 Standalone dashboard (synthetic data)
  live/                Live dashboard: /api/data server + query
mcp-server/          Read-only MCP server (Python): typed query tools for LLM agents
examples/            End-to-end demo scripts
CLAUDE.md            Repo conventions for Claude Code / coding agents
```
