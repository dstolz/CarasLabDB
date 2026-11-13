# Deploying CarasLabDB on Linux

> **The lab's production deployment is on Windows 11**: see
> [deployment-windows.md](deployment-windows.md), which is the complete
> guide (roles, TLS, the dashboard behind a reverse proxy, scheduled jobs,
> restore and upgrade runbooks). This guide is the Linux alternative and
> follows the same role model; for anything it covers only briefly, the
> Windows guide's section of the same name applies.

This guide walks through standing up the parts of the system on a Linux
server or workstation (Debian/Ubuntu and RHEL/Rocky/Fedora commands are both
given):

1. **The PostgreSQL database**: applies `design_docs/schema.sql` and
   `design_docs/grants.sql` to a running Postgres 14+ server. This is the
   actual data store.
2. **The MATLAB interface** (`@CarasLabDB`) and **GUI** (`@CarasLabDBApp`):
   the tools researchers use to read and write metadata.
3. **The web dashboard** (`web/lab-dashboard.html`): a standalone, static
   visualization page. It runs on synthetic in-page data and does **not** talk
   to the database, so it can be deployed by itself if that is all you need.
   A **live** variant (`web/live/`) that reads the real database is also
   covered.
4. **Backups and scheduled checks**: `tools/backup_lab.py`,
   `tools/restore_lab.py`, `tools/verify_artifacts.py` and
   `lab.fn_check_integrity()`.

You do not need all of them on every machine. A researcher's workstation
typically needs #2 (MATLAB) plus network access to a shared database server. A
lab server hosts #1 (and often the live dashboard). The static dashboard (#3)
can live anywhere a browser or static file server can reach it.

Commands below are for **bash**. Lines prefixed with `sudo` need root; the rest
run as your normal login user. The SQL, the `psql` commands and the Python
tools were run on Ubuntu 24.04 with PostgreSQL 16; package installation,
`systemd` units, firewalls, cron and the reverse proxy are marked *(not
verified in this repository's testing)*.

---

## 0. Prerequisites overview

| Component | Requires | Where it runs |
|-----------|----------|---------------|
| Database  | PostgreSQL 14 or newer | Lab server (or localhost for testing) |
| MATLAB interface + GUI | MATLAB **R2024b+** with **Database Toolbox** | Each researcher workstation |
| Web dashboard | Any modern browser; Python 3 (optional, only to serve it) | Anywhere |
| Live dashboard, backups, checks | Python 3; the PostgreSQL client programs; `psycopg` for the verifier | The lab server |

The database and MATLAB pieces can both live on one machine for a single-user
or evaluation setup. For lab use, run Postgres on a shared server and point
each workstation's MATLAB at it over the network.

This guide assumes the repo is checked out at `/srv/CarasLabDB` on the server;
substitute your actual path throughout. The logins it uses are those of
[deployment-windows.md](deployment-windows.md) §0.1: a non-superuser owner
`lab_admin`, the group roles `lab_rw` and `lab_ro` (never logins), one login
per lab member, and the service logins `lab_dashboard`, `lab_mcp` (both in
`lab_ro`) and `lab_verifier` (in `lab_rw`).

---

## 1. Deploy the PostgreSQL database

### 1.1 Install PostgreSQL

*(Not verified in this repository's testing.)*

Use your distribution's package (Ubuntu 24.04 and current Fedora/Rocky ship
Postgres 16). For a specific newer version, add the official PGDG repository
from <https://www.postgresql.org/download/linux/> instead.

**Debian / Ubuntu**: the package auto-creates a cluster and starts the service:

```bash
sudo apt update
sudo apt install -y postgresql postgresql-client
```

**RHEL / Rocky / Fedora**: you must initialize the data directory and enable
the service yourself:

```bash
sudo dnf install -y postgresql-server postgresql
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```

On RHEL-family systems the initial `pg_hba.conf` authenticates TCP
connections from `127.0.0.1` / `::1` with `ident`, not with a password, so
`psql -h localhost -U lab_admin` and the live dashboard fail until those
lines are changed to `scram-sha-256` (§1.5). Debian/Ubuntu already use
`scram-sha-256` there.

Confirm the service is running (both families use systemd):

```bash
systemctl status postgresql
```

On Linux, `psql`, `createdb`, and friends are installed on the system `PATH` by
the client package.

### 1.2 Create the owner role and the database

Local socket connections use **peer authentication**, so the superuser is
reached as the `postgres` OS user. Create a dedicated, non-superuser owner
(the owner can drop the immutability triggers, so it should not be
`postgres`) and the database it owns:

```bash
sudo -u postgres psql -c "CREATE ROLE lab_admin LOGIN CREATEROLE PASSWORD 'CHANGE_ME_ADMIN';"
sudo -u postgres psql -c "CREATE DATABASE lab OWNER lab_admin;"
sudo -u postgres psql -c "REVOKE ALL ON DATABASE lab FROM PUBLIC;"
```

Put the administrator's password in their own `~/.pgpass` (mode `600`):
`localhost:5432:*:lab_admin:CHANGE_ME_ADMIN`.

### 1.3 Apply the schema and the grants as the owner

From the repo root (`/srv/CarasLabDB`):

```bash
psql -X -v ON_ERROR_STOP=1 -h localhost -U lab_admin -d lab -f design_docs/schema.sql
psql -X -v ON_ERROR_STOP=1 -h localhost -U lab_admin -d lab -f design_docs/grants.sql
psql -X -h localhost -U lab_admin -d lab -c "SELECT max(version) FROM lab.schema_version;"   # 5
```

`schema.sql` prints `NOTICE: trigger ... does not exist, skipping` lines;
they are expected. It creates the `lab` schema, all tables, triggers, views
and functions. On PostgreSQL 13+ `gen_random_uuid()` is built in, so the
commented-out `pgcrypto` line at the top is not needed.

`grants.sql` creates the group roles `lab_rw` and `lab_ro` without `LOGIN` if
they do not exist, and sets the privileges every deployment uses: both read
everything; `lab_rw` inserts everywhere except the logs the database writes
itself, and may edit in place only `session`, the project tables, the tag
vocabulary, the variable definitions and the descriptive columns of
`subject` (not `subject_id`); it may not edit `lab.person` or set its
`db_login`, and may not add event types. `UPDATE`/`DELETE` on the event log,
artifacts, provenance edges and logs are blocked by triggers whatever is
granted. Run it as `lab_admin` (on PostgreSQL 16 a `CREATEROLE` role may
manage only roles it created), and again after every migration.

### 1.4 Logins: members and services

As `lab_admin` (`psql -h localhost -U lab_admin -d lab`). Each lab member gets
their own login and a `lab.person` row that maps it:

```sql
CREATE ROLE jdoe LOGIN PASSWORD 'initial-password' IN ROLE lab_rw;
INSERT INTO lab.person (full_name, email, role, db_login)
VALUES ('Jane Doe', 'jdoe@example.edu', 'student', 'jdoe');

CREATE ROLE lab_dashboard LOGIN PASSWORD 'CHANGE_ME_DASH' IN ROLE lab_ro;
CREATE ROLE lab_mcp       LOGIN PASSWORD 'CHANGE_ME_MCP'  IN ROLE lab_ro;
CREATE ROLE lab_verifier  LOGIN PASSWORD 'CHANGE_ME_VER'  IN ROLE lab_rw;
```

The database stamps the connected login on every row a client writes and
uses `lab.person.db_login` (through `lab.fn_current_person()`) to fill
`recorded_by` and the other person columns when the client names nobody.
Offboarding disables the login and never drops it, because its name is in
the log:

```sql
ALTER ROLE jdoe NOLOGIN;
UPDATE lab.person SET is_active = false WHERE db_login = 'jdoe';
```

Seed your reference rows (`storage_root`, `species`, ...) before real use;
members may add them, but only `lab_admin` can edit them afterwards. Renaming a subject is `SELECT lab.fn_rename_subject('old',
'new')` as `lab_admin`; `lab_rw` cannot change a `subject_id`.

### 1.5 Allow network connections (only if the DB serves other machines)

*(Not verified in this repository's testing.)*

If MATLAB will run on the **same** machine as Postgres, only the
`localhost` lines below matter.

For a shared server, edit the two config files. Their location differs by
distribution:

- Debian/Ubuntu: `/etc/postgresql/16/main/`
- RHEL/Rocky/Fedora: `/var/lib/pgsql/data/`

(`sudo -u postgres psql -c 'SHOW config_file;'` prints the exact path.)

- **`postgresql.conf`**: set `listen_addresses = '*'` (or the specific server
  IP).
- **`pg_hba.conf`**: allow the lab's logins from your lab subnet with
  password authentication, by group (`+lab_rw` is any member of `lab_rw`):

  ```
  host    lab    lab_admin   127.0.0.1/32      scram-sha-256
  host    lab    +lab_ro     127.0.0.1/32      scram-sha-256
  host    lab    +lab_rw     127.0.0.1/32      scram-sha-256
  host    lab    +lab_rw     192.168.1.0/24    scram-sha-256
  host    lab    +lab_ro     192.168.1.0/24    scram-sha-256
  ```

  On RHEL-family systems also change the default `ident` lines for
  `127.0.0.1/32` and `::1/128` to `scram-sha-256`. For TLS, set `ssl = on`
  with a certificate and use `hostssl` for the subnet lines, as in
  [deployment-windows.md](deployment-windows.md) §1.6 (including the check
  that MATLAB actually negotiates it).

Then restart the service and open the firewall port:

```bash
sudo systemctl restart postgresql
```

**Firewall: ufw (Debian/Ubuntu):**

```bash
sudo ufw allow from 192.168.1.0/24 to any port 5432 proto tcp
```

**Firewall: firewalld (RHEL/Rocky/Fedora):**

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="5432" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Restrict the firewall rule and `pg_hba.conf` to trusted subnets; do not expose
5432 to the open internet.

---

## 2. Deploy the MATLAB interface and GUI

### 2.1 Requirements

- **MATLAB R2024b or later** (the code uses `arguments`-block syntax with
  eager default-value validation; developed on R2025a; the GUI and non-database code were checked on R2024b). The Linux installer places MATLAB
  under `/usr/local/MATLAB/<release>` (e.g. `R2024b`) by default; launch it with `matlab` (symlink
  the binary onto your `PATH` if the installer did not: `sudo ln -s
  /usr/local/MATLAB/R2024b/bin/matlab /usr/local/bin/matlab`).
- **Database Toolbox**: the class connects via the native `postgresql()`
  interface. No ODBC DSN or JDBC `.jar` configuration is required.

Confirm both are present in MATLAB:

```matlab
ver                              % check MATLAB version >= 24.2 (R2024b)
license('test','Database_Toolbox')   % returns 1 if licensed
exist('postgresql')              % returns 2 if the native interface is available
```

If `exist('postgresql')` returns `0`, the Database Toolbox is not installed;
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

Each member connects with **their own** login (§1.4):

```matlab
db = CarasLabDB( ...
    Username="jdoe", ...
    Password=secret, ...
    Server="localhost", ...      % or the DB server hostname/IP
    Port=5432, ...
    DatabaseName="lab", ...
    PersonEmail="dstolz@umd.edu");   % optional once the login is mapped to a person
```

A successful construction opens the connection, checks the schema version
and resolves the current person. `CarasLabDB:noDatabaseToolbox` means the
toolbox is missing; `CarasLabDB:connectionFailed` means the server, port,
credentials, or `pg_hba.conf` rule is wrong; `CarasLabDB:schemaVersionMismatch`
means this copy of the class does not match the database's schema version
(update the class; `AllowSchemaMismatch=true` connects anyway with a
warning).

Then walk through `examples/carasLabDB_demo.m`, which exercises the full flow
(reference data → subject/session → recording event → artifact → analysis
event → retrieval → supersede correction) against a live database.

### 2.4 Launch the GUI

```matlab
app = CarasLabDBApp();      % opens a login dialog
% or, reusing an already-open connection:
app = CarasLabDBApp(db);
```

The GUI is a programmatic `uifigure` app. It persists window geometry, the
connection (minus password), the active-view toggle, and SQL history between
sessions via MATLAB preferences (`setpref`, stored under `~/.matlab/`), so
each user's settings follow their Linux home directory.

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
`lab-web` configuration already defined in `.claude/launch.json`. Without
network access to the CDN the page shows a notice in place of the charts.

For a persistent internal deployment, copy `lab-dashboard.html` to the web
root of any static host (nginx, Apache, a network share opened in a browser,
etc.); no server-side runtime is required.

### 3.2 Live dashboard (reads the real database)

`web/live/server.py` serves the generated `lab-dashboard-live.html` plus a
single `/api/data` endpoint that runs `web/live/lab_data.sql` against the `lab`
schema in a read-only transaction. A finished export is reused for 5 seconds,
so page loads and refreshes inside that window share one query; otherwise
the page reflects current data. It needs only Python 3 (standard library)
and access to Postgres. Connection settings come from the standard libpq
environment variables (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, a password
file). It uses `psycopg`/`psycopg2` if importable, otherwise shells out to
`psql`.

It has **no authentication**. Run it bound to `127.0.0.1` (the default) as
`lab_dashboard`, a login that inherits `lab_ro`, and put a reverse proxy
that provides HTTPS and login in front of it. Do not pass `--host 0.0.0.0`.

Run it directly:

```bash
PGHOST=localhost PGDATABASE=lab PGUSER=lab_dashboard python3 web/live/server.py --port 8778
# then open http://127.0.0.1:8778/
```

**Run it as a systemd service** *(not verified in this repository's
testing)*. Keep the password out of the unit: put it in a password file
readable only by the service user, e.g. `/etc/caraslabdb/pgpass` owned by
`labweb`, mode `600`, containing `localhost:5432:lab:lab_dashboard:CHANGE_ME_DASH`.
Then create `/etc/systemd/system/caraslabdb-live.service`:

```ini
[Unit]
Description=Caras Lab live dashboard
After=network.target postgresql.service

[Service]
Type=simple
User=labweb
WorkingDirectory=/srv/CarasLabDB
Environment=PGHOST=localhost PGPORT=5432 PGDATABASE=lab PGUSER=lab_dashboard
Environment=PGPASSFILE=/etc/caraslabdb/pgpass
ExecStart=/usr/bin/python3 /srv/CarasLabDB/web/live/server.py --host 127.0.0.1 --port 8778
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

**Reverse proxy** *(not verified in this repository's testing)*. Serve it
through nginx or Apache with a TLS certificate for the dashboard's host name
and an authentication layer (campus single sign-on where available, or at
least HTTP basic authentication over HTTPS), proxying to
`http://127.0.0.1:8778/`. For nginx, the core of the server block is:

```nginx
server {
    listen 443 ssl;
    server_name labdash.example.edu;
    ssl_certificate     /etc/ssl/certs/labdash.crt;
    ssl_certificate_key /etc/ssl/private/labdash.key;
    auth_basic           "Caras Lab";
    auth_basic_user_file /etc/nginx/caraslabdb.htpasswd;
    location / { proxy_pass http://127.0.0.1:8778; }
}
```

Open 443 (not 8778) to the lab subnets in the firewall, as in §1.5.

---

## 4. Quick verification checklist

- [ ] `systemctl status postgresql` shows the service **active (running)**.
- [ ] `psql -h localhost -U lab_admin -d lab -c "\dt lab.*"` lists the schema
      tables, and `SELECT max(version) FROM lab.schema_version` returns 5.
- [ ] A member's own login (in `lab_rw`) can `SELECT`/`INSERT`, cannot
      `UPDATE lab.person` or an event, and `SELECT lab.fn_current_person()`
      returns their person.
- [ ] MATLAB: `ver`, `license('test','Database_Toolbox')`, and
      `exist('postgresql')` all check out.
- [ ] `CarasLabDB(...)` constructs without error and
      `examples/carasLabDB_demo.m` runs against the live DB.
- [ ] `CarasLabDBApp()` opens and connects through its login dialog.
- [ ] `lab-dashboard.html` renders charts in the browser.
- [ ] (If deployed) `curl -s http://127.0.0.1:8778/api/data` on the server
      returns JSON, not an error object, and the dashboard is reachable from
      other machines only through the proxy.
- [ ] The backup job has produced a set and `--check` succeeds (§5).

---

## 5. Backups and maintenance

The event log is append-only and correction history is meaningful, so back up
the whole database, with its roles, using `tools/backup_lab.py`. It writes a
dump, the roles (`.globals.sql`: every login, its password hash and its
memberships) and a manifest of row counts; reads the dump back before
keeping it; copies and verifies the set with `--copy-to`; and prunes sets
older than `--keep-days` (default 30) only after all of that succeeded. It
runs as the `postgres` superuser (peer authentication as the `postgres` OS
user) into a directory that user can write:

```bash
sudo install -d -o postgres -g postgres -m 700 /var/backups/caraslabdb
sudo -u postgres python3 /srv/CarasLabDB/tools/backup_lab.py -d lab \
    --copy-to /mnt/offsite/caraslabdb --log-file /var/backups/caraslabdb/backup.log \
    /var/backups/caraslabdb
sudo -u postgres python3 /srv/CarasLabDB/tools/backup_lab.py --check 26 -d lab /var/backups/caraslabdb
```

`--copy-to` must be storage off the machine (an NFS or SMB mount the
`postgres` user can write). `--check HOURS` takes no backup and succeeds only
if a readable dump newer than that exists: use it for monitoring.

Schedule them with cron *(not verified in this repository's testing)*. As the
`postgres` user (`sudo -u postgres crontab -e`):

```cron
30 2 * * * python3 /srv/CarasLabDB/tools/backup_lab.py -d lab --copy-to /mnt/offsite/caraslabdb --log-file /var/backups/caraslabdb/backup.log /var/backups/caraslabdb
0  8 * * * python3 /srv/CarasLabDB/tools/backup_lab.py --check 26 -d lab /var/backups/caraslabdb || echo "CarasLabDB backup is stale" | mail -s "CarasLabDB backup" admin@example.edu
```

(`mail` stands for whatever alerting you use.)

**Restore** with `tools/restore_lab.py`, as `postgres`, into a **new**
database; it creates the roles from the set that do not exist yet (existing
ones are left as they are), restores the dump in one transaction and reports
row counts against the manifest:

```bash
sudo -u postgres python3 /srv/CarasLabDB/tools/restore_lab.py \
    /var/backups/caraslabdb/lab_20261113_023000.dump lab_restored
```

Exit 0 means the counts match. To put a restored copy into service, stop the
clients and swap names (`ALTER DATABASE lab RENAME TO lab_broken; ALTER
DATABASE lab_restored RENAME TO lab;`), then re-run `grants.sql`; the full
runbook is [deployment-windows.md](deployment-windows.md) §5. Test a restore
after setup and periodically.

**File verification and integrity report.** On a machine that mounts the NAS,
as `lab_verifier` (it needs `pip install "psycopg[binary]"`):

```bash
PGHOST=dbhost PGDATABASE=lab PGUSER=lab_verifier \
    python3 /srv/CarasLabDB/tools/verify_artifacts.py --root nas-main=/mnt/nas-main
```

and, as any login (e.g. `lab_dashboard`), `psql -X -tA -h localhost -U
lab_dashboard -d lab -c "SELECT * FROM lab.fn_check_integrity()"`: an empty
result is healthy. Schedule the verifier weekly and the integrity report
daily from cron, with the password in that OS user's `~/.pgpass`.

**Schema upgrades** follow [deployment-windows.md](deployment-windows.md) §6:
back up, stop the clients, apply the migration as `lab_admin` with
`psql -X -v ON_ERROR_STOP=1 -1 -h localhost -U lab_admin -d lab -f
design_docs/migrations/<script>.sql`, re-run `grants.sql`, check, and update
the MATLAB class and the MCP server everywhere.
