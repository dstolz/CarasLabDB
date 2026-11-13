# Deploying CarasLabDB on Windows 11

This is the lab's **production deployment guide**. The lab runs CarasLabDB on
a Windows 11 machine managed by the university through **Microsoft Endpoint
Configuration Manager (MECM)**, used as the lab's server. The Linux and
Synology guides ([deployment-linux.md](deployment-linux.md),
[deployment-synology.md](deployment-synology.md)) describe alternatives.

The guide covers, end to end:

1. **The PostgreSQL database**: PostgreSQL 14+ installed on the server,
   `design_docs/schema.sql` and `design_docs/grants.sql` applied by a
   dedicated, non-superuser owner role, one login per lab member, network
   access, TLS (§1).
2. **The MATLAB interface** (`@CarasLabDB`) and **GUI** (`@CarasLabDBApp`) on
   each researcher's workstation (§2).
3. **The live dashboard** (`web/live/server.py`), started at boot, behind a
   reverse proxy that provides HTTPS and login (§3), and the static demo
   dashboard (§3.5).
4. **Scheduled jobs**: backups, backup monitoring, file verification and the
   integrity report (§4).
5. **Runbooks**: restore (§5), upgrade (§6), onboarding and offboarding
   (§1.4), renaming a subject (§7).
6. **For IT**: what a MECM-managed machine means for all of the above (§9).

Commands are for **PowerShell**. Run an elevated (Administrator) PowerShell
only where noted.

> **What has been tested.** The SQL in this guide (roles, grants, onboarding,
> offboarding, the maintenance lock-out, the upgrade and the integrity
> report) and the Python tools (`tools\backup_lab.py`, `tools\restore_lab.py`,
> `tools\verify_artifacts.py`, `web\live\server.py`) were run on Linux against
> PostgreSQL 16. Steps that only exist on Windows (the installer, services,
> Task Scheduler, Windows Firewall, file ACLs, IIS) and anything MECM does
> are marked *(not verified in this repository's testing)*. Check those on
> the machine, and where this guide says **confirm with IT**, do.

---

## 0. Prerequisites overview

| Component | Requires | Where it runs |
|-----------|----------|---------------|
| Database  | PostgreSQL 14 or newer | The lab server |
| Live dashboard | Python 3; `psql` on the PATH, or the `psycopg` package | The lab server, bound to 127.0.0.1 |
| Reverse proxy | IIS with URL Rewrite and Application Request Routing (ARR) | The lab server |
| Scheduled jobs | Python 3; the PostgreSQL client programs; `psycopg` for the verifier | The lab server (the verifier on any machine that mounts the NAS) |
| MATLAB interface + GUI | MATLAB **R2024b+** with **Database Toolbox** | Each researcher workstation |
| Static demo dashboard | Any modern browser | Anywhere |

### 0.1 Who is who

PostgreSQL logins (roles) used throughout. Every name is a suggestion; keep
whatever you choose consistent.

| Login | Kind | Used by | Privileges |
|---|---|---|---|
| `postgres` | superuser, created by the installer | the backup job and the restore runbook only | everything |
| `lab_admin` | login, **not** a superuser, `CREATEROLE` | the lab's database administrator: owns the database and schema, applies migrations, creates and disables logins, renames subjects | owner of `lab` |
| `lab_rw` | group role, never a login | inherited by every lab member and by the verifier | read, append, edit the descriptive tables ([`grants.sql`](grants.sql)) |
| `lab_ro` | group role, never a login | inherited by the dashboard and the MCP server | read only |
| `jdoe`, ... | one login per lab member, `IN ROLE lab_rw` | that person's MATLAB client and GUI | those of `lab_rw` |
| `lab_dashboard` | login, `IN ROLE lab_ro` | the live dashboard | those of `lab_ro` |
| `lab_mcp` | login, `IN ROLE lab_ro` | the MCP server ([mcp-server.md](mcp-server.md)) | those of `lab_ro` |
| `lab_verifier` | login, `IN ROLE lab_rw` | `tools\verify_artifacts.py` | those of `lab_rw` |

Why a separate owner: the owner of the schema can drop the immutability
triggers, and a subject rename cascades into the append-only tables with the
owner's privileges, so the owner should be a role used only for
administration and not the `postgres` superuser.

Why one login per person: the database stamps the connected login on every
row a client writes (`event.recorded_login`, `artifact.created_login`,
`artifact_verification.verified_login`, `tag_assignment.applied_login`,
`variable_value.set_login`, `retraction.retracted_login`) and on every edit
(`row_history.changed_by`), whatever the client sends. A shared login makes
all of that meaningless.

Windows accounts. The jobs and the dashboard run under a low-privileged
Windows account, not under an administrator's own account, so that they keep
running when nobody is signed in and the credentials they need live in one
place. This guide calls it `LAB\svc-caraslabdb`; whether that is a domain
account, a managed service account or a local account is **confirm with IT**
(§9).

---

## 1. Deploy the PostgreSQL database

### 1.1 Install PostgreSQL

*(Not verified in this repository's testing.)*

On a MECM-managed machine the installation is usually done by IT, from
Software Center or as a package they deploy (§9). Ask for one PostgreSQL
**major version, 14 or later (16 is a good default), pinned**: a new major
version needs the upgrade in §6.1 and must not arrive as an automatic update.

If you install it yourself, use the EDB Windows installer from
<https://www.postgresql.org/download/windows/>:

- Set and record a password for the `postgres` superuser. Keep it where the
  lab keeps admin credentials; after setup it is used only by the backup job
  and for restores.
- Keep the default port **5432** unless it is in use.
- Skip Stack Builder.

The installer registers PostgreSQL as an automatically started Windows
service (`postgresql-x64-16` for version 16). Confirm:

```powershell
Get-Service postgresql*
```

Put the client programs on the PATH (adjust `16`):

```powershell
$env:Path += ";C:\Program Files\PostgreSQL\16\bin"          # this session
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path","User") + ";C:\Program Files\PostgreSQL\16\bin",
    "User")                                                 # permanently, for you
```

The data directory is `C:\Program Files\PostgreSQL\16\data` by default; it
holds `postgresql.conf` and `pg_hba.conf`.

### 1.2 Create the owner role and the database

As `postgres`, once (you are prompted for its password):

```powershell
psql -U postgres -d postgres -c "CREATE ROLE lab_admin LOGIN CREATEROLE PASSWORD 'CHANGE_ME_ADMIN';"
psql -U postgres -d postgres -c "CREATE DATABASE lab OWNER lab_admin;"
psql -U postgres -d postgres -c "REVOKE ALL ON DATABASE lab FROM PUBLIC;"
```

A password typed on a command line stays in the PowerShell history. To set
it without that, start `psql -U postgres -d postgres` and type
`\password lab_admin` at its prompt.

- `CREATEROLE` lets `lab_admin` create `lab_rw` / `lab_ro` (in the next step)
  and the members' logins, and disable them, without the superuser. On
  PostgreSQL 16 and later a `CREATEROLE` role may manage only the roles it
  created or was given `ADMIN OPTION` on, which is why `grants.sql` should be
  run by `lab_admin` and not by `postgres`.
- `REVOKE ALL ... FROM PUBLIC` means only roles granted `CONNECT` (by
  `grants.sql`: `lab_rw` and `lab_ro`, and so every login in them) can
  connect to `lab`. §6 relies on it to lock clients out during an upgrade.

### 1.3 Apply the schema and the grants as the owner

From the repo root (`C:\src\CarasLabDB`), connecting as `lab_admin` over
TCP:

```powershell
psql -X -v ON_ERROR_STOP=1 -h localhost -U lab_admin -d lab -f design_docs/schema.sql
psql -X -v ON_ERROR_STOP=1 -h localhost -U lab_admin -d lab -f design_docs/grants.sql
```

`schema.sql` prints a series of `NOTICE: trigger ... does not exist,
skipping` lines; they are expected. With `ON_ERROR_STOP=1` any real error
stops it with a non-zero exit. It installs schema version 5:

```powershell
psql -X -h localhost -U lab_admin -d lab -c "SELECT max(version) FROM lab.schema_version;"   # 5
psql -X -h localhost -U lab_admin -d lab -c "\dt lab.*"
```

`grants.sql` creates the group roles `lab_rw` and `lab_ro` (without `LOGIN`)
if they do not exist and sets every privilege. In short: both read
everything; `lab_rw` inserts everywhere except the logs the database writes
itself; it may edit in place only `session`, the project tables, the tag
vocabulary, the variable definitions and the descriptive columns of
`subject` (not `subject_id`); it may not edit `lab.person` or set
`lab.person.db_login`, and may not add rows to `lab.event_type`. `UPDATE` and
`DELETE` on the event log, artifacts, provenance edges and every log table
are blocked by triggers whatever is granted. Re-run it after every migration.

### 1.4 Logins: lab members and services (onboarding, offboarding)

Connect as the administrator for all of this:

```powershell
psql -X -h localhost -U lab_admin -d lab
```

**Onboarding a lab member** is two steps: a login that inherits `lab_rw`,
and a `lab.person` row whose `db_login` names it.

```sql
CREATE ROLE jdoe LOGIN PASSWORD 'initial-password' IN ROLE lab_rw;

-- A new person:
INSERT INTO lab.person (full_name, email, role, db_login)
VALUES ('Jane Doe', 'jdoe@example.edu', 'student', 'jdoe');
-- or, for a person row that already exists:
UPDATE lab.person SET db_login = 'jdoe' WHERE lower(email) = 'jdoe@example.edu';
```

Ask the member to change the password at their first connection
(`\password` in psql, or ask the administrator to set one). The mapping
matters: `lab.fn_current_person()` returns the person whose `db_login` is
the connected login. The database uses it to fill `recorded_by`,
`created_by`, `verified_by`, `applied_by`, `retracted_by` and `set_by` when
the client names nobody, and the MATLAB class uses it to resolve the current
person. Only the administrator can set `db_login`: whoever could set it
could sign entries as someone else.

**Service logins**, once:

```sql
CREATE ROLE lab_dashboard LOGIN PASSWORD 'CHANGE_ME_DASH' IN ROLE lab_ro;
CREATE ROLE lab_mcp       LOGIN PASSWORD 'CHANGE_ME_MCP'  IN ROLE lab_ro;
CREATE ROLE lab_verifier  LOGIN PASSWORD 'CHANGE_ME_VER'  IN ROLE lab_rw;
```

They need no `lab.person` row. A login mapped to nobody is still stamped on
every row it writes; `fn_current_person()` is then NULL.

**Offboarding** disables the login; it never drops it, because the name is
in the log of every row that person wrote:

```sql
ALTER ROLE jdoe NOLOGIN;
UPDATE lab.person SET is_active = false WHERE db_login = 'jdoe';
```

`ALTER ROLE jdoe LOGIN` re-enables it. The privileges live on `lab_rw`, so
no grant changes are needed either way.

Seed the reference rows (`storage_root`, `species`, ...) before real use.
Members may add rows to the reference tables, but only the owner can edit
them afterwards (`lab_rw` has no `UPDATE` there).

### 1.5 Network access: `pg_hba.conf` and Windows Firewall

*(The `pg_hba.conf` and firewall steps are not verified in this repository's
testing.)*

In `postgresql.conf` set `listen_addresses = '*'` (the EDB installer usually
already has it) or the server's address. Keep
`password_encryption = scram-sha-256`, the default since PostgreSQL 14.

In `pg_hba.conf` the first matching line wins. Replace any broad `all all`
network lines with rules for the lab's subnets (`10.1.2.0/24` stands for the
lab subnet and the VPN pool: **confirm with IT**). `+name` means "any member
of the role":

```
# TYPE    DATABASE  USER           ADDRESS          METHOD
host      lab       lab_admin      127.0.0.1/32     scram-sha-256
host      lab       lab_dashboard  127.0.0.1/32     scram-sha-256
host      lab       +lab_ro        127.0.0.1/32     scram-sha-256
host      lab       +lab_rw        127.0.0.1/32     scram-sha-256
hostssl   lab       +lab_rw        10.1.2.0/24      scram-sha-256
hostssl   lab       +lab_ro        10.1.2.0/24      scram-sha-256
```

Keep the installer's `host all all 127.0.0.1/32 scram-sha-256` (and `::1`)
lines for local administration by `postgres`. `lab_admin` is accepted only
from the server itself. Until TLS is set up (§1.6), write `host` instead of
`hostssl` for the two subnet lines.

Restart the service (elevated):

```powershell
Restart-Service postgresql-x64-16
```

Open the port to the same subnets only, scoped with `-RemoteAddress`
(elevated):

```powershell
New-NetFirewallRule -DisplayName "PostgreSQL 5432 (CarasLabDB)" -Direction Inbound `
    -Protocol TCP -LocalPort 5432 -RemoteAddress 10.1.2.0/24 -Profile Domain -Action Allow
```

On a managed machine the firewall may be set by Group Policy or MECM, which
then overrides or removes a local rule; request the rule from IT instead
(§9). Never expose 5432 to the internet.

### 1.6 Encryption in transit (TLS)

*(Not verified in this repository's testing; whether MATLAB uses TLS must be
confirmed on site.)*

1. Get a server certificate for the server's DNS name from IT (campus CA) and
   put the certificate and its key in the data directory as `server.crt` and
   `server.key`. Restrict the key file to the service account and
   Administrators.
2. In `postgresql.conf`:

   ```
   ssl = on
   ssl_cert_file = 'server.crt'
   ssl_key_file  = 'server.key'
   ```

3. Use `hostssl` for the network lines in `pg_hba.conf` (§1.5) and restart
   the service. A client that does not negotiate TLS is then refused.

Check from a workstation with `psql "host=labdb.example.edu dbname=lab
user=jdoe sslmode=require"`: `\conninfo` should report an SSL connection.
For full verification of the server's identity a client uses
`sslmode=verify-full` with the campus CA certificate as its root
certificate.

MATLAB's native `postgresql()` interface does not obviously expose an SSL
option, so whether it negotiates TLS with a `hostssl`-only server must be
checked on site before anyone relies on it. With a MATLAB client connected,
run as the administrator:

```sql
SELECT a.usename, a.client_addr, a.application_name, s.ssl, s.version
FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid)
WHERE a.datname = 'lab';
```

`ssl = t` on the MATLAB row confirms it. If MATLAB cannot connect at all
under `hostssl`, keep `host` for the workstation subnet and raise it with IT.

---

## 2. Deploy the MATLAB interface and GUI

### 2.1 Requirements

- **MATLAB R2024b or later** (the code uses `arguments`-block syntax with
  eager default-value validation; developed on R2025a; the GUI and
  non-database code were checked on R2024b).
- **Database Toolbox**: the class connects through the native `postgresql()`
  interface. No ODBC DSN or JDBC `.jar` configuration is required.

```matlab
ver                                  % MATLAB version >= 24.2 (R2024b)
license('test','Database_Toolbox')   % 1 if licensed
exist('postgresql')                  % 2 if the native interface is available
```

On a managed workstation MATLAB and its toolboxes may also come through
Software Center (§9).

### 2.2 Get the code onto the machine and add it to the path

Place the repo somewhere stable, e.g. `C:\src\CarasLabDB`, and add the
**repo root** (not the `@CarasLabDB` folder) to the MATLAB path:

```matlab
addpath('C:\src\CarasLabDB');
savepath;                        % persist across MATLAB sessions
```

Every workstation must run the version of the class that matches the
database's schema version (§6).

### 2.3 Connect and smoke-test

Each member connects with **their own** login (§1.4):

```matlab
db = CarasLabDB( ...
    Username="jdoe", ...
    Password=secret, ...
    Server="labdb.example.edu", ...  % the server's DNS name
    Port=5432, ...
    DatabaseName="lab", ...
    PersonEmail="dstolz@umd.edu");   % optional once the login is mapped to a person
```

A successful construction opens the connection, sets the session time zone
to the workstation's, checks the schema version and resolves the current
person. Errors:

- `CarasLabDB:noDatabaseToolbox`: the toolbox is missing.
- `CarasLabDB:connectionFailed`: server, port, credentials, or a
  `pg_hba.conf` / firewall rule.
- `CarasLabDB:schemaVersionMismatch`: the database is at a different schema
  version than this copy of the class was written for. Update the class (or
  the database, §6). `AllowSchemaMismatch=true` connects anyway, with a
  warning; use it only deliberately.
- `CarasLabDB:personNotFound`: `PersonEmail` (or `PersonId` / `PersonName`)
  matches no `lab.person` row.

Then walk through `examples/carasLabDB_demo.m` against a scratch subject.

### 2.4 Launch the GUI

```matlab
app = CarasLabDBApp();      % opens a login dialog
app = CarasLabDBApp(db);    % or reuse an open connection
```

The app stores window geometry, the connection settings (not the password),
the active-view toggle and SQL history with MATLAB's `setpref`, so each
user's settings follow their Windows profile. Ctrl+? lists its keyboard
shortcuts.

---

## 3. The live dashboard

`web/live/server.py` serves the dashboard page and one JSON endpoint,
`/api/data`, which runs `web/live/lab_data.sql` in a read-only transaction. A
finished export is reused for 5 seconds, so a burst of page loads costs one
query. Only the page and `/api/data` are served, and it has **no
authentication**: it must be bound to `127.0.0.1` (its default) and reached
only through the reverse proxy in §3.4.

It needs Python 3 and either `psql` on the PATH or `psycopg`; connection
settings come from the standard libpq variables (`PGHOST`, `PGPORT`,
`PGDATABASE`, `PGUSER`, a password file).

### 3.1 Try it by hand

```powershell
$env:PGHOST = "localhost"; $env:PGDATABASE = "lab"; $env:PGUSER = "lab_dashboard"
python web\live\server.py --host 127.0.0.1 --port 8778
# open http://127.0.0.1:8778/ on the server
```

### 3.2 Credentials for the service account

*(Not verified in this repository's testing.)*

libpq reads passwords from `%APPDATA%\postgresql\pgpass.conf` of the account
that runs the program; a scheduled task must not carry a password in its
command line. One line per login, `host:port:database:user:password`. For
`LAB\svc-caraslabdb`, which runs the dashboard and the jobs in §4:

```
localhost:5432:lab:lab_dashboard:CHANGE_ME_DASH
localhost:5432:lab:lab_verifier:CHANGE_ME_VER
localhost:5432:*:postgres:POSTGRES_PASSWORD
```

The `postgres` line is for the backup job only (§4.1). Create the file in
that account's profile (`C:\Users\svc-caraslabdb\AppData\Roaming\postgresql\pgpass.conf`;
the profile exists once the account has signed in or run a task) and
restrict it, because libpq on Windows does not check the file's
permissions (elevated):

```powershell
$f = "C:\Users\svc-caraslabdb\AppData\Roaming\postgresql\pgpass.conf"
icacls $f /inheritance:r /grant:r "LAB\svc-caraslabdb:(R)" "BUILTIN\Administrators:(F)"
```

If the task runs without the profile loaded, point libpq at the file
explicitly with the `PGPASSFILE` variable in the launcher below.

### 3.3 Start it at boot without a signed-in user

*(Not verified in this repository's testing.)*

Use a Task Scheduler task with an **At startup** trigger, run as the
low-privileged service account whether or not anyone is signed in. (A
Windows service needs a service wrapper such as WinSW or NSSM, which is
third-party software and on a managed machine needs IT's approval; Task
Scheduler is built in.)

A launcher, `C:\src\CarasLabDB\deploy\run-dashboard.cmd` (a file of your
own; it is not in the repository):

```bat
@echo off
set PGHOST=localhost
set PGPORT=5432
set PGDATABASE=lab
set PGUSER=lab_dashboard
rem set PGPASSFILE=C:\Users\svc-caraslabdb\AppData\Roaming\postgresql\pgpass.conf
"C:\Program Files\Python312\python.exe" C:\src\CarasLabDB\web\live\server.py --host 127.0.0.1 --port 8778 >> C:\ProgramData\CarasLabDB\dashboard.log 2>&1
```

Register it (elevated; the account needs the "Log on as a batch job" right,
§9):

```powershell
New-Item -ItemType Directory -Force C:\ProgramData\CarasLabDB | Out-Null
$action   = New-ScheduledTaskAction -Execute "C:\src\CarasLabDB\deploy\run-dashboard.cmd"
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$cred     = Get-Credential "LAB\svc-caraslabdb"
Register-ScheduledTask -TaskName "CarasLabDB dashboard" -Action $action -Trigger $trigger `
    -Settings $settings -User $cred.UserName -Password $cred.GetNetworkCredential().Password `
    -RunLevel Limited
Start-ScheduledTask -TaskName "CarasLabDB dashboard"
```

`ExecutionTimeLimit` zero means no time limit (the default would stop the
server after 72 hours). The service account needs read access to the repo
and write access to `C:\ProgramData\CarasLabDB`. Reboot once and check that
`http://127.0.0.1:8778/` answers before anyone signs in.

### 3.4 HTTPS and login in front of it: IIS

*(Not verified in this repository's testing.)*

On a domain-joined machine the natural reverse proxy is IIS with **URL
Rewrite** and **Application Request Routing (ARR)**, using **Windows
Authentication** so that campus accounts are the login. URL Rewrite and ARR
are separate Microsoft downloads; on a managed machine IT installs them
(§9).

1. Install IIS with Windows Authentication (elevated):

   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WindowsAuthentication
   ```

   Then install URL Rewrite and ARR.
2. In IIS Manager, server node, **Application Request Routing Cache →
   Server Proxy Settings**: tick **Enable proxy**.
3. On the site: an **HTTPS binding** with the certificate IT issues for the
   dashboard's DNS name; **Authentication**: Windows Authentication on,
   Anonymous off; **Authorization Rules**: allow only the lab's AD group.
4. A reverse-proxy rule in the site's `web.config`:

   ```xml
   <configuration>
     <system.webServer>
       <rewrite>
         <rules>
           <rule name="CarasLabDB dashboard" stopProcessing="true">
             <match url="(.*)" />
             <action type="Rewrite" url="http://127.0.0.1:8778/{R:1}" />
           </rule>
         </rules>
       </rewrite>
     </system.webServer>
   </configuration>
   ```

5. Open 443 in the firewall to the lab subnets only, as in §1.5, and keep
   8778 closed (the server listens on 127.0.0.1 anyway).

Browsers need outbound access to `cdn.jsdelivr.net` for the chart library;
without it the page shows a notice in place of the charts.

### 3.5 The static demo dashboard

`web/lab-dashboard.html` is a self-contained page with synthetic data and no
backend. Open it in a browser, or serve the folder:

```powershell
python -m http.server 8777 --directory web
# http://localhost:8777/lab-dashboard.html
```

---

## 4. Scheduled jobs

*(The Task Scheduler registration is not verified in this repository's
testing; the commands each task runs were run on Linux.)*

All of them run as `LAB\svc-caraslabdb` with the password file of §3.2,
whether or not anyone is signed in. Register each like the dashboard task
(§3.3), with the trigger shown and the default execution time limit. Nobody
reads a scheduled task's console, so each job either logs to a file or is
redirected to one, and each exits non-zero on failure: have Task Scheduler
(or the monitoring IT uses) alert on a non-zero **Last Run Result**.

| Task | Trigger | Runs |
|---|---|---|
| Backup | daily 02:30 | `tools\backup_lab.py` (§4.1) |
| Backup check | daily 08:00 | `tools\backup_lab.py --check 26` (§4.1) |
| File verification | weekly | `tools\verify_artifacts.py` (§4.2) |
| Integrity report | daily | `lab.fn_check_integrity()` (§4.3) |

### 4.1 Backups

`tools\backup_lab.py` writes a set of three files to a backup directory: the
database (`pg_dump`, custom format), every role with its password hash and
memberships (`.globals.sql`) and a manifest of the schema version and row
counts. It reads the dump back before moving the set into place, copies it
to `--copy-to` and verifies the copy, and prunes sets older than
`--keep-days` (default 30) only after all of that succeeded. It runs as the
`postgres` superuser, because only a superuser can read the role password
hashes. Standard library only.

```powershell
& "C:\Program Files\Python312\python.exe" C:\src\CarasLabDB\tools\backup_lab.py `
    --pg-bin "C:\Program Files\PostgreSQL\16\bin" -U postgres --host localhost -d lab `
    --copy-to \\fileserver\labshare\caraslabdb-backups `
    --log-file C:\ProgramData\CarasLabDB\backup.log `
    D:\CarasLabDB\backups
```

- Both directories must exist before the first run (the script does not
  create them).
- `D:\CarasLabDB\backups` should be on a different disk from the PostgreSQL
  data directory if possible; the `--copy-to` directory must be **off the
  machine** (a file share the service account can write, or wherever IT
  keeps backups: **confirm with IT**).
- Restrict both directories to the service account and Administrators: the
  `.globals.sql` file holds the password hashes of every login.

The monitoring task succeeds only if the directory holds a readable dump of
`lab` newer than the given number of hours:

```powershell
& "C:\Program Files\Python312\python.exe" C:\src\CarasLabDB\tools\backup_lab.py `
    --pg-bin "C:\Program Files\PostgreSQL\16\bin" --check 26 -d lab D:\CarasLabDB\backups
```

Run a second check against the `--copy-to` directory if you want the
off-machine copy monitored too.

### 4.2 File verification

`tools\verify_artifacts.py` reads every active artifact's file under the
storage roots you name, recomputes its checksum and appends one row per file
to `lab.artifact_verification` (`ok`, `mismatch` or `missing`). It needs a
login inheriting `lab_rw` (`lab_verifier`), a mount of the NAS, and `psycopg`
(`pip install "psycopg[binary]"`). Each `--root` maps a `lab.storage_root`
name to where it is mounted on this machine:

```bat
set PGHOST=localhost
set PGDATABASE=lab
set PGUSER=lab_verifier
"C:\Program Files\Python312\python.exe" C:\src\CarasLabDB\tools\verify_artifacts.py --root nas-main=\\nas\data
```

The service account needs read access to the share; a mapped drive letter
such as `Z:\` belongs to a signed-in user's session, so use the UNC path. A
root whose directory is missing or empty is refused, so an unmounted share
does not record every file as missing. `--older-than-days 7` checks only
files not verified in the last week and `--limit N` caps one run. Exit code
1 means at least one file is missing or mismatched.

### 4.3 Integrity report

`lab.fn_check_integrity()` returns one row per problem (13 checks; see
[database-design.md](database-design.md) §4.2); an empty result is healthy.
Any login can run it; use `lab_dashboard`. Save this as
`C:\src\CarasLabDB\deploy\integrity.sql` (a file of your own). It prints every
row and then fails if any is an `error`:

```sql
\set ON_ERROR_STOP 1
SELECT now(), * FROM lab.fn_check_integrity();
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM lab.fn_check_integrity() WHERE severity = 'error') THEN
        RAISE EXCEPTION 'lab.fn_check_integrity() reports errors';
    END IF;
END
$$;
```

and run it from the task's launcher; `psql` exits with 3 when the check
fails and 0 when it passes:

```bat
set PGHOST=localhost
set PGDATABASE=lab
set PGUSER=lab_dashboard
"C:\Program Files\PostgreSQL\16\bin\psql.exe" -X -tA -F "|" -f C:\src\CarasLabDB\deploy\integrity.sql >> C:\ProgramData\CarasLabDB\integrity.log 2>&1
```

Warnings (an unverified file, a correction that dropped a tag) are worth a
weekly look; errors (a typed event with no detail row, a failed file check)
are worth an alert.

---

## 5. Restore runbook

`tools\restore_lab.py` restores a backup set into a **new** database and
never overwrites one. It creates the roles from the set's `.globals.sql` that
do not exist on this server (existing roles are left exactly as they are,
so a drill on the live server cannot re-enable a disabled login), creates
the database with its original owner and privileges, restores the dump in
one transaction, and prints a report: schema version, row counts compared
with the manifest, owners, grants and `fn_check_integrity()`. Exit code 0
means the row counts match the manifest; 3 means restored but they differ.
Run it as `postgres`.

**A restore drill** (after setup, then every few months), on the server or a
spare machine with the same PostgreSQL major version or newer:

```powershell
& "C:\Program Files\Python312\python.exe" C:\src\CarasLabDB\tools\restore_lab.py `
    --pg-bin "C:\Program Files\PostgreSQL\16\bin" -U postgres --host localhost `
    D:\CarasLabDB\backups\lab_20261113_023000.dump lab_restored
psql -U postgres -d postgres -c "DROP DATABASE lab_restored;"
```

**Recovering the live database:**

1. Stop the clients: disable the dashboard task
   (`Stop-ScheduledTask "CarasLabDB dashboard"`), tell the lab to close
   MATLAB, and lock them out (§6, step 2).
2. Restore the newest good set into `lab_restored` as above and read the
   report.
3. Swap the names (as `postgres`; nobody may be connected to either
   database):

   ```sql
   ALTER DATABASE lab RENAME TO lab_broken;
   ALTER DATABASE lab_restored RENAME TO lab;
   ```

4. Re-run `grants.sql` as `lab_admin` (it re-grants `CONNECT`), restart the
   dashboard task, and tell the lab. Entries made after the backup was taken
   are not in it and must be re-entered.
5. Keep `lab_broken` until you are sure; then drop it.

On a new server, install the same PostgreSQL major version (or newer), then
restore with the role step included: the `.globals.sql` brings back every
login with its password.

---

## 6. Upgrade runbook (schema migrations)

A new schema version arrives as a numbered script in `design_docs/migrations/`
together with matching versions of the MATLAB class and the MCP server. The
MATLAB class refuses to connect to a database at a schema version it was not
written for, so the database and every client move together.

1. **Back up** (§4.1, by hand) and note the set's name.
2. **Stop the clients.** Announce a window; stop the dashboard task; then, as
   `lab_admin`, lock out everyone but the administrator, and as `postgres`
   end the sessions still open:

   ```sql
   REVOKE CONNECT ON DATABASE lab FROM lab_rw, lab_ro;      -- as lab_admin
   SELECT pg_terminate_backend(pid) FROM pg_stat_activity   -- as postgres
   WHERE datname = 'lab' AND pid <> pg_backend_pid();
   ```

3. **Apply the migration as the owner**, in one transaction (`-1`),
   stopping on the first error. A script refuses to run against any version
   but the one it upgrades; apply each newer script in order:

   ```powershell
   psql -X -v ON_ERROR_STOP=1 -1 -h localhost -U lab_admin -d lab `
       -f design_docs/migrations/005_variables_retraction_logins.sql
   ```

   Read the script's header first: it says what changes and what to do
   afterwards (005, for instance, asks the administrator to set
   `lab.person.db_login` for every member, §1.4).
4. **Re-run `grants.sql`** as `lab_admin` (§1.3). This also gives `CONNECT`
   back to `lab_rw` and `lab_ro`.
5. **Check.** `SELECT max(version) FROM lab.schema_version;` and
   `SELECT * FROM lab.fn_check_integrity();` on the upgraded database. For
   the privileges, run `tests\roles_test.sql` as `postgres` against a
   scratch database freshly built from the new `schema.sql` and
   `grants.sql` (it creates and acts as test logins and expects an empty
   database, so it is not run against `lab` or a copy of it; it rolls itself
   back):

   ```powershell
   createdb -U postgres lab_rolecheck
   psql -X -q -v ON_ERROR_STOP=1 -U postgres -d lab_rolecheck -f design_docs/schema.sql
   psql -X -q -v ON_ERROR_STOP=1 -U postgres -d lab_rolecheck -f design_docs/grants.sql
   psql -X -v ON_ERROR_STOP=1 -U postgres -d lab_rolecheck -f tests/roles_test.sql
   dropdb -U postgres lab_rolecheck
   ```

   It ends with `roles_test.sql: all assertions passed`.
6. **Update the clients everywhere**: the repo on the server (dashboard),
   the MATLAB class on every workstation, and the MCP server wherever it is
   installed. Restart the dashboard task and tell the lab.

If step 3 fails, nothing was changed (one transaction); re-run `grants.sql`
to let clients back in, and investigate. If a problem shows after step 4,
restore the backup from step 1 (§5).

### 6.1 PostgreSQL major-version upgrades

*(Not verified in this repository's testing.)*

A new PostgreSQL major version (16 to 17, say) cannot read the old data
directory. The simplest path here is dump and restore: install the new
version alongside the old one on another port (the EDB installer offers
5433), restore the latest backup set into it with `tools\restore_lab.py
--port 5433 ... lab` (the `.globals.sql` brings the roles), check the
report, stop the old service and set it to Manual, move the new one to port
5432, and update the `--pg-bin` paths in the scheduled tasks. `pg_upgrade` is
faster for large clusters but more involved. On a managed machine the new
version is installed by IT (§9).

---

## 7. Renaming a subject (who may run `lab.fn_rename_subject`)

`subject_id` is the natural key every append-only table refers to, so
renaming an animal is identity maintenance, not an edit: `lab_rw` may not
change it, and `trg_subject_id_guard` refuses the change from any role that
may not execute `lab.fn_rename_subject`. The function is revoked from
`PUBLIC`; the owner (`lab_admin`) can run it:

```sql
SELECT lab.fn_rename_subject('G-0422', 'G-0423');   -- as lab_admin
```

Every rename is recorded in `lab.maintenance_log`. To delegate it to
another administrator, grant `EXECUTE ON FUNCTION lab.fn_rename_subject(text,
text)` to that person's login only, never to `lab_rw`.

---

## 8. Verification checklist

- [ ] `Get-Service postgresql*` shows the service **Running**, start type
      Automatic.
- [ ] The schema and grants were applied by `lab_admin`, and
      `SELECT max(version) FROM lab.schema_version` returns the version the
      clients expect (5).
- [ ] A member's own login can connect from a workstation, insert, and
      `SELECT lab.fn_current_person()` returns their `person_id`; the same
      login cannot `UPDATE lab.person` and cannot rename a subject.
- [ ] `lab_dashboard` can read and cannot insert.
- [ ] From a workstation, `\conninfo` reports SSL (if TLS is required), and
      the `pg_stat_ssl` query in §1.6 shows `ssl = t` for a MATLAB session.
- [ ] After a reboot with nobody signed in, the dashboard answers through
      IIS over HTTPS with campus login, and `http://<server>:8778/` is not
      reachable from another machine.
- [ ] The backup task has produced a set in the backup directory and in the
      `--copy-to` directory, and the check task succeeds.
- [ ] A restore drill (§5) ended with `restore_lab: OK`.
- [ ] The verifier and integrity tasks ran and logged.
- [ ] MATLAB: `CarasLabDB(...)` constructs without error and `CarasLabDBApp()`
      connects through its login dialog.

---

## 9. For IT: MECM-managed Windows 11

A summary the lab can hand to IT. Each item is stated only as far as the lab
can be sure of it; where it says **confirm with IT**, the answer is yours.

- **Software installation and updates are controlled by MECM.** The server
  needs PostgreSQL (one major version, 14 or later, pinned: a major-version
  change needs the dump-and-restore in §6.1 and must not happen as an
  automatic update; minor updates within the version are routine), Python 3
  with the `psycopg` package for the verifier, and, for the dashboard proxy,
  IIS with URL Rewrite and ARR. Whether these are packaged by IT, available
  in Software Center, or installed by the lab with approval: **confirm with
  IT**.
- **Firewall rules** may be owned by Group Policy or MECM, in which case a
  local rule (§1.5) is overridden or removed; the lab then needs inbound TCP
  5432 and 443 opened to the lab subnets and VPN pool only. **Confirm with
  IT** how such rules are requested.
- **Reboots happen in maintenance windows**, so every component must start
  unattended: the PostgreSQL service (automatic start, installed that way),
  the dashboard (an At-startup task, §3.3) and the scheduled jobs (which run
  whether or not anyone is signed in). The lab should be told when windows
  are, because clients cannot record metadata while the server is down.
- **The machine must not sleep or hibernate**; it is a server. Whether the
  power plan is set by policy: **confirm with IT**.
- **Antivirus real-time scanning** of the PostgreSQL data directory
  (`C:\Program Files\PostgreSQL\<version>\data`) should be excluded: the
  PostgreSQL project's guidance for Windows warns that antivirus scanning of
  the data directory can cause failures and corruption. The backup directory
  may stay scanned. **Confirm with IT** how exclusions are requested.
- **Service accounts.** The dashboard and the scheduled jobs run as one
  low-privileged account (`LAB\svc-caraslabdb` in this guide) that needs the
  **"Log on as a batch job"** right for Task Scheduler tasks that run
  without a signed-in user; the PostgreSQL service account (and any account
  run as a Windows service) needs **"Log on as a service"**. It needs read
  access to the repo and the NAS share and write access to the backup
  directories. Whether a domain account, a group-managed service account or
  a local account fits your policy, and whether these rights are granted by
  Group Policy: **confirm with IT**.
- **The clock is synchronised by the domain** (domain-joined machines take
  their time from the domain hierarchy). The database stamps every entry
  with the server's time and those timestamps are part of the lab's
  permanent record, so the clock must stay synchronised.
- **Backups** go to a directory on the server and to an off-machine share
  (`--copy-to`, §4.1); 30 days are kept by default. Where the off-machine copy
  should live and whether it is itself backed up: **confirm with IT**.
- **Credentials** on the machine: the `postgres` password (backup job), and
  the dashboard and verifier passwords, in the service account's password
  file with an ACL restricted to that account and Administrators (§3.2).
  The `lab_admin` password is held by the lab's administrator. Where IT
  expects such credentials to be kept: **confirm with IT**.
- **Certificates** for PostgreSQL TLS (§1.6) and for the dashboard's HTTPS
  binding (§3.4), for the server's DNS names, from the campus CA.

See [deployment-requirements.md](deployment-requirements.md) for the
plain-language summary of what the system needs.
