# Deploying CarasLabDB on Linux

This guide walks through standing up the three parts of the system on a fresh
Linux server or workstation (Debian/Ubuntu and RHEL/Rocky/Fedora commands are
both given):

1. **The PostgreSQL database** — applies `design_docs/schema.sql` to a running
   Postgres 14+ server. This is the actual data store.
2. **The MATLAB interface** (`@CarasLabDB`) and **GUI** (`@CarasLabDBApp`) —
   the tools researchers use to read and write metadata.
3. **The web dashboard** (`web/lab-dashboard.html`) — a standalone, static
   visualization page. It runs on synthetic in-page data and does **not** talk
   to the database, so it can be deployed by itself if that is all you need.
   A **live** variant (`web/live/`) that reads the real database is also
   covered.

You do not need all three on every machine. A researcher's workstation
typically needs #2 (MATLAB) plus network access to a shared database server. A
lab server hosts #1 (and often the live dashboard). The static dashboard (#3)
can live anywhere a browser or static file server can reach it.

Commands below are for **bash**. Lines prefixed with `sudo` need root; the rest
run as your normal login user.

---

## 0. Prerequisites overview

| Component | Requires | Where it runs |
|-----------|----------|---------------|
| Database  | PostgreSQL 14 or newer | Lab server (or localhost for testing) |
| MATLAB interface + GUI | MATLAB **R2025a+** with **Database Toolbox** | Each researcher workstation |
| Web dashboard | Any modern browser; Python 3 (optional, only to serve it) | Anywhere |

The database and MATLAB pieces can both live on one machine for a single-user
or evaluation setup. For lab use, run Postgres on a shared server and point
each workstation's MATLAB at it over the network.

This guide assumes the repo is checked out at `/srv/CarasLabDB` on the server;
substitute your actual path throughout.

---

## 1. Deploy the PostgreSQL database

### 1.1 Install PostgreSQL

Use your distribution's package (Ubuntu 24.04 and current Fedora/Rocky ship
Postgres 16). For a specific newer version, add the official PGDG repository
from <https://www.postgresql.org/download/linux/> instead.

**Debian / Ubuntu** — the package auto-creates a cluster and starts the service:

```bash
sudo apt update
sudo apt install -y postgresql postgresql-client
```

**RHEL / Rocky / Fedora** — you must initialize the data directory and enable
the service yourself:

```bash
sudo dnf install -y postgresql-server postgresql
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```

Confirm the service is running (both families use systemd):

```bash
systemctl status postgresql
```

On Linux, `psql`, `createdb`, and friends are installed on the system `PATH` by
the client package — no `PATH` editing is needed as on Windows.

### 1.2 Create the database and apply the schema

By default Postgres on Linux uses **peer authentication** for local socket
connections, so administer it as the `postgres` OS user with `sudo -u postgres`.
From the repo root (`/srv/CarasLabDB`):

```bash
sudo -u postgres createdb lab
sudo -u postgres psql -d lab -f design_docs/schema.sql
```

`schema.sql` creates the `lab` schema, all tables, triggers, views, and the
`fn_artifact_lineage` function. It is safe to re-run against a fresh database.
On PostgreSQL 13+, `gen_random_uuid()` is built in; only on **older** servers
would you need to uncomment the `CREATE EXTENSION pgcrypto;` line at the top of
the file — not relevant if you installed 14+.

Verify the schema loaded:

```bash
sudo -u postgres psql -d lab -c "\dt lab.*"
```

You should see the reference tables (`person`, `storage_root`, `species`, …),
the `event` base table, the per-type `*_event` detail tables, `artifact`, and
`event_input`.

### 1.3 Create application roles (recommended)

Do not have researchers connect as the `postgres` superuser. Create a
read/write role for the MATLAB clients:

```bash
sudo -u postgres psql -d lab <<'SQL'
CREATE ROLE lab_rw LOGIN PASSWORD 'CHANGE_ME';
GRANT USAGE ON SCHEMA lab TO lab_rw;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA lab TO lab_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA lab TO lab_rw;
SQL
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

For a shared server, edit the two config files. Their location differs by
distribution:

- Debian/Ubuntu: `/etc/postgresql/16/main/`
- RHEL/Rocky/Fedora: `/var/lib/pgsql/data/`

(`sudo -u postgres psql -c 'SHOW config_file;'` prints the exact path.)

- **`postgresql.conf`** — set `listen_addresses = '*'` (or the specific server
  IP).
- **`pg_hba.conf`** — add a line allowing your lab subnet with password auth,
  e.g.:

  ```
  host    lab    lab_rw    192.168.1.0/24    scram-sha-256
  ```

Then reload/restart the service and open the firewall port.

```bash
sudo systemctl restart postgresql
```

**Firewall — ufw (Debian/Ubuntu):**

```bash
sudo ufw allow from 192.168.1.0/24 to any port 5432 proto tcp
```

**Firewall — firewalld (RHEL/Rocky/Fedora):**

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="5432" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Restrict the firewall rule and `pg_hba.conf` to trusted subnets; do not expose
5432 to the open internet.

---

## 2. Deploy the MATLAB interface and GUI

### 2.1 Requirements

- **MATLAB R2025a or later** (the code uses `arguments`-block features and
  validation behavior specific to R2025a). The Linux installer places MATLAB
  under `/usr/local/MATLAB/R2025a` by default; launch it with `matlab` (symlink
  the binary onto your `PATH` if the installer did not: `sudo ln -s
  /usr/local/MATLAB/R2025a/bin/matlab /usr/local/bin/matlab`).
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

Place the repo somewhere stable, e.g. `/srv/CarasLabDB` or `~/CarasLabDB`. Add
the **repo root** (not the `@CarasLabDB` folder itself) to the MATLAB path so
the class folders `@CarasLabDB` and `@CarasLabDBApp` are visible as classes:

```matlab
addpath('/srv/CarasLabDB');
savepath;                        % persist across MATLAB sessions
```

> Add the parent directory of `@CarasLabDB`, never the `@`-folder itself.
> That is the standard MATLAB class-folder convention.

Note that Linux filesystems are case-sensitive: the class-folder name must be
exactly `@CarasLabDB` for MATLAB to resolve the `CarasLabDB` class.

### 2.3 Connect and smoke-test

```matlab
db = CarasLabDB( ...
    Username="lab_rw", ...
    Password="CHANGE_ME", ...
    Server="localhost", ...      % or the DB server hostname/IP
    Port=5432, ...
    DatabaseName="lab", ...
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
-view toggle, and SQL history between sessions via MATLAB preferences (stored
under `~/.matlab/`), so each user's settings follow their Linux home directory.

---

## 3. Deploy the web dashboard

### 3.1 Static (offline) dashboard

The dashboard is a single self-contained file, `web/lab-dashboard.html`
(Chart.js is loaded from a CDN; all data is generated in-page). It has **no
backend** and does not connect to Postgres.

**Serve it over HTTP (matches the repo's launch config):**

```bash
python3 -m http.server 8777 --directory web
```

Then browse to <http://localhost:8777/lab-dashboard.html>. This mirrors the
`lab-web` configuration already defined in `.claude/launch.json`. An internet
connection is needed the first time so the browser can fetch Chart.js from the
CDN.

For a persistent internal deployment, copy `lab-dashboard.html` to the web
root of any static host (nginx, Apache, a network share opened in a browser,
etc.) — no server-side runtime is required.

### 3.2 Live dashboard (reads the real database)

`web/live/server.py` serves the generated `lab-dashboard-live.html` plus a
single `/api/data` endpoint that runs `web/live/lab_data.sql` against the `lab`
schema per request, so the page always reflects current data. It needs only
Python 3 (standard library) and access to Postgres. Database connection
settings come from the standard libpq environment variables (`PGHOST`,
`PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, or a `~/.pgpass` entry). It
uses `psycopg`/`psycopg2` if importable, otherwise shells out to `psql` — so no
Python package install is strictly required as long as `psql` is on `PATH`.

Run it directly (mirrors the `lab-web-live` launch config):

```bash
PGDATABASE=lab python3 web/live/server.py --port 8778
# then open http://127.0.0.1:8778/
```

By default it binds to `127.0.0.1`. To serve other machines, pass
`--host 0.0.0.0` and open the port in your firewall as in §1.4.

**Run it as a systemd service** for a persistent deployment. Create
`/etc/systemd/system/caraslabdb-live.service`:

```ini
[Unit]
Description=Caras Lab live dashboard
After=network.target postgresql.service

[Service]
Type=simple
User=labweb
WorkingDirectory=/srv/CarasLabDB
Environment=PGHOST=localhost PGPORT=5432 PGDATABASE=lab PGUSER=lab_rw
Environment=PGPASSWORD=CHANGE_ME
ExecStart=/usr/bin/python3 /srv/CarasLabDB/web/live/server.py --host 0.0.0.0 --port 8778
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Then enable and start it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now caraslabdb-live
systemctl status caraslabdb-live
```

Prefer a `~/.pgpass` file (mode `600`) over `PGPASSWORD` in the unit if you want
to keep the password out of the service definition. Front the service with
nginx/Apache if you need TLS or a friendly hostname.

---

## 4. Quick verification checklist

- [ ] `systemctl status postgresql` shows the service **active (running)**.
- [ ] `sudo -u postgres psql -d lab -c "\dt lab.*"` lists the schema tables.
- [ ] A non-superuser role (`lab_rw`) can `SELECT`/`INSERT` but not `UPDATE`.
- [ ] MATLAB: `ver`, `license('test','Database_Toolbox')`, and
      `exist('postgresql')` all check out.
- [ ] `CarasLabDB(...)` constructs without error and
      `examples/carasLabDB_demo.m` runs against the live DB.
- [ ] `CarasLabDBApp()` opens and connects through its login dialog.
- [ ] `lab-dashboard.html` renders charts in the browser.
- [ ] (If deployed) `curl -s http://localhost:8778/api/data` returns JSON, not
      an error object.

---

## 5. Backups and maintenance

The event log is append-only and correction history is meaningful, so back up
the whole database rather than individual tables:

```bash
# Nightly logical backup.
sudo -u postgres pg_dump -Fc lab -f "/var/backups/lab_$(date +%Y%m%d).dump"
```

Schedule it with cron. As the `postgres` user (`sudo -u postgres crontab -e`),
add:

```cron
# 02:30 nightly, keep the custom-format dump under /var/backups
30 2 * * * pg_dump -Fc lab -f /var/backups/lab_$(date +\%Y\%m\%d).dump
```

(Note the `%` characters must be escaped as `\%` inside a crontab.)

Restore with `pg_restore -d lab_restored backup.dump` into a fresh database.
Keep backups on separate storage from the live data directory, and test a
restore periodically.
