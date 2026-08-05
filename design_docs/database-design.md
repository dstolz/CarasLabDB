# Database Design — Lab Metadata System

This document specifies the PostgreSQL schema that implements the append-only
event log, artifact index, and provenance DAG described in
[overview.md](overview.md). It is the authoritative reference for the schema:
an ER overview, a table-by-table rationale, and the recursive lineage query. The
complete runnable DDL lives alongside it in [schema.sql](schema.sql).

- **Target:** PostgreSQL 14+ (schema named `lab`).
- **Portability:** the schema degrades cleanly to SQLite for single-writer use;
  the deltas are listed in [Portability](#portability-notes).

---

## 1. Overview & ER diagram

The schema has five layers:

1. **Reference tables** — mostly-static vocabulary and registries (`person`,
   `probe`, `pipeline`, `storage_root`, `species`, and the categorical lookups
   `event_type` / `artifact_role` / `acquisition_system`).
2. **Projects** — `project`, its membership (`project_member`) and its
   attachments (`project_artifact`). Unlike everything below, these rows are
   deliberately **mutable**: people join and leave, documents get revised.
3. **Dimensions** — the durable identities the events hang off: `subject` (the
   animal) and `session` (a recording period, 1:1 with a NAS folder).
4. **Events** — a base `event` table plus one typed detail table per event type
   (class-table inheritance). Events are immutable and append-only.
5. **Artifacts & provenance** — `artifact` rows point at the event that produced
   them; `event_input` records which artifacts an event consumed. Together these
   two edge types form the provenance DAG.

```mermaid
erDiagram
    project      ||--o{ project_member   : has
    project      ||--o{ project_artifact : collects
    project      ||--o{ subject          : groups
    person       ||--o{ project_member   : joins
    person       ||--o{ event            : records
    person       ||--o{ surgery_event    : performs
    species      ||--o{ subject          : classifies
    storage_root ||--o{ session          : roots
    storage_root ||--o{ artifact         : roots
    probe        ||--o{ surgery_event    : implanted_in
    probe        ||--o{ recording_event  : used_by
    pipeline     ||--o{ analysis_event   : run_as

    subject      ||--o{ session          : has
    subject      ||--o{ event            : subject_of
    session      ||--o{ event            : groups

    event_type   ||--o{ event            : typed_as
    event        ||--|| birth_event      : detail
    event        ||--|| surgery_event    : detail
    event        ||--|| recording_event  : detail
    event        ||--|| behavior_event   : detail
    event        ||--|| husbandry_event  : detail
    event        ||--|| endpoint_event   : detail
    event        ||--|| histology_event  : detail
    event        ||--|| analysis_event   : detail
    event        |o--o{ event            : supersedes

    event        ||--o{ artifact         : produces
    event        ||--o{ event_input      : consumes
    artifact     ||--o{ event_input      : consumed_by
    artifact     |o--o{ artifact         : supersedes
    artifact     ||--o{ artifact_verification : verified_by
    artifact_role||--o{ artifact         : role
```

---

## 2. Conventions

- **Identifiers.** `event` and `artifact` use `uuid` primary keys defaulting to
  `gen_random_uuid()`. UUIDs are client-generatable, so the MATLAB `CarasLabDB`
  layer can mint IDs offline and batch-insert without a round-trip, and two
  workstations never collide. `subject` uses its human-meaningful lab ID as a
  natural text primary key; lookup tables use short `code` primary keys.
- **Two clocks.** Every event carries `occurred_at` (when the fact happened in
  the lab) *and* `recorded_at` (when the row was inserted). They differ whenever
  metadata is entered after the fact, which is the norm.
- **Categoricals are lookup tables, not native enums.** `event_type`,
  `artifact_role`, and `acquisition_system` are small tables referenced by FK.
  This keeps the vocabulary extensible without `ALTER TYPE`, and it is the
  portable choice for SQLite. Tiny fixed sets that will never grow (`sex`,
  `checksum_algo`, `modality`, `status`) use `CHECK` constraints instead.
- **Extensibility.** The base `event` and `artifact` tables each carry an
  `attributes jsonb` column for ad-hoc fields that do not warrant a schema
  change. Structured, frequently-queried data gets real columns
  (`analysis_event.parameters`, `recording_event.hardware_config`,
  `probe.geometry` are the JSONB exceptions where the shape is genuinely open).
- **Timestamps** are `timestamptz`; store UTC. **Text** uses `text`, not
  `varchar(n)`.
- **Everything is schema-qualified** (`lab.<table>`) so the DDL is
  copy-paste-safe regardless of the caller's `search_path`.

---

## 3. Table reference

### 3.1 Reference tables

| Table | Purpose |
|---|---|
| `person` | Lab members. Referenced by `event.recorded_by`, `surgery_event.surgeon_id`, and every `*_by` column. |
| `storage_root` | Named NAS roots. Paths elsewhere are stored **relative** to a root so they resolve across machines/OSes; the per-OS mount point lives in client config, not the DB. |
| `species` | Species vocabulary for `subject`. |
| `probe` | Electrode/probe device registry, including channel geometry as JSONB. Referenced by surgeries (implant) and recordings (acquisition device). |
| `pipeline` | Analysis pipeline registry (name + repo). Each *run* pins its own `code_version`/`parameters` on the `analysis_event`, so this table stays stable while runs vary. |
| `event_type` | The eight event-type codes; the discriminator that selects a detail table. |
| `artifact_role` | Role a file plays (`raw`, `spikes`, `lfp`, `video`, `figure`, …). |
| `acquisition_system` | Acquisition software (`intan_rhx`, `open_ephys`). |

### 3.2 Projects

| Table | Purpose |
|---|---|
| `project` | The unit of work a subject belongs to. `subject.project_id` is `NOT NULL`, so every animal has exactly one. |
| `project_member` | Many-to-many `project`↔`person`, with a `role` (`PI`, `lead`, `analyst`, …). |
| `project_artifact` | Project-level attachments — NAS files *and* external references (Google Docs/Sheets, arbitrary URLs). Distinct from the provenance `artifact` table: these are reference material, not checksummed data files produced by an event. A `CHECK` enforces that `kind = 'file'` rows are located by (`storage_root_id`, `relative_path`) and every other kind by `uri`, never both. |

These three tables are the schema's mutable layer. They are intentionally
**not** covered by the append-only triggers in §4: membership and documents are
current-state facts, not a log of events.

### 3.3 Dimensions

**`subject`** — the animal, keyed by lab ID. Its identity is independent of any
birth: an acquired animal has a `subject` row with `date_of_birth` possibly null
and no `birth_event`. Descriptive fields (`species_code`, `sex`, `strain`,
`genotype`, `source`) live here because they are stable identity attributes;
anything that *happens* to the subject over time is an event.

**`session`** — a recording period mapping 1:1 to a NAS folder `subject/session`.
`UNIQUE(subject_id, label)` and `UNIQUE(storage_root_id, relative_path)` enforce
that mapping. Recording and behavior events belong to a session; births,
surgeries, and husbandry do not.

### 3.4 Events (class-table inheritance)

**`event`** is the base row shared by all event types. It holds the common
columns — type, subject, session, the two clocks, recorder, correction link,
notes, and the `attributes` JSONB — and nothing type-specific.

Type correctness is enforced **declaratively**, not by trigger: `event` carries
`UNIQUE(event_id, event_type)`, and every detail table pins its own type with a
`CHECK` plus a composite foreign key `(event_id, event_type) →
event(event_id, event_type)`. A `recording_event` row therefore *cannot* attach
to an event whose type is `birth`.

Detail tables and their type-specific columns:

| Detail table | Key columns |
|---|---|
| `birth_event` | `dam_subject_id`, `sire_subject_id`, `litter_id`, `birth_weight_g` (newborn = base `subject_id`) |
| `surgery_event` | `procedure`, `surgeon_id`, `anesthesia`, `target_region`, `hemisphere`, stereotax `ap/ml/dv_mm`, `probe_id`, `outcome` |
| `recording_event` | `acquisition_system_code`, `probe_id`, `modality`, `sample_rate_hz`, `n_channels`, `duration_s`, `stimulus_protocol`, `hardware_config` |
| `behavior_event` | `task`, `paradigm`, `stage`, `trials_completed`, `performance`, `reward` |
| `husbandry_event` | `measure`, `weight_g`, `water_ml`, `health_status` |
| `endpoint_event` | `method`, `perfusion_fixative`, `tissue_collected`, `disposition` |
| `histology_event` | `technique`, `target_region`, `stain`, `microscope` |
| `analysis_event` | `pipeline_id`, `pipeline_name`, `code_version`, `parameters`, `environment`, `started_at`, `finished_at`, `status` |

Rules that need a trigger rather than a constraint:

- **Recordings require a session.** `trg_require_session_for_recording` rejects a
  `recording_event` whose base `event.session_id` is null. (Behavior events may
  belong to a session but are not *required* to — not every training run
  produces a NAS folder.)
- **Corrections preserve the event type.** `trg_event_supersede_same_type`
  rejects an event that supersedes one of a different type. Without it a
  `recording` could be replaced by a `birth`, silently retyping history and
  stranding the original detail row.
- **`subject_id` is derived from the session when omitted.**
  `trg_event_fill_subject` fills it in, which is what makes the composite FK
  below bite (see "Subject/session agreement").
- **Immutability.** `event`, every `*_event` detail table, `artifact`, and
  `event_input` reject `UPDATE`/`DELETE`/`TRUNCATE` (see §4).

**Subject/session agreement.** `event` and `artifact` each carry a composite
foreign key `(session_id, subject_id) → session(session_id, subject_id)`. An
event therefore cannot be filed under animal A while pointing at a session
belonging to animal B — a row that looks perfectly fine in isolation but
quietly corrupts every per-subject rollup. This is the same declarative trick
as `(event_id, event_type)`, and it needs the `UNIQUE (session_id, subject_id)`
on `session` as its target.

**Video.** Behavioral video is not a separate event type; it is an `artifact`
with `role = 'video'`. A recording that is primarily video sets
`recording_event.modality = 'video'` (or `'multimodal'` when video accompanies
ephys), and the `.mp4`/`.avi` files register as artifacts of that event.

### 3.5 Artifacts & provenance

**`artifact`** — one row per file on the NAS, referenced by
`(storage_root_id, relative_path)` plus a `checksum`. It always points at the
`produced_by_event_id` that created it. `UNIQUE(storage_root_id, relative_path,
checksum)` dedupes re-registration of the same bytes while allowing a
re-derived file at the same path (new bytes) to register as a *new* artifact,
optionally linked to the old one via `supersedes`.

**`event_input`** — the second edge type: the artifacts an event consumed. It is
general (any event may consume artifacts) but in practice is populated by
analysis events. `artifact.produced_by_event_id` + `event_input` are the two
edges of the provenance DAG.

**`artifact_verification`** — an *append-only log* of integrity checks. Because
`artifact` rows are immutable, periodic checksum re-verification is recorded here
(`ok` / `missing` / `mismatch`) instead of mutating the artifact. A `mismatch`
must carry the `observed_checksum`, since that is the only thing that makes the
row actionable.

**Checksums are format-checked.** `checksum` must be hex of exactly the width
the declared `checksum_algo` produces (`md5` = 32, `sha256`/`blake3` = 64), and
a trigger lower-cases it on insert. Both halves matter: this table exists to
make file integrity *checkable*, so a truncated or placeholder checksum would
make a nightly verifier report `mismatch` forever with no way to distinguish a
corrupted file from a bad registration; and without case normalisation the same
bytes registered as `AB..` and `ab..` are two different rows under the `UNIQUE`
above, defeating the de-duplication it exists for.

**Paths must be genuinely relative.** `session.relative_path`,
`artifact.relative_path` and `project_artifact.relative_path` each reject
absolute paths, drive letters and `..` segments — the things that cannot be
repaired by rewriting. Paths are stored relative to a storage root precisely so
they resolve on every machine that mounts the NAS; an absolute path baked in
from one workstation does not.

Separators are **normalised, not rejected**: a trigger rewrites `\` to `/` on
insert. This lab runs on Windows, where `fullfile()` and every native tool
produce `GERB042\sess01`; storing that alongside a Linux client's
`GERB042/sess01` would put one folder in the table twice and break both the
session-to-folder mapping and artifact de-duplication. Same reasoning as
lower-casing checksums — canonicalise on the way in so one real-world thing is
always one row.

---

## 4. Immutability & corrections

Events are facts; facts do not change. The schema forbids `UPDATE` and `DELETE`
on all event and artifact tables via `fn_forbid_mutation()`. A mistake is fixed
by **appending a superseding row** whose `supersedes` points at the row it
replaces. The partial unique index on `supersedes` keeps history *linear* — a
given row can be corrected by at most one successor, so there are no forks.

`TRUNCATE` is blocked separately. It bypasses row-level triggers entirely, so
the `BEFORE UPDATE OR DELETE ... FOR EACH ROW` trigger does **not** stop it —
a single `TRUNCATE lab.event CASCADE` would silently erase the whole log and
everything hanging off it. Each protected table therefore also carries a
`BEFORE TRUNCATE ... FOR EACH STATEMENT` trigger (statement level, because
`FOR EACH ROW` is not permitted for `TRUNCATE`).

`event_input` is append-only too, but it has no `supersedes` column, so a
mis-recorded input is corrected by superseding the *consuming event* and
re-declaring its inputs. `fn_forbid_mutation()` says so in its error message
rather than giving the generic "insert a superseding row" advice that cannot be
followed there.

A row is **active** when nothing supersedes it. The `event_active` and
`artifact_active` views encapsulate that filter so callers never hand-roll it.

### 4.1 The one sanctioned mutation: renaming a subject

`subject_id` is a human-typed natural key, and humans mistype it. Because it is
*the* key, correcting a typo means updating every FK that points at it — and
those land in append-only tables. Without an explicit path a mistyped animal ID
would be **permanently uncorrectable**: the referencing rows can be neither
updated nor deleted, and creating the correctly-named subject strands that
animal's history under the wrong ID forever.

So the FKs to `subject(subject_id)` declare `ON UPDATE CASCADE`, and
`lab.fn_rename_subject(old, new)` performs the rename behind a
transaction-local flag (`lab.maintenance`) that `fn_forbid_mutation()` honours
for `UPDATE` only — never `DELETE`, never `TRUNCATE`. Every rename is recorded
in `lab.maintenance_log`. This is a relabelling of *who* a row is about, not a
change to *what happened*, which is why it is the only exception. The function
is `REVOKE`d from `PUBLIC`; grant it only to an admin role.

### 4.2 Integrity report

Class-table inheritance leaves one hole no constraint can close: the composite
FK guarantees a detail row cannot attach to an event of the wrong type, but
nothing can force a detail row to *exist* — that would need a constraint
deferred across two tables. A client that inserts the base event and dies
before the detail insert leaves a typed event with no payload, which reads as a
real event everywhere and renders as a blank row.

`lab.fn_check_integrity()` is the scheduled check for that and related
conditions — run it from cron; an empty result means healthy:

```sql
SELECT * FROM lab.fn_check_integrity();
```

| Check | Severity | Meaning |
|---|---|---|
| `event_missing_detail` | error | Typed event whose detail row was never written |
| `artifact_verification_failed` | error | Latest integrity check was `missing` or `mismatch` |
| `event_recorded_before_occurred` | warning | `occurred_at` more than a day after `recorded_at` — usually a client timezone bug |
| `artifact_never_verified` | warning | Active artifact with no verification on record |
| `duplicate_active_path` | warning | Two active artifacts at one path; the NAS file can only be one of them |

**Worked example — a recording logged with the wrong sample rate:**

```sql
-- Original (wrong: 20 kHz)
INSERT INTO lab.event (event_id, event_type, subject_id, session_id, occurred_at)
VALUES ('11111111-1111-1111-1111-111111111111', 'recording', 'GERB042', :sess, now());
INSERT INTO lab.recording_event (event_id, acquisition_system_code, sample_rate_hz, n_channels)
VALUES ('11111111-1111-1111-1111-111111111111', 'intan_rhx', 20000, 64);

-- Correction (right: 30 kHz) — supersedes the original, original row is retained
INSERT INTO lab.event (event_id, event_type, subject_id, session_id, occurred_at, supersedes)
VALUES ('22222222-2222-2222-2222-222222222222', 'recording', 'GERB042', :sess, now(),
        '11111111-1111-1111-1111-111111111111');
INSERT INTO lab.recording_event (event_id, acquisition_system_code, sample_rate_hz, n_channels)
VALUES ('22222222-2222-2222-2222-222222222222', 'intan_rhx', 30000, 64);

-- event_active now shows only the 30 kHz row; the audit trail keeps both.
SELECT event_id, sample_rate_hz
FROM lab.event_active e JOIN lab.recording_event r USING (event_id)
WHERE e.session_id = :sess;
```

---

## 5. Provenance & the lineage query

Provenance is the DAG of `event → artifact → analysis → artifact`. Upstream
lineage of an artifact answers "everything that contributed to producing this
file": the artifact was produced by an event, that event consumed input
artifacts, each of which was produced by an earlier event, and so on.

`fn_artifact_lineage(artifact_id, 'up'|'down')` walks it with a recursive CTE
(depth-guarded for safety). Ancestors:

```sql
WITH RECURSIVE lin AS (
    SELECT 0 AS depth, a.produced_by_event_id AS event_id, a.artifact_id
    FROM lab.artifact a
    WHERE a.artifact_id = :target
  UNION
    SELECT l.depth + 1, ain.produced_by_event_id, ain.artifact_id
    FROM lin l
    JOIN lab.event_input ei  ON ei.event_id = l.event_id
    JOIN lab.artifact    ain ON ain.artifact_id = ei.artifact_id
    WHERE l.depth < 64
)
SELECT * FROM lin ORDER BY depth;
```

The `provenance_edge` view exposes both edge types as a uniform edge list for
graph tooling.

---

## 6. The DDL

The full, runnable DDL is **[schema.sql](schema.sql)** — the canonical schema,
kept as a single source of truth so nothing drifts from a copy. Apply it to a
fresh database:

```bash
createdb lab && psql -d lab -f design_docs/schema.sql
```

`schema.sql` creates everything described above, in dependency order: the `lab`
schema; the reference/lookup tables; the `project` tables; the `subject` /
`session` dimensions; the base `event` and its eight detail tables; `artifact` /
`event_input` / `artifact_verification`; all indexes; the immutability
(`UPDATE`/`DELETE` **and** `TRUNCATE`) and validation triggers; the identity
maintenance function and `maintenance_log`; the `event_active` /
`artifact_active` / `provenance_edge` / `subject_current` views;
`fn_artifact_lineage()` and `fn_check_integrity()`; and the seed vocabulary. It
targets PostgreSQL 14+ (`gen_random_uuid()` is in core since PG 13; a
`pgcrypto` fallback line is included for older servers).

The seed `INSERT`s use `ON CONFLICT DO NOTHING`, so re-applying the file to a
database that already has the vocabulary is not a hard failure. The `CREATE
TABLE` statements are not idempotent, however — this is still a
fresh-database script, not a migration.

---

## 7. Portability notes

The schema is designed for PostgreSQL. For single-writer SQLite use, the deltas
are:

| Feature | PostgreSQL | SQLite equivalent |
|---|---|---|
| Primary-key generation | `uuid DEFAULT gen_random_uuid()` | app-generated UUID stored as `text` |
| `timestamptz` | native | ISO-8601 `text` (store UTC) |
| `jsonb` | native, GIN-indexable | `text` via the JSON1 extension (no GIN) |
| Immutability | `BEFORE UPDATE OR DELETE` triggers | equivalent `BEFORE` triggers with `RAISE(ABORT, …)` |
| Identity columns | `GENERATED ALWAYS AS IDENTITY` | `INTEGER PRIMARY KEY AUTOINCREMENT` |
| `LATERAL` subqueries | native | correlated subqueries in `SELECT` |
| Case-insensitive email uniqueness | `UNIQUE INDEX ON (lower(email))` | `COLLATE NOCASE` on the column |
| `TRUNCATE` protection | statement-level `BEFORE TRUNCATE` trigger | not needed — SQLite has no `TRUNCATE` |
| Subject-rename escape hatch | transaction-local GUC read by the trigger | a `PRAGMA`-guarded flag, or drop the triggers for the rename |
| Regex `CHECK`s on paths/checksums | POSIX `~` / `!~` | `GLOB` patterns, or enforce in the client |

The event/artifact/provenance model itself is unchanged; only these
type/idiom substitutions apply.

---

## 8. Related documents

- [overview.md](overview.md) — purpose, philosophy, and data flow.
- [schema.sql](schema.sql) — the canonical, runnable DDL.
- [mcp-server.md](mcp-server.md) — the read-only MCP interface over this schema.
- [testing-locally.md](testing-locally.md) — how to load and verify the schema
  on a scratch database.
- `for-coders.md` *(planned)* — MATLAB versions and connection details for the
  `CarasLabDB` class. Note it connects through the native `postgresql()`
  Database Toolbox interface; no JDBC jar or ODBC DSN is involved.
