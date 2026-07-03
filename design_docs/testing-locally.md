# Testing CarasLabDB locally before server deployment

This document describes how to stand up and exercise the **entire** package on a
single local machine so you can catch problems before rolling the database out
to a shared lab server. It complements [`deployment-windows.md`](deployment-windows.md):
that guide is about *installing* the system; this one is about *proving it works*.

The goal of local testing is a throwaway `lab` database on `localhost` that you
can create, exercise end-to-end through both the MATLAB class and the GUI, then
drop — repeatedly — without touching production data. There is no automated test
suite in this repo, so "testing" here means a disciplined manual walkthrough with
explicit pass/fail checks.

The three parts and how each is tested:

| Part | What you verify | Needs a live DB? |
|------|-----------------|------------------|
| PostgreSQL schema (`design_docs/schema.sql`) | DDL loads; append-only triggers, views, and lineage function behave | — |
| MATLAB interface (`@CarasLabDB`) + GUI (`@CarasLabDBApp`) | Connect, insert every event type, retrieve, supersede, read-only SQL guard | Yes |
| Web dashboard (`web/lab-dashboard.html`) | Renders from in-page synthetic data | No |

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
- **MATLAB R2025a+** with **Database Toolbox**.
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
of plowing through — so a clean run with no error output means all 46 `CREATE`
statements (tables, views, triggers, the `fn_artifact_lineage` function, roles,
indexes) applied. On PostgreSQL 14+ `gen_random_uuid()` is built in; you should
**not** need the `pgcrypto` extension.

**Pass:** command exits 0 with no `ERROR:` lines.

### 1.2 Verify the objects exist

```powershell
psql -U postgres -d lab_test -c "\dt lab.*"      # tables
psql -U postgres -d lab_test -c "\dv lab.*"      # views (expect *_active)
psql -U postgres -d lab_test -c "\df lab.*"      # functions (fn_artifact_lineage, fn_forbid_mutation)
```

**Pass:** you see the reference tables (`person`, `storage_root`, `species`, …),
the `event` base table, the eight `*_event` detail tables, `artifact`,
`event_input`, the `event_active` / `artifact_active` views, and both functions.

### 1.3 Seed a person and verify the append-only invariant (the most important schema test)

First seed one `person` row. The MATLAB and GUI tests in §2–§3 connect *as* this
person (`PersonEmail = "test@local"`), so it has to exist; `ON CONFLICT` keeps the
step safe to re-run:

```powershell
psql -U postgres -d lab_test -c @'
INSERT INTO lab.person (full_name, email, role)
VALUES ('Test User', 'test@local', 'PI')
ON CONFLICT (email) DO NOTHING;
'@
```

A **successful** test should look like this:

```powershell
INSERT 0 1
```

Now test the design's core guarantee directly. Insert one `event` row — the base
table of the append-only log — then try to mutate it; the triggers must reject
both `UPDATE` and `DELETE`:

```powershell
psql -U postgres -d lab_test -v ON_ERROR_STOP=0 -c @'
INSERT INTO lab.event (event_type, occurred_at, notes)
VALUES ('analysis', now(), 'immutability probe');
-- Both of the next two statements MUST fail with the mutation-forbidden error:
UPDATE lab.event SET notes = 'changed' WHERE notes = 'immutability probe';
DELETE FROM lab.event                  WHERE notes = 'immutability probe';
'@
```

**Pass:** the `INSERT` succeeds; the `UPDATE` and `DELETE` each raise an exception
from `fn_forbid_mutation()`. If either mutation *succeeds*, the immutability
triggers are broken — stop and fix the schema before going further.

A **successful** test should look like this:

```powershell
ERROR:  UPDATE on lab.event is not allowed: this table is append-only. Insert a superseding row instead.
CONTEXT:  PL/pgSQL function lab.fn_forbid_mutation() line 3 at RAISE
```

> Why `event` and not `person`: only the append-only log is trigger-protected —
> `event`, every `*_event` detail table, `artifact`, and `event_input`. Reference
> tables like `person` are intentionally mutable, so probing one would report a
> false failure even on a correct schema.

### 1.4 Create the application role and confirm least privilege

Mirror what the server will run with — researchers connect as a non-superuser
with INSERT/SELECT only:

```powershell
psql -U postgres -d lab_test -c "CREATE ROLE lab_rw LOGIN PASSWORD 'test-pw';"
psql -U postgres -d lab_test -c "GRANT USAGE ON SCHEMA lab TO lab_rw;"
psql -U postgres -d lab_test -c "GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA lab TO lab_rw;"
psql -U postgres -d lab_test -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA lab TO lab_rw;"
```

Confirm this role can read/insert but is blocked from UPDATE by both privilege
and trigger. Use it for the MATLAB tests below rather than `postgres`.

---

## 2. Test the MATLAB interface (`@CarasLabDB`)

### 2.1 Confirm the toolchain

```matlab
ver                                  % MATLAB >= 25.1 (R2025a)
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
    Username     = "lab_rw", ...
    Password     = "test-pw", ...
    Server       = "localhost", ...
    Port         = 5432, ...
    DatabaseName = "lab_test", ...
    PersonEmail  = "test@local");     % must match the seeded person row
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
point at `localhost` / `lab_test` / `lab_rw`. It exercises the full path the
real system depends on:

1. Reference/lookup rows (`addStorageRoot`, `addProbe`).
2. Project + members + project artifacts.
3. Subject and session.
4. A **recording** event and its raw `artifact`.
5. An **analysis** event that consumes the raw artifact (`addEventInput`) and
   produces a spikes artifact — this builds the provenance DAG.
6. Retrieval via the `get*` methods (defaulting to the `*_active` views).
7. `artifactLineage(spikesId, Direction="up")` — walks the lineage function.
8. A **supersede** correction on a husbandry (weight) event, proving append-only
   corrections work end-to-end.

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

### 2.7 Clean up

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

Log in against `localhost` / `lab_test` / `lab_rw`, then verify each surface
(mirrors `examples/carasLabDBApp_demo.m`):

- [ ] Subjects / Sessions / Events / Artifacts tabs populate with the rows §2 inserted.
- [ ] Quick subject search (substring and regex) filters the table.
- [ ] Column filters in Exact / Contains / Regex / Range modes work.
- [ ] "Active only" toggles between `*_active` views and full history (superseded
      rows appear when unchecked).
- [ ] "Export → WS" copies the visible table into the base workspace.
- [ ] "Add Event" opens a type-aware form and inserts.
- [ ] Select a row → "Edit / Supersede" performs an append-only correction.
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

---

## 5. Full local acceptance checklist

Run top to bottom against `lab_test` before you deploy to a server:

- [ ] `schema.sql` loads clean with `ON_ERROR_STOP=1`.
- [ ] Schema objects present (`\dt`, `\dv`, `\df` in the `lab` schema).
- [ ] `UPDATE`/`DELETE` on an immutable row are rejected by `fn_forbid_mutation()`.
- [ ] `lab_rw` role can `SELECT`/`INSERT`, cannot `UPDATE`.
- [ ] MATLAB `ver` / `Database_Toolbox` / `exist('postgresql')` all check out.
- [ ] `CarasLabDB(...)` connects to `localhost`/`lab_test` and `isOpen()`.
- [ ] `carasLabDB_demo.m` runs end-to-end; lineage and supersede work.
- [ ] Every event type inserts and retrieves.
- [ ] Read-only SQL guard rejects a write from both the class and the GUI.
- [ ] `CarasLabDBApp` browses, filters, exports, adds, and supersedes.
- [ ] `lab-dashboard.html` renders with no console errors.

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

1. Create the **real** `lab` database instead of `lab_test`, and (for a shared
   server) enable network access — `listen_addresses`, `pg_hba.conf`, firewall —
   per `deployment-windows.md` §1.4.
2. Point MATLAB and the GUI at the server hostname/IP instead of `localhost`, and
   use the production `lab_rw` password.

Re-run the §2.3 connection smoke test and the §2.4 walkthrough (against a
**scratch** subject you can leave in place or supersede) from a researcher
workstation to confirm network + `pg_hba.conf` work end-to-end. Then seed the real
`person` and reference rows and hand it to users.

```