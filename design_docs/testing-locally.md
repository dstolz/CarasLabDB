# Testing CarasLabDB locally before server deployment

This document describes how to stand up and exercise the **entire** package on a
single local machine so you can catch problems before rolling the database out
to a shared lab server. It complements [`deployment-windows.md`](deployment-windows.md):
that guide is about *installing* the system; this one is about *proving it works*.

The goal of local testing is a throwaway `lab` database on `localhost` that you
can create, exercise end-to-end through both the MATLAB class and the GUI, then
drop — repeatedly — without touching production data. The schema, the
privileges, the Python tools and the MCP server have
automated tests (`tests/schema_test.sql`, `tests/roles_test.sql`,
`tests/check_verify_artifacts.py`, `tests/check_lab_data.py`,
`mcp-server/tests/`), which CI (`.github/workflows/tests.yml`) runs on
PostgreSQL 14, 15, 16 and 17. The MATLAB class and GUI have a
`matlab.unittest` suite in `tests/matlab/` (§2.7) that runs locally only,
because CI has no MATLAB; beyond it, "testing" them here means a disciplined
manual walkthrough with explicit pass/fail checks.

Before the first real use of the MATLAB class and GUI, also work through [matlab-first-run-checklist.md](matlab-first-run-checklist.md): CI runs the MATLAB tests on Linux only, and most of the GUI is not covered by any automated test.

The parts this guide covers and how each is tested:

| Part | What you verify | Needs a live DB? |
|------|-----------------|------------------|
| PostgreSQL schema (`design_docs/schema.sql`) | DDL loads; append-only triggers, views, and lineage function behave | — |
| Privileges (`design_docs/grants.sql`) | Members of `lab_rw` / `lab_ro` can do exactly what they should | — |
| Tools (`tools/`) | Backup, restore and file verification work against `lab_test` | — |
| MATLAB interface (`@CarasLabDB`) + GUI (`@CarasLabDBApp`) | Connect, insert every event type, retrieve, supersede, retract, variables, read-only SQL guard | Yes |
| Web dashboard (`web/lab-dashboard.html`) | Renders from in-page synthetic data | No |

The read-only MCP server (`mcp-server/`) has its own verification steps — stand
up `lab_test` with §1 below, then follow `mcp-server/README.md` ("Verify") and
`design_docs/mcp-server.md` §7.

Commands are **PowerShell** unless the block is labelled `matlab` or `sql`.

> Some steps below — starting/restarting the PostgreSQL service, or setting a
> **machine-wide** `PATH` — need elevated rights. If a command fails with an
> "Access is denied" or permission error, re-open PowerShell with **Run as
> administrator** and retry.

---

## 0. Prerequisites for a local test rig

Everything runs on one Windows 11 box:

- **PostgreSQL 14+** installed and the service running (`Get-Service postgresql*`).
- `psql`, `createdb`, `dropdb`, `pg_dump` on `PATH` (see `deployment-windows.md` §1.1).
- **MATLAB R2024b+** with **Database Toolbox**.
- **Python** (optional) if you want to serve the dashboard over HTTP.
- The repo checked out at a stable path, e.g. `C:\src\CarasLabDB`.

Use a **test-only database name** (`lab_test` below) so you never risk running
these destructive steps against a real `lab` database. Point MATLAB and the GUI
at `lab_test` for the whole exercise.

### 0.1 If `createdb` / `psql` aren't recognized

The Windows PostgreSQL installer does **not** add its `bin` folder to `PATH`, so
a fresh install gives `createdb : The term 'createdb' is not recognized …` even
though the tools are present (under `C:\Program Files\PostgreSQL\<version>\bin`).

For a single throwaway test session, prepend the `bin` folder to `PATH` and grab
the superuser password once, so `createdb`/`psql` resolve and don't hang on a
hidden `Password:` prompt (adjust `16` to your installed major version):

```powershell
$env:Path += ";C:\Program Files\PostgreSQL\16\bin"
$env:PGPASSWORD = Read-Host "postgres password" -AsSecureString | ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
createdb -U postgres lab_test
psql -U postgres -d lab_test -f design_docs/schema.sql
```

Both variables live only in the current PowerShell session — a new terminal
starts clean. `PGPASSWORD` also lets the later `dropdb`/`psql` steps run without
re-prompting.

> If you already know the `postgres` password, skip the `Read-Host` prompt and
> just set it directly: `$env:PGPASSWORD = "yourpassword"`.

To make `createdb`, `psql`, `pg_dump`, etc. permanently available (new terminals
included), add the `bin` folder to your user `PATH` once, then open a new shell:

```powershell
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Program Files\PostgreSQL\16\bin", "User")
```

If you'd rather set it for **all users** (`"Machine"` instead of `"User"`) or the
PostgreSQL service isn't running and needs a `Start-Service`/`Restart-Service`,
you'll need an elevated PowerShell — see the admin-mode note at the top of this
document.

---

## 1. Test the database schema

### 1.1 Create a throwaway database and load the schema

From the repo root (`C:\src\CarasLabDB`):

```powershell
dropdb -U postgres --if-exists lab_test          # clean slate
createdb -U postgres lab_test
psql -U postgres -d lab_test -v ON_ERROR_STOP=1 -f design_docs/schema.sql
```

`-v ON_ERROR_STOP=1` makes `psql` exit non-zero on the **first** DDL error instead
of plowing through — so a clean run with no error output means the whole file
applied: the tables and indexes, the views, the trigger functions and the
triggers built from them, the lineage and integrity functions, and the seed
vocabulary `INSERT`s at the end. On PostgreSQL 14+ `gen_random_uuid()` is built
in; you should **not** need the `pgcrypto` extension.

Note that `schema.sql` creates **no roles** and issues no `GRANT`s (its only
privilege statement is a `REVOKE` on `lab.fn_rename_subject`). Roles are a
deployment decision, made separately in §1.4.

**Pass:** command exits 0 with no `ERROR:` lines.

### 1.2 Verify the objects exist

Rather than counting statements, check that the objects the rest of the system
depends on are actually there:

```powershell
psql -U postgres -d lab_test -c "\dt lab.*"      # tables
psql -U postgres -d lab_test -c "\dv lab.*"      # views (expect *_active)
psql -U postgres -d lab_test -c "\df lab.*"      # functions (all named fn_*)
```

If you'd rather have one plain list to diff against `design_docs/schema.sql`:

```powershell
psql -U postgres -d lab_test -c @'
SELECT c.relkind, c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'lab' AND c.relkind IN ('r','v')
UNION ALL
SELECT 'f', p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'lab'
ORDER BY 1, 2;
'@
```

**Pass:** the listing contains, at minimum —

- **Reference/lookup tables:** `person`, `storage_root`, `species`, `probe`,
  `pipeline`, `event_type`, `artifact_role`, `acquisition_system`.
- **Project tables:** `project`, `project_member`, `project_artifact`.
- **Dimensions:** `subject`, `session`.
- **The log:** the `event` base table plus the eight `*_event` detail tables
  (`birth_event` … `analysis_event`).
- **Provenance:** `artifact`, `event_input`, `artifact_verification`.
- **Tags:** `tag_namespace`, `tag`, `tag_assignment` (see [tagging.md](tagging.md)).
- **Variables:** `variable`, `variable_value` (see [variables.md](variables.md)).
- **Retraction:** `retraction`.
- **Audit and versioning:** `maintenance_log` (subject renames), `row_history`
  (edits to the mutable tables) and `schema_version` (1 on a fresh install).
- **Views:** `event_active`, `artifact_active`, `event_version`,
  `artifact_version`, `artifact_verification_latest`, `provenance_edge`,
  `subject_current`, `tag_current`, `entity_tags`, `variable_current`,
  `entity_variables`.
- **Functions:** the trigger functions `fn_forbid_mutation`,
  `fn_require_session_for_recording`, `fn_fill_subject_from_session`,
  `fn_supersede_same_type`, `fn_normalize_checksum`, `fn_normalize_path`,
  `fn_artifact_unique_active`, `fn_artifact_matches_event`,
  `fn_forbid_provenance_cycle`, `fn_log_row_change`, `fn_stamp_login`,
  `fn_subject_id_guard`, `fn_normalize_tag`, `fn_tag_guard`,
  `fn_tag_namespace_guard`, `fn_tag_assignment_policy`,
  `fn_normalize_variable`, `fn_variable_guard`, `fn_variable_value_policy`,
  `fn_carry_variables_on_supersede`, `fn_retraction_policy`; plus
  `fn_rename_subject`, `fn_artifact_lineage`, the correction-chain helpers
  `fn_event_current` / `fn_artifact_current` / `fn_event_versions` /
  `fn_artifact_versions`, `fn_check_integrity`, `fn_current_person`,
  `fn_retract`, the tag functions `fn_canonical_tag`, `fn_register_tag`,
  `fn_tag`, `fn_tag_match`, `fn_find_by_tags`, `fn_tag_filter_problems`, and
  the variable functions `fn_canonical_variable`, `fn_define_variable`,
  `fn_set_variable`, `fn_unset_variable`, `fn_variable_number`,
  `fn_variable_text`, `fn_carry_variables`.

The list grows as the schema does — treat `schema.sql` as the authority and this
as the "nothing obviously missing" check.

Then confirm the triggers actually got attached (the immutability guarantee is
worthless if they didn't):

```powershell
psql -U postgres -d lab_test -c @'
SELECT c.relname, t.tgname
FROM pg_trigger t
JOIN pg_class c     ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'lab' AND NOT t.tgisinternal
ORDER BY 1, 2;
'@
```

**Pass:** every append-only table — `event`, the eight `*_event` detail tables,
`artifact`, `event_input`, and the logs `artifact_verification`,
`maintenance_log`, `row_history`, `schema_version`, `tag_assignment`,
`variable_value`, `retraction` — carries *two* immutability triggers:
`trg_immutable_<table>` (row-level, `UPDATE`/`DELETE`) and
`trg_immutable_truncate_<table>` (statement-level, `TRUNCATE`, which row-level
triggers cannot see). The validation and normalization triggers
`trg_require_session_for_recording`, `trg_event_fill_subject`,
`trg_artifact_fill_subject`, `trg_event_supersede_same_type`,
`trg_artifact_normalize`, `trg_verification_normalize`,
`trg_session_normalize_path`, `trg_artifact_normalize_path`,
`trg_project_artifact_normalize_path`, `trg_artifact_unique_active`,
`trg_artifact_matches_event`, `trg_event_input_acyclic`, `trg_subject_id_guard`,
`trg_tag_normalize`, `trg_tag_assignment_normalize`, `trg_tag_guard`,
`trg_tag_namespace_guard`, `trg_tag_assignment_policy`,
`trg_variable_normalize`, `trg_variable_guard`, `trg_variable_value_policy`,
`trg_event_carry_variables`, `trg_artifact_carry_variables`,
`trg_retraction_policy` and the six `trg_*_stamp_login` triggers (on `event`,
`artifact`, `artifact_verification`, `tag_assignment`, `retraction`,
`variable_value`) are there too, as is one `trg_history_<table>` on each
mutable table (`person`, `subject`, `session`, the project tables, the
reference tables, the tag vocabulary tables `tag_namespace` and `tag`, and
`variable`).

The two normalizers are worth knowing about because they *accept* input a
strict reading of the constraints would reject: a `relative_path` written
Windows-style as `G-0421\sess01` is stored as `G-0421/sess01`, and an
upper-case checksum is stored lower-cased. Both need a project/subject fixture
to demonstrate, so they are exercised in §2 through the MATLAB layer rather
than with a standalone `psql` command here.

The scripted version of these checks, and of most of §1.3, is
`tests/schema_test.sql`. It runs in one transaction that it rolls back, so it
leaves `lab_test` empty:

```powershell
psql -U postgres -d lab_test -X -v ON_ERROR_STOP=1 -f tests/schema_test.sql
```

**Pass:** it ends with `schema_test.sql: all assertions passed`.

Finally, the schema ships its own health report; on a freshly loaded, empty
database it should return no rows:

```powershell
psql -U postgres -d lab_test -c "SELECT * FROM lab.fn_check_integrity();"
```

### 1.3 Seed a person and verify the append-only invariant (the most important schema test)

First seed one `person` row. The MATLAB and GUI tests in §2–§3 connect *as* this
person (`PersonEmail = "test@local"`), so it has to exist; `ON CONFLICT` keeps the
step safe to re-run:

```powershell
psql -U postgres -d lab_test -c @'
INSERT INTO lab.person (full_name, email, role)
VALUES ('Test User', 'test@local', 'PI')
ON CONFLICT (lower(email)) WHERE email IS NOT NULL DO NOTHING;
'@
```

Email uniqueness is enforced by `uq_person_email_lower`, a *partial* unique index
on `lower(email)` — so the conflict target has to name the expression **and**
repeat the index predicate. A plain `ON CONFLICT (email)` matches no index and
fails with *"there is no unique or exclusion constraint matching the ON CONFLICT
specification"*.

A **successful** test should look like this:

```powershell
INSERT 0 1
```

Now test the design's core guarantee directly. Insert one `event` row — the base
table of the append-only log — then try to mutate it; the triggers must reject
both `UPDATE` and `DELETE`.

Run the three statements as **three separate `psql -c` calls**. Everything inside
a single `-c` string runs as one implicit transaction, so if they were sent
together the `UPDATE`'s exception would roll the `INSERT` back and the `DELETE`
would never execute — you'd see one error and prove only half the claim:

```powershell
psql -U postgres -d lab_test -c "INSERT INTO lab.event (event_type, occurred_at, notes) VALUES ('analysis', now(), 'immutability probe');"
# Each of the next two MUST fail with the mutation-forbidden error:
psql -U postgres -d lab_test -c "UPDATE lab.event SET notes = 'changed' WHERE notes = 'immutability probe';"
psql -U postgres -d lab_test -c "DELETE FROM lab.event WHERE notes = 'immutability probe';"
```

**Pass:** the `INSERT` succeeds and stays committed; the `UPDATE` and the
`DELETE` each raise an exception from `fn_forbid_mutation()`. If either mutation
*succeeds*, the immutability triggers are broken — stop and fix the schema
before going further.

A **successful** test should look like this (the `CONTEXT:` line number depends
on where the `RAISE` sits in the current function body):

```powershell
INSERT 0 1
ERROR:  UPDATE on lab.event is not allowed: this table is append-only. Insert a superseding row instead.
CONTEXT:  PL/pgSQL function lab.fn_forbid_mutation() line 68 at RAISE
ERROR:  DELETE on lab.event is not allowed: this table is append-only. Insert a superseding row instead.
CONTEXT:  PL/pgSQL function lab.fn_forbid_mutation() line 68 at RAISE
```

Confirm the row survived both attempts — this is the half of the claim the
error messages alone don't prove:

```powershell
psql -U postgres -d lab_test -c "SELECT count(*) FROM lab.event WHERE notes = 'immutability probe';"
```

**Pass:** `1`.

> This probe row is a bare base `event` with no `analysis_event` detail row, so
> `lab.fn_check_integrity()` will now report it as an `event_missing_detail`
> error. That's the check working as designed, not a failure; it clears when you
> drop `lab_test` in §6.

> Why `event` and not `person`: only the append-only log is trigger-protected —
> `event`, every `*_event` detail table, `artifact`, `event_input` and the log
> tables. Reference
> tables like `person` are intentionally mutable, so probing one would report a
> false failure even on a correct schema.

### 1.4 Logins and least privilege

Mirror the production role model ([deployment-windows.md](deployment-windows.md)
§0.1, §1.4): `lab_rw` and `lab_ro` are group roles, never logins, and each
person connects with a login of their own. On a test rig the schema may be
owned by `postgres`; production uses a non-superuser owner. Apply the grants,
create a personal test login and map it to the person seeded in §1.3:

```powershell
psql -U postgres -d lab_test -v ON_ERROR_STOP=1 -f design_docs/grants.sql
psql -U postgres -d lab_test -c "CREATE ROLE test_rw LOGIN PASSWORD 'test-pw' IN ROLE lab_rw;"
psql -U postgres -d lab_test -c "UPDATE lab.person SET db_login = 'test_rw' WHERE email = 'test@local';"
```

Roles are cluster-wide, so on a second run `CREATE ROLE` reports that
`test_rw` already exists; that is fine. Then, as `test_rw`:

```powershell
$env:PGPASSWORD = "test-pw"
psql -h localhost -U test_rw -d lab_test -c "SELECT p.email FROM lab.person p WHERE p.person_id = lab.fn_current_person();"
psql -h localhost -U test_rw -d lab_test -c "UPDATE lab.event SET notes = 'x' WHERE false;"
```

**Pass:** the first prints `test@local` (the login is mapped to the person,
which is what fills `recorded_by` when a client names nobody); the second
fails with `permission denied for table event`. Use `test_rw` for the MATLAB
tests below rather than `postgres`.

The scripted version is `tests/roles_test.sql`: it creates throw-away
logins in `lab_rw` and `lab_ro`, acts as them, and checks everything a
member and a reader may and may not do (attribution, variables, retraction,
the subject-rename guard, `lab.person.db_login`, ...). It expects a database
with no rows, so run it as a superuser against its own scratch database; it
rolls itself back:

```powershell
createdb -U postgres lab_roles
psql -U postgres -d lab_roles -X -q -v ON_ERROR_STOP=1 -f design_docs/schema.sql
psql -U postgres -d lab_roles -X -q -v ON_ERROR_STOP=1 -f design_docs/grants.sql
psql -U postgres -d lab_roles -X -v ON_ERROR_STOP=1 -f tests/roles_test.sql
dropdb -U postgres lab_roles
```

**Pass:** it ends with `roles_test.sql: all assertions passed`.

### 1.5 Test the tools: backup, restore, file verification, dashboard export

`tools/backup_lab.py` and `tools/restore_lab.py` need only Python 3 and the
PostgreSQL client programs, and run as a superuser (`postgres` here, with
`PGPASSWORD` set as in §0.1, or a `pgpass.conf` entry):

```powershell
New-Item -ItemType Directory -Force C:\temp\labbackups | Out-Null     # it must exist
python tools\backup_lab.py -U postgres --host localhost -d lab_test C:\temp\labbackups
python tools\backup_lab.py -U postgres --host localhost --check 1 -d lab_test C:\temp\labbackups
python tools\restore_lab.py -U postgres --host localhost C:\temp\labbackups\lab_test_<stamp>.dump lab_test_restored
dropdb -U postgres lab_test_restored
```

**Pass:** the backup prints `backup_lab: OK: ...`; the check prints `... is
recent and readable`; the restore ends with `restore_lab: OK` after a report
whose row counts match the manifest. Add `--pg-bin "C:\Program
Files\PostgreSQL\16\bin"` if the programs are not on the PATH.

The file verifier and the live dashboard's export have end-to-end checks.
`tests/check_verify_artifacts.py` writes rows, so give it its own database;
it needs `pip install "psycopg[binary]"`:

```powershell
createdb -U postgres lab_verify
psql -U postgres -d lab_verify -X -q -f design_docs/schema.sql
$env:PGUSER = "postgres"; $env:PGDATABASE = "lab_verify"; python tests\check_verify_artifacts.py
$env:PGDATABASE = "lab_test"; python tests\check_lab_data.py
dropdb -U postgres lab_verify
```

**Pass:** `check_verify_artifacts: OK` and `check_lab_data: OK (...)`.
`check_lab_data.py` rolls its fixture back, so `lab_test` is left as it was.

The forms server ([forms.md](forms.md)) has its own end-to-end check. It
creates two throw-away logins, so run it as a superuser, on a database of
its own with the schema and the grants:

```powershell
createdb -U postgres lab_forms
psql -U postgres -d lab_forms -X -q -f design_docs/schema.sql -f design_docs/grants.sql
$env:PGUSER = "postgres"; $env:PGDATABASE = "lab_forms"; python tests\check_forms_server.py
dropdb -U postgres lab_forms
```

**Pass:** `check_forms_server: OK (...)`. It signs in through the API,
publishes templates, records, corrects and withdraws entries, and compares
each subject's CSV with the database byte for byte, including a file locked
as Excel locks it and a file edited by hand.

---

## 2. Test the MATLAB interface (`@CarasLabDB`)

### 2.1 Confirm the toolchain

```matlab
ver                                  % MATLAB >= 24.2 (R2024b)
license('test','Database_Toolbox')   % 1 = licensed
exist('postgresql')                  % 2 = native interface present
```

If `exist('postgresql')` is `0`, install Database Toolbox before continuing —
the class raises `CarasLabDB:noDatabaseToolbox` at construction without it.

### 2.2 Put the class folders on the path

Add the **repo root** (the parent of `@CarasLabDB`), never the `@`-folder itself:

```matlab
addpath('C:\src\CarasLabDB');
% savepath;   % only if you want it to persist; for a test rig you can skip
```

### 2.3 Connection smoke test

```matlab
db = CarasLabDB( ...
    Username     = "test_rw", ...
    Password     = "test-pw", ...
    Server       = "localhost", ...
    Port         = 5432, ...
    DatabaseName = "lab_test", ...
    PersonEmail  = "test@local");     % optional: test_rw is mapped to this person (§1.4)
assert(db.isOpen())
```

**Pass:** constructs without error and `isOpen()` is true. Common failures and
what they mean:

- `CarasLabDB:connectionFailed` — wrong server/port/credentials, DB not running,
  or (on a server) a missing `pg_hba.conf` rule.
- `CarasLabDB:personNotFound` — no `person` row matches `PersonEmail`; seed one
  (§1.3 did this) or use `addPerson` / `setPerson`.

### 2.4 End-to-end walkthrough

Run `examples/carasLabDB_demo.m`, editing the connection block at the top to
point at `localhost` / `lab_test` / `test_rw`. It exercises the full path the
real system depends on:

1. Reference/lookup rows (`addStorageRoot`, `addProbe`).
2. Project + members + project artifacts.
3. Subject and session.
4. A **recording** event and its raw `artifact`.
5. An **analysis** event that consumes the raw artifact (`addEventInput`) and
   produces a spikes artifact — this builds the provenance DAG.
6. Retrieval via the `get*` methods (defaulting to the `*_active` views).
7. `artifactLineage(spikesId, Direction="up")` — walks the lineage function.
8. **Tagging**: `setTag` / `addTag` / `getEntityTags` / `findByTags` and the
   `Tags=` filter on `getArtifacts` / `getSubjects`.
9. A **supersede** correction on a husbandry (weight) event, proving append-only
   corrections work end-to-end; the event's `qc:pass` tag is carried to the
   correction.

**Pass:** the script runs to completion, the `disp()` outputs show the rows you
inserted, `lineage` shows the raw file as an ancestor of the spikes file, and the
supersede prints `weight event … superseded by …`.

### 2.5 Exercise the remaining event types

The demo covers recording, analysis, and husbandry. To test the full surface,
insert one of **each** event type so every detail table and its
`(event_id, event_type)` composite-FK path is covered:

```matlab
db.addBirthEvent(...);      db.addSurgeryEvent(...);
db.addBehaviorEvent(...);   db.addEndpointEvent(...);
db.addHistologyEvent(...);  % plus recording/analysis/husbandry from the demo
```

Fill required Name=Value args per each method's `arguments` block. **Pass:** each
insert returns an event id and appears in `db.getEvents(SubjectId=...)`.

### 2.6 Verify the read-only SQL guard

The ad-hoc query path must refuse writes. Confirm a `SELECT` works and a write is
rejected:

```matlab
n = db.runQuery("SELECT count(*) AS n FROM lab.event_active;");   % works
% This must error (syntactic guard and/or READ ONLY transaction):
try
    db.runReadOnlyQuery("INSERT INTO lab.person(full_name,email) VALUES('x','y@z');");
    error("guard failed — write was allowed");
catch ME
    fprintf("read-only guard rejected write as expected: %s\n", ME.message);
end
```

**Pass:** the `SELECT` returns a count; the `INSERT` is rejected.

### 2.7 Automated tests (`tests/matlab`)

The class and the GUI have a `matlab.unittest` suite. `TagTests` covers tag
syntax, the vocabulary, assigning tags, the tag filters (checked against
`lab.fn_find_by_tags`), carry-forward on correction, subject rename, argument
validation, transactions, and `examples/carasLabDB_demo.m`. `VariableTests`
covers variables, retraction, the person-from-login mapping, the husbandry
batch and file registration. `TagGuiTests` drives `CarasLabDBApp`'s browse
filters, tag editor and variables editor with `matlab.uitest`.

CI runs the whole suite on Linux in MATLAB R2024b, R2025a and the latest
release (the `matlab` job of `.github/workflows/tests.yml`; its entry point is
`tests/run_matlab_tests.m`). It does not run on Windows there, so run it once
on a lab workstation as below.

It does not use `lab_test`. Its shared fixture, `LabScratchDb`, creates a
database `lab_mtest`, applies `schema.sql` and `grants.sql`, adds a
non-superuser login in `lab_rw` (so the grants are exercised), and drops all of
it again afterwards. That needs a login allowed to create databases and roles,
so the database tests are opt-in:

```matlab
setenv("CARASLABDB_MTEST_ADMIN", "postgres")                  % CREATEDB + CREATEROLE
setenv("CARASLABDB_MTEST_ADMIN_PASSWORD", "...")              % unless trust / pgpass
setenv("CARASLABDB_MTEST_PGBIN", "C:\Program Files\PostgreSQL\16\bin")  % if psql is not on the PATH
results = runtests("tests/matlab")
```

`CARASLABDB_MTEST_HOST` and `CARASLABDB_MTEST_PORT` default to `localhost` and
`5432`. Use a development server, never the lab's production one; the fixture
will not touch an existing `lab_mtest` it did not create. Without
`CARASLABDB_MTEST_ADMIN`, or without Database Toolbox, the database tests are
reported as Incomplete and only the database-free ones run
(`runtests("tests/matlab", Tag="NoDatabase")`, which works on any supported
release). `TagGuiTests` opens and closes the app's windows for about four
minutes; do not interact with them while it runs. It saves your
`CarasLabDBApp` preferences first and restores them afterwards. The fixture
runs `psql`; on Linux it does so without MATLAB's own library path, with no
pager and with no input, because MATLAB runs commands on a pseudo-terminal.

**Pass:** no failures. The suite cannot press real keys (`matlab.uitest` has
no key-press gesture), so it tests each shortcut through the window's
`KeyPressFcn`. Check by hand that Ctrl+T works from the keyboard and, in the
tag editor, Ctrl+Enter, Ctrl+S, Delete, Ctrl+R, Esc and Ctrl+?, and that
Enter in the editor's Value box moves focus to Add or Set.

### 2.8 Clean up

```matlab
delete(db);   % closes the connection this object opened
```

---

## 3. Test the GUI (`@CarasLabDBApp`)

With the class folders already on the path and `lab_test` populated by §2:

```matlab
app = CarasLabDBApp();          % Option A: opens a login dialog
% app = CarasLabDBApp(db);      % Option B: reuse an already-open connection
```

Log in against `localhost` / `lab_test` / `test_rw`, then verify each surface
(mirrors `examples/carasLabDBApp_demo.m`):

- [ ] Subjects / Sessions / Events / Artifacts tabs populate with the rows §2 inserted.
- [ ] Quick subject search (substring and regex) filters the table.
- [ ] Column filters in Exact / Contains / Regex / Range modes work.
- [ ] "Active only" toggles between `*_active` views and full history (superseded
      rows appear when unchecked).
- [ ] "Export → WS" copies the visible table into the base workspace.
- [ ] "Add Event" opens a type-aware form and inserts.
- [ ] Select a row → "Edit / Supersede" performs an append-only correction.
- [ ] The Tags field (e.g. `stage:preprocessed`) filters the table; Ctrl+T on a
      selected row opens the tag editor.
- [ ] Ctrl+L on a selected row opens the variables editor; a value set there
      appears in `lab.variable_current`.
- [ ] Ctrl+Delete retracts the selected event or artifact (with a reason); it
      leaves the table while "Active only" is on.
- [ ] Ctrl+H opens the daily husbandry grid and writes the day's weights in
      one go; Ctrl+I shows the integrity report.
- [ ] Ctrl+? lists the shortcuts.
- [ ] "Custom SQL" tab runs a `SELECT`/`WITH` query and **rejects** a write.
- [ ] Closing the window persists preferences (reopen: fields remembered, password not).

```matlab
delete(app);
```

**Pass:** all boxes tick. The GUI is a thin front end over the class, so if §2
passed, failures here are UI-layer issues (form specs, filter WHERE building),
not data-layer.

---

## 4. Test the web dashboard

The dashboard has no backend and does not touch Postgres, so it can be tested
independently:

```powershell
python -m http.server 8777 --directory web    # matches the lab-web launch config
```

Open <http://localhost:8777/lab-dashboard.html> (or just double-click the file;
an internet connection is needed once to fetch Chart.js from its CDN).

**Pass:** the page renders all charts from `window.LAB_DATA`, the browser
console shows no errors, and controls/filters respond. Because data is generated
in-page by a fixed-seed mulberry32 PRNG, the charts are deterministic across
reloads.

### 4.1 The forms page

The forms page needs its server and a database (`lab_test` after §1.4, with a
member login mapped to a person):

```powershell
psql -U postgres -d lab_test -c "CREATE ROLE dev_member LOGIN PASSWORD 'devpass' IN ROLE lab_rw"
psql -U postgres -d lab_test -c "INSERT INTO lab.person (full_name, db_login) VALUES ('Dev Member', 'dev_member')"
# PGUSER is only the login the server rewrites waiting CSV files with;
# members sign in on the page with their own.
$env:PGUSER = "postgres"; $env:PGDATABASE = "lab_test"
python web\forms\server.py --csv-root C:\temp\forms-csv --insecure-cookie
# open http://127.0.0.1:8779/ and sign in as dev_member
```

Work through it by hand. Nothing in CI drives the page in a browser.

- [ ] Templates → New template: add a number field with units and a
      minimum, a choice and a required yes/no; add a subject variable to *Top
      of the form*. *Checks* says there are no problems; Ctrl+S publishes
      version 1.
- [ ] Enter data: Ctrl+K, find a subject, add the template for it, fill it
      in, Ctrl+S. The entry is listed, and
      `C:\temp\forms-csv\<project>\<subject>.csv` has the row, with the
      number exactly as typed (`1350.50`).
- [ ] Type `1e3` in the number field: it is refused with the reason.
- [ ] Stop the server, then save an entry. The page says the server cannot
      be reached and the *Unsent* tab counts 1. Start the server again, and
      within two minutes, or at once with *Send now*, the count drops to 0
      and the entry is in the CSV, once.
- [ ] Correct an entry and change a note (Ctrl+E on the row): the CSV shows
      the current values, and *history* lists both notes.
- [ ] Open the CSV in Excel and save an entry: the page says the file is
      waiting; close Excel and within a minute the file is rewritten.
- [ ] `checkIntegrity()` in MATLAB (or `SELECT * FROM lab.fn_check_integrity()`)
      reports no `observation_invalid`.

---

## 5. Full local acceptance checklist

Run top to bottom against `lab_test` before you deploy to a server:

- [ ] `schema.sql` loads clean with `ON_ERROR_STOP=1`.
- [ ] Schema objects present (`\dt`, `\dv`, `\df` in the `lab` schema).
- [ ] `UPDATE`/`DELETE` on an immutable row are rejected by `fn_forbid_mutation()`.
- [ ] `test_rw` (a login in `lab_rw`) can `SELECT`/`INSERT`, cannot `UPDATE` an
      event, and is resolved by `lab.fn_current_person()`; `tests/roles_test.sql`
      passes on a fresh scratch database (§1.4).
- [ ] Backup, `--check` and restore succeed, and `check_verify_artifacts.py` /
      `check_lab_data.py` print OK (§1.5).
- [ ] MATLAB `ver` / `Database_Toolbox` / `exist('postgresql')` all check out.
- [ ] `CarasLabDB(...)` connects to `localhost`/`lab_test` and `isOpen()`.
- [ ] `carasLabDB_demo.m` runs end-to-end; lineage and supersede work.
- [ ] Every event type inserts and retrieves.
- [ ] Tags: `setTag` replaces a `stage`, `findByTags` / `Tags=` find it, and a
      superseded event's correction carries its tags.
- [ ] Variables: `setVariable` then `getVariables` shows the value, a second
      `setVariable` updates it (`History=true` shows both), and a superseded
      event's correction carries its variables; `retractEvent` hides an event
      from `getEvents`; `checkIntegrity()` returns a table.
- [ ] `runtests("tests/matlab")` passes with `CARASLABDB_MTEST_ADMIN` set (§2.7).
- [ ] Read-only SQL guard rejects a write from both the class and the GUI.
- [ ] `CarasLabDBApp` browses, filters, exports, adds, and supersedes.
- [ ] `lab-dashboard.html` renders with no console errors; the Tags filter
      (`#`) narrows the tables.
- [ ] `check_forms_server.py` prints OK (§1.5), and the forms page passes
      its checklist (§4.1).

---

## 6. Tear down the test rig

```powershell
dropdb -U postgres --if-exists lab_test
```

Because everything ran against `lab_test` on `localhost`, dropping that database
removes all test data. Nothing you did here touches a production `lab` database.

---

## 7. From local test to server deployment

Once the checklist in §5 is green, the same steps map onto the server with two
substitutions:

1. Create the **real** `lab` database instead of `lab_test`, owned by a
   non-superuser owner that applies `schema.sql` and `grants.sql`
   (`deployment-windows.md` §1.2–§1.3), and (for a shared
   server) enable network access — `listen_addresses`, `pg_hba.conf`, firewall —
   per `deployment-windows.md` §1.5.
2. Point MATLAB and the GUI at the server hostname/IP instead of `localhost`, and
   each person's own login (see `deployment-windows.md` §1.4).

Re-run the §2.3 connection smoke test and the §2.4 walkthrough (against a
**scratch** subject you can leave in place or supersede) from a researcher
workstation to confirm network + `pg_hba.conf` work end-to-end. Then seed the real
`person` and reference rows and hand it to users.
