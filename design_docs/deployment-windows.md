# Deploying CarasLabDB on Windows 11

This guide walks through standing up the three parts of the system on a fresh
Windows 11 machine:

1. **The PostgreSQL database** — applies `design_docs/schema.sql` to a running
   Postgres 14+ server. This is the actual data store.
2. **The MATLAB interface** (`@CarasLabDB`) and **GUI** (`@CarasLabDBApp`) —
   the tools researchers use to read and write metadata.
3. **The web dashboard** (`web/ephys-dashboard.html`) — a standalone, static
   visualization page. It runs on synthetic in-page data and does **not** talk
   to the database, so it can be deployed by itself if that is all you need.

You do not need all three on every machine. A researcher's workstation
typically needs #2 (MATLAB) plus network access to a shared database server. A
lab server hosts #1. The dashboard (#3) can live anywhere a browser or static
file server can reach it.

Commands below are for **PowerShell** (the default Windows 11 shell). Run an
elevated (Administrator) PowerShell only where noted.

---

## 0. Prerequisites overview

| Component | Requires | Where it runs |
|-----------|----------|---------------|
| Database  | PostgreSQL 14 or newer | Lab server (or localhost for testing) |
| MATLAB interface + GUI | MATLAB **R2025a+** with **Database Toolbox** | Each researcher workstation |
| Web dashboard | Any modern browser; Python (optional, only to serve it) | Anywhere |

The database and MATLAB pieces can both live on one machine for a single-user
or evaluation setup. For lab use, run Postgres on a shared server and point
each workstation's MATLAB at it over the network.

---

## 1. Deploy the PostgreSQL database

### 1.1 Install PostgreSQL

1. Download the Windows installer (EDB build) from
   <https://www.postgresql.org/download/windows/>. Choose **version 14 or
   later** (16 is a good default).
2. Run the installer. During setup:
   - Set and record a password for the `postgres` superuser.
   - Keep the default port **5432** unless it is already in use.
   - The Stack Builder step at the end is optional and can be skipped.
3. The installer registers **PostgreSQL** as a Windows service that starts
   automatically on boot. Confirm it is running:

   ```powershell
   Get-Service postgresql*
   ```

4. Add the Postgres `bin` directory to your `PATH` for the current session so
   `psql` and `createdb` are available (adjust the version number to match
   your install):

   ```powershell
   $env:Path += ";C:\Program Files\PostgreSQL\16\bin"
   ```

   To make this permanent, add that path via **Settings → System → About →
   Advanced system settings → Environment Variables**, or:

   ```powershell
   [Environment]::SetEnvironmentVariable(
       "Path",
       [Environment]::GetEnvironmentVariable("Path","User") + ";C:\Program Files\PostgreSQL\16\bin",
       "User")
   ```

### 1.2 Create the database and apply the schema

From the repo root (`C:\src\CarasLabDB`):

```powershell
# You will be prompted for the 'postgres' password set during install.
createdb -U postgres ephys
psql -U postgres -d ephys -f design_docs/schema.sql
```

`schema.sql` creates the `ephys` schema, all tables, triggers, views, and the
`fn_artifact_lineage` function. It is safe to re-run against a fresh database.
On PostgreSQL 13+, `gen_random_uuid()` is built in; only on **older** servers
would you need to uncomment the `CREATE EXTENSION pgcrypto;` line at the top of
the file — not relevant if you installed 14+.

Verify the schema loaded:

```powershell
psql -U postgres -d ephys -c "\dt ephys.*"
```

You should see the reference tables (`person`, `storage_root`, `species`, …),
the `event` base table, the per-type `*_event` detail tables, `artifact`, and
`event_input`.

### 1.3 Create application roles (recommended)

Do not have researchers connect as the `postgres` superuser. Create a
read/write role for the MATLAB clients:

```powershell
psql -U postgres -d ephys -c "CREATE ROLE ephys_rw LOGIN PASSWORD 'CHANGE_ME';"
psql -U postgres -d ephys -c "GRANT USAGE ON SCHEMA ephys TO ephys_rw;"
psql -U postgres -d ephys -c "GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA ephys TO ephys_rw;"
psql -U postgres -d ephys -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ephys TO ephys_rw;"
```

Note the schema is **append-only**: `UPDATE`/`DELETE` are blocked by triggers,
so `INSERT` + `SELECT` is the correct privilege set for normal use.
Corrections happen through superseding inserts, not updates.

Seed at least one `person` row (the MATLAB client resolves a "current person"
for provenance columns) and your reference/lookup rows (`storage_root`,
`species`, etc.) before real use.

### 1.4 Allow network connections (only if the DB serves other machines)

If MATLAB will run on the **same** machine as Postgres, skip this section —
`localhost` already works.

For a shared server, edit the two config files in the data directory
(default `C:\Program Files\PostgreSQL\16\data`):

- **`postgresql.conf`** — set `listen_addresses = '*'` (or the specific server
  IP).
- **`pg_hba.conf`** — add a line allowing your lab subnet with password auth,
  e.g.:

  ```
  host    ephys    ephys_rw    192.168.1.0/24    scram-sha-256
  ```

Then restart the service (elevated PowerShell) and open the firewall port:

```powershell
Restart-Service postgresql-x64-16
New-NetFirewallRule -DisplayName "PostgreSQL 5432" -Direction Inbound `
    -Protocol TCP -LocalPort 5432 -Action Allow
```

Restrict the firewall rule and `pg_hba.conf` to trusted subnets; do not expose
5432 to the open internet.

---

## 2. Deploy the MATLAB interface and GUI

### 2.1 Requirements

- **MATLAB R2025a or later** (the code uses `arguments`-block features and
  validation behavior specific to R2025a).
- **Database Toolbox** — the class connects via the native `postgresql()`
  interface. No ODBC DSN or JDBC `.jar` configuration is required.

Confirm both are present in MATLAB:

```matlab
ver                              % check MATLAB version >= 25.1 (R2025a)
license('test','Database_Toolbox')   % returns 1 if licensed
exist('postgresql')              % returns 2 if the native interface is available
```

If `exist('postgresql')` returns `0`, the Database Toolbox is not installed —
add it via **Home → Add-Ons → Get Add-Ons** or the MATLAB installer.

### 2.2 Get the code onto the machine and add it to the path

Place the repo somewhere stable, e.g. `C:\src\CarasLabDB`. Add the **repo
root** (not the `@CarasLabDB` folder itself) to the MATLAB path so the
class folders `@CarasLabDB` and `@CarasLabDBApp` are visible as classes:

```matlab
addpath('C:\src\CarasLabDB');
savepath;                        % persist across MATLAB sessions
```

> Add the parent directory of `@CarasLabDB`, never the `@`-folder itself.
> That is the standard MATLAB class-folder convention.

### 2.3 Connect and smoke-test

```matlab
db = CarasLabDB( ...
    Username="ephys_rw", ...
    Password="CHANGE_ME", ...
    Server="localhost", ...      % or the DB server hostname/IP
    Port=5432, ...
    DatabaseName="ephys", ...
    PersonEmail="dstolz@umd.edu");   % must match a person row's email
```

A successful construction opens the connection and resolves the current
person. If it errors with `CarasLabDB:noDatabaseToolbox`, the toolbox is
missing; `CarasLabDB:connectionFailed` means the server, port, credentials, or
`pg_hba.conf` rule is wrong.

Then walk through `examples/carasLabDB_demo.m`, which exercises the full flow
(reference data → subject/session → recording event → artifact → analysis
event → retrieval → supersede correction) against a live database.

### 2.4 Launch the GUI

```matlab
app = CarasLabDBApp();      % opens a login dialog
% or, reusing an already-open connection:
app = CarasLabDBApp(db);
```

The app persists window geometry, the connection (minus password), the active
-view toggle, and SQL history between sessions via MATLAB preferences, so each
user's settings follow their Windows profile.

---

## 3. Deploy the web dashboard

The dashboard is a single self-contained file, `web/ephys-dashboard.html`
(Chart.js is loaded from a CDN; all data is generated in-page). It has **no
backend** and does not connect to Postgres.

### Option A — open directly

Double-click `web/ephys-dashboard.html`, or open it in any browser. It renders
entirely from in-page synthetic data. An internet connection is needed the
first time so the browser can fetch Chart.js from the CDN.

### Option B — serve it over HTTP (matches the repo's launch config)

If you have Python installed:

```powershell
python -m http.server 8777 --directory web
```

Then browse to <http://localhost:8777/ephys-dashboard.html>. This mirrors the
`ephys-web` configuration already defined in `.claude/launch.json`.

For a persistent internal deployment, copy `ephys-dashboard.html` to the web
root of any static host (IIS, nginx, a network share opened in a browser,
etc.) — no server-side runtime is required.

---

## 4. Quick verification checklist

- [ ] `Get-Service postgresql*` shows the service **Running**.
- [ ] `psql -U postgres -d ephys -c "\dt ephys.*"` lists the schema tables.
- [ ] A non-superuser role (`ephys_rw`) can `SELECT`/`INSERT` but not `UPDATE`.
- [ ] MATLAB: `ver`, `license('test','Database_Toolbox')`, and
      `exist('postgresql')` all check out.
- [ ] `CarasLabDB(...)` constructs without error and
      `examples/carasLabDB_demo.m` runs against the live DB.
- [ ] `CarasLabDBApp()` opens and connects through its login dialog.
- [ ] `ephys-dashboard.html` renders charts in the browser.

---

## 5. Backups and maintenance

The event log is append-only and correction history is meaningful, so back up
the whole database rather than individual tables:

```powershell
# Nightly logical backup (schedule via Task Scheduler).
pg_dump -U postgres -Fc ephys -f "D:\backups\ephys_$(Get-Date -Format yyyyMMdd).dump"
```

Restore with `pg_restore -U postgres -d ephys_restored backup.dump` into a
fresh database. Keep backups on separate storage from the live data directory,
and test a restore periodically.
