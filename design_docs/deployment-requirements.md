# Server requirements for deploying CarasLabDB

> **Status.** The lab deploys CarasLabDB on a Windows 11 machine managed
> through Microsoft Endpoint Configuration Manager (MECM), used as the lab's
> server. The step-by-step guide is
> [deployment-windows.md](deployment-windows.md); its §9, "For IT:
> MECM-managed Windows 11", lists what that arrangement needs from IT. The
> requirements below hold for any arrangement.

We want to deploy a record-keeping database (a 'metadata server') that logs
what happens in the lab (animal births, surgeries, recordings, analyses, etc)
and keeps an index of the data files those activities produce, so that any
result can be traced back to the animal, procedure and recording it came from.
The data files themselves stay on the lab's NAS; the database holds only the
records that describe them.

What we need. A PostgreSQL database (version 14 or newer) holding a single
database of short text records. The load is small: a modest virtual machine
(2 cores, 4 GB memory, 50 GB disk) would be more than enough, and nothing
beyond PostgreSQL and Python 3 is needed on it. Alongside the database we have
a small read-only web dashboard (a Python 3 program we supply) that shows the
database contents in a browser; we would like it hosted on the same machine
or wherever you suggest.

We are flexible about how this is provided. A dedicated virtual machine on
the campus network with an administrator login for the lab would let us
install and maintain everything ourselves from our own guides, which is our
preference. A managed PostgreSQL service, or a machine that IT sets up for
us, would also work. We would appreciate knowing which of these you offer.

Whatever the arrangement, the database needs to be reachable from the lab's
workstations and through the campus VPN under a stable DNS hostname (the
standard PostgreSQL port is 5432, but any port is fine as long as we know
it), and the dashboard needs a web address (HTTPS) reachable from the same
places with campus login in front of it, since the dashboard program has no
login of its own. Neither should be reachable from the public internet, and
nothing on the server needs to reach the internet itself.

Each lab member will have their own database login, so the database can
record who made each entry, and lab membership changes fairly often. We would
like the lab's admin login to be able to create and disable these logins
ourselves; if that is not possible on your service, we would need a simple
way to request them. We also need a nightly database dump kept on separate
storage for at least 30 days, and the server's clock set automatically from a
network time source (NTP), because the database records the date and time of
every entry and those timestamps are part of the lab's permanent record.

This page is for IT staff. It describes what the lab needs on the server side
to run the CarasLabDB metadata database, in plain terms, and lists the open
design questions that affect deployment. It does not cover researcher
workstations (MATLAB installs) — those are the lab's responsibility and are
documented separately in `deployment-windows.md` and `deployment-linux.md`.
Step-by-step install commands for Windows (the production guide), Linux and
Synology are in the deployment guides; this page is the summary of *what* we need, not *how* to build it.

## What the system is

CarasLabDB is a small PostgreSQL database that records *what happened* in the
lab — animal births, surgeries, recordings, analyses — and indexes the data
files those events produced. It stores **metadata only**: file paths and
checksums, not the files themselves. The multi-terabyte recording data stays on
the lab's existing NAS and is never copied into the database.

The database is **append-only by design**: rows are never edited or deleted;
corrections are added as new rows that point at the row they replace. Database
triggers enforce this. This matters for backups (the data only grows, and
historical rows are meaningful) and for account privileges (see §3).

## What we are asking IT to host

| Item | Required? | What it is |
|---|---|---|
| PostgreSQL server | **Yes** | The database. One instance, one database named `lab`. |
| Backups of that database | **Yes** | Nightly logical dump, retained off-box. |
| A stable hostname | **Yes** | Every client is configured with the server name; it must not change. |
| Network access to the database port | **Yes** | From lab workstations to the server, on the campus network or VPN. Port 5432 by default; any port works. |
| Live web dashboard | **Yes** | A small Python web service on the same VM that shows the database contents in a browser. Read-only. Needs HTTPS and campus login in front of it. |

Everything else (MATLAB, the read-only "MCP" query tool for AI assistants,
the offline demo dashboard) runs on researchers' own machines and only needs
to *reach* the database over the network.

---

## 1. PostgreSQL server

**Software**

- PostgreSQL **version 14 or newer**. Any currently supported major release
  is fine; we recommend whichever IT normally deploys. No extensions are
  required (the schema uses only built-in features).
- Any operating system PostgreSQL supports. The lab's deployment is on a
  MECM-managed Windows 11 machine; Linux and Docker on a Synology NAS are
  also documented. A virtual machine is fine.
- Python 3 for the dashboard (§2). The server does **not** need MATLAB or a
  mount of the NAS, and nothing on it needs outbound internet access
  (allowing it for OS and PostgreSQL updates is IT's call).

**Size** (our estimate from the schema; the database stores short text
records, not data files)

| Resource | Estimate |
|---|---|
| CPU | 2 cores |
| Memory | 4 GB |
| Disk for the database | 50 GB is generous; growth is on the order of hundreds of MB per year |
| Concurrent connections | Fewer than 20 typical; PostgreSQL's default limit of 100 is sufficient |

A single small VM is adequate. There is no expected performance concern at
lab scale.

**Accounts (PostgreSQL roles)** — none are created by our schema file. Our
preference is that IT creates only the first row of the table below and the
lab admin creates the rest and manages them from then on; if that is not
possible, we need a simple way to request the others:

| Role | Purpose | Privileges |
|---|---|---|
| lab admin login | Applies the schema and its upgrades, creates and disables the other logins, performs rare maintenance (e.g. renaming an animal ID) | Owner of database `lab`, **not** a superuser; `CREATEROLE` if permitted |
| `lab_rw` (group, no login) | Holds the read-write privilege set that every lab member's login inherits | Read and insert on the tables in schema `lab`; update on a small set of descriptive tables (see §3, concern 1) |
| one login per lab member | Used by that person's MATLAB client to record events | Member of `lab_rw`; no privileges of its own |
| `lab_ro` (group, no login) | Holds the read-only privilege set | Read only |
| dashboard login, AI-tool login | Used by the live dashboard and by the read-only AI query tool | Members of `lab_ro` |
| file-verification login | Used by the scheduled job that checks the data files against their checksums | Member of `lab_rw` |
| `postgres` superuser | Used only by the nightly backup (which includes the logins) and for restores | Superuser; not reachable from the network |

Per-person logins are a requirement, not a preference: the database is to
record which login made each entry, and that record is only meaningful if
logins are not shared. The privileges live on the group, so a membership
change is one login created or disabled. We would like the lab admin to do
this without a ticket, which needs PostgreSQL's `CREATEROLE` attribute on the
admin login (and, if it creates the `lab_rw` group itself, it can then add and
remove members). On a shared, managed cluster that may not be permitted; in
that case we need a request procedure. If campus directory authentication
(LDAP/Kerberos) is available for PostgreSQL, we would prefer it to separate
passwords; either works for us.

The schema file must be applied by the owner role; it is a single SQL file
(`design_docs/schema.sql`) and takes seconds to run on an empty database. The
privileges above are then applied by a second file, `design_docs/grants.sql`.

**Network**

- Listen on one TCP port, reachable from the lab's workstation subnet(s) and
  from the campus VPN. It must **not** be reachable from the public internet.
  PostgreSQL's default is **5432**; any other port is acceptable, since every
  client takes the port as a setting. We only need to know which one.
- Password authentication (`scram-sha-256`, the PostgreSQL default) restricted
  to those subnets in `pg_hba.conf`.
- A **DNS hostname** for the server. Clients store the hostname in their
  saved settings; an IP that changes breaks every workstation.
- Encryption in transit: see §3, concern 3. We would like IT's policy on this.

**Backups**

- A nightly `pg_dump` of database `lab` (custom format), copied to storage
  separate from the server, retained for at least 30 days. The database is
  small, so full nightly dumps are practical indefinitely. We supply
  `tools/backup_lab.py`, which takes the dump together with the logins and a
  manifest, verifies it, copies it to a second location (`--copy-to`) and
  prunes old sets only after a new one succeeded, plus a `--check` mode for
  monitoring; `tools/restore_lab.py` restores a set into a new database and
  checks it against the manifest. Both are Python 3, standard library only,
  and run as the PostgreSQL superuser on the server. If IT's own backup
  system takes the dumps instead, that is equally fine.
- File-level snapshots of a running PostgreSQL data directory are **not** a
  reliable backup on their own; the dump is what we need.
- A test restore into a scratch database once after setup, and periodically
  thereafter, to confirm the backups are usable.

**Time** — the server's clock must be synchronised (NTP). The database stamps
every record with the server time at insertion, and those timestamps are part
of the provenance record.

**Maintenance** — routine PostgreSQL patching is fine at any time outside
working hours; clients reconnect on their next action. The lab should be told
in advance of planned downtime: only clients that queue (§3, concern 6) keep
recording while the server is down.

---

## 2. Live dashboard

`web/live/server.py` is a small Python 3 program (standard library only, no
packages required if the `psql` command is present) that serves one web page
and one JSON endpoint. It runs one read-only query against the database and
reuses the result for 5 seconds, so page loads within that window share it;
the browser renders the charts.

Preferably on the database machine. It needs:

- Python 3. No packages are required if the `psql` command is installed.
- Its own database login, a member of `lab_ro`.
- To start at boot without anyone signed in (a Task Scheduler task on
  Windows, `deployment-windows.md` §3.3; a `systemd` unit on Linux). It
  listens on one HTTP port on 127.0.0.1 only (default 8778).
- **A reverse proxy in front of it that provides HTTPS and campus login**,
  reachable from the lab subnet and VPN only. The program itself has no
  authentication and speaks plain HTTP, so it must not be exposed directly.
  See §3, concern 4.
- Browsers viewing it need outbound access to `cdn.jsdelivr.net` to load one
  charting library.

---

## 3. Design concerns that affect deployment

These were found while reviewing the code and documentation for this page.
Items marked *lab* are ours to fix later and are listed so IT knows they are
known; items marked *IT decision* need input before go-live.

1. **Account privileges.** *(lab; resolved)* The privilege set is one
   script, `design_docs/grants.sql`, which every guide applies. `lab_rw` can
   read, and insert everywhere except the logs only the database writes, and
   can update only the descriptive tables the MATLAB client edits (`session`,
   `project`, `project_member`, `project_artifact`, the tag vocabulary
   `tag_namespace` / `tag`, the variable definitions `variable`, and the
   descriptive columns of `subject`, not its ID); every such edit is recorded
   in the database with the login that made it. It cannot edit the `person`
   table or say which login belongs to which person, and cannot rename an
   animal. `lab_ro` can only read. Default-privilege rules cover tables added
   later.

2. **Recording who made each entry depends on per-person logins.** *(IT +
   lab; resolved in the software)* Logins are one per lab member (see §1).
   The database itself stamps the connected login on every entry and on
   every edit, whatever the client sends, and maps each login to the lab
   member it belongs to (set by the lab admin only); when the client names
   no person, the database fills in the login's person, and the MATLAB
   client takes the current person from the same mapping. Onboarding is a
   new login plus that mapping; offboarding disables the login (it is never
   deleted, because its name is in the record). IT's part is the admin
   login, ideally able to create the others, and, if available, campus
   directory authentication for them.

3. **Encryption on the wire is unverified.** *(IT decision, then lab
   verification)* None of the clients (MATLAB, Python, `psql`) set an
   SSL/TLS option, so whether traffic is encrypted depends on the server
   configuration and each driver's default. If campus policy requires TLS on
   the database connection, the server needs `ssl = on` with a certificate and
   `hostssl`-only rules in `pg_hba.conf` (`deployment-windows.md` §1.6); we
   will then confirm MATLAB's native PostgreSQL driver negotiates it before
   anyone relies on it.

4. **The live dashboard is not hardened.** *(lab / IT)* It is Python's
   built-in HTTP server, unauthenticated, plain HTTP, and it returns the
   complete metadata set to any client that reaches it. It is fit for an
   internal network or VPN behind a reverse proxy, not for direct exposure.
   We will not ask for it to be exposed beyond the lab subnet.

5. **Schema upgrades.** *(lab)* `schema.sql` builds a fresh, empty database.
   The database records its schema version (`lab.schema_version`), and an
   existing database is upgraded by the numbered scripts in
   `design_docs/migrations/`, each applied once by the owner role in a
   maintenance window, after a backup, and refusing to run twice. The
   database has not been launched: the current version is 1 and there are
   no migrations yet. The lab admin login applies them; the runbook is
   `deployment-windows.md` §6.

6. **Single instance; clients may queue.** *(IT decision)* The database is
   one instance. The MATLAB class writes directly to it, but a client may
   keep what it has to record while the server is down and send it later:
   the ephys_analysis toolbox does this, and `recordEvent` makes such a late
   send safe to repeat. Records a client does not queue cannot be made until
   the server is back, although recordings on the rigs continue unaffected. We do not think this justifies a high-availability
   setup, but IT should tell us the expected recovery time for a VM failure so
   the lab can plan around it. Backups need only daily granularity.

7. **Administrative operations need a separate, protected login.** *(IT
   decision)* Renaming an animal's ID is the single sanctioned edit to the
   append-only tables and is implemented as a database function that ordinary
   roles cannot execute; the owner (the lab admin login) can. Someone must
   hold the owner/admin credentials. We
   propose the lab PI and one IT contact; IT should say where such credentials
   are expected to be kept.

8. **Data classification.** *(lab to confirm)* The database holds animal
   research records and the names and emails of lab members. It contains no
   human-subject data and no file contents. We believe this is internal,
   non-sensitive data, but IT may want that stated formally for their records.

---

## 4. What we need back from IT

- Which hosting arrangement is available: a VM we administer, a managed
  PostgreSQL service, or a machine IT sets up for us.
- Hostname and port of the PostgreSQL server, and which subnets/VPN can reach it.
- Confirmation of the PostgreSQL major version installed.
- Credentials (or a secure hand-off) for the lab admin login, owning
  database `lab` and, if permitted, with `CREATEROLE` so the lab creates the
  other logins itself; otherwise, the procedure for requesting logins.
- The backup schedule, retention period, and where dumps are kept.
- Answers to the *IT decision* items in §3: whether campus directory
  authentication is available, TLS policy, expected recovery time, and where
  admin credentials should live.
- The dashboard's URL.
