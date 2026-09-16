# Server requirements for deploying CarasLabDB

We want to deploy a record-keeping database (a 'metadata server') that logs
what happens in the lab (animal births, surgeries, recordings, analyses, etc)
and keeps an index of the data files those activities produce, so that any
result can be traced back to the animal, procedure and recording it came from.
The data files themselves stay on the lab's NAS; the database holds only the
records that describe them.

What we need hosted. One PostgreSQL database server (version 14 or newer) on a
small virtual machine, holding a single database. It stores short text records
only, so a modest virtual machine (2 cores, 4 GB memory, 50 GB disk) would be
sufficient. The same machine will also host a small read-only web dashboard
(a Python 3 program we supply) that shows the database contents in a browser.
Beyond PostgreSQL and Python 3 the server needs no other software and no
direct access to the NAS.

The server must be reachable from the lab's workstations and through the
campus VPN under a stable DNS hostname. The standard PostgreSQL port is 5432,
but any port IT prefers is fine as long as we are told what it is. The
dashboard needs a web address (HTTPS) reachable from the same places, with
campus login in front of it, because the dashboard program has no login of
its own. The server does not need to reach the internet itself (nothing on it
downloads or calls out), although IT may of course allow that for routine
security updates. It should not be reachable from the public internet.

We need IT to create one admin login for the lab, with permission to create
and manage other logins on this database. The lab admin will then create the
read-only login and a personal login for each lab member, and will handle all
membership changes going forward, without involving IT. Each person will have
their own login, so the database can record who made each entry. We also need
a nightly database dump kept on separate storage for at least 30 days. The
server's clock must be set automatically from a network time source (NTP),
because the database records the date and time of every entry and those
timestamps are part of the lab's permanent record.

This page is for IT staff. It describes what the lab needs on the server side
to run the CarasLabDB metadata database, in plain terms, and lists the open
design questions that affect deployment. It does not cover researcher
workstations (MATLAB installs) — those are the lab's responsibility and are
documented separately in `deployment-windows.md` and `deployment-linux.md`.
Step-by-step install commands for Linux, Windows and Synology are in those
guides; this page is the summary of *what* we need, not *how* to build it.

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
- Any operating system PostgreSQL supports (Linux preferred; Windows and
  Docker on a Synology NAS are also documented). A virtual machine is fine.
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

**Accounts (PostgreSQL roles)** — none are created by our schema file. IT
creates only the first row of the table below; the lab admin creates the rest
and manages them from then on:

| Role | Purpose | Privileges |
|---|---|---|
| lab admin login (created by IT) | Applies the schema, creates and manages the other logins, performs rare maintenance (e.g. renaming an animal ID) | Owner of database `lab`; `CREATEROLE` |
| `lab_rw` (group, no login) | Holds the read-write privilege set that every lab member's login inherits | Read and insert on all tables in schema `lab`; update on a small set of descriptive tables (see §3, concern 1) |
| one login per lab member | Used by that person's MATLAB client to record events | Member of `lab_rw`; no privileges of its own |
| `lab_ro` | Used by the dashboard and the read-only AI query tool | Read only |

Per-person logins are a requirement, not a preference: the database is to
record which login made each entry, and that record is only meaningful if
logins are not shared. The privileges live on the group, so a membership
change is one login created or disabled. The lab admin does this without IT:
the admin login needs PostgreSQL's `CREATEROLE` attribute, and because it
creates the `lab_rw` group itself it can add and remove members. If campus
directory authentication (LDAP/Kerberos) is available for PostgreSQL, we would
prefer it to separate passwords; either works for us.

The schema file must be applied by the owner role; it is a single SQL file
(`design_docs/schema.sql`) and takes seconds to run on an empty database.

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
  small, so full nightly dumps are practical indefinitely.
- File-level snapshots of a running PostgreSQL data directory are **not** a
  reliable backup on their own; the dump is what we need.
- A test restore into a scratch database once after setup, and periodically
  thereafter, to confirm the backups are usable.

**Time** — the server's clock must be synchronised (NTP). The database stamps
every record with the server time at insertion, and those timestamps are part
of the provenance record.

**Maintenance** — routine PostgreSQL patching is fine at any time outside
working hours; clients reconnect on their next action. The lab should be told
in advance of planned downtime because there is no offline mode (§3, concern 6).

---

## 2. Live dashboard

`web/live/server.py` is a small Python 3 program (standard library only, no
packages required if the `psql` command is present) that serves one web page
and one JSON endpoint. On every page load it runs one read-only query against
the database and renders charts in the browser.

It runs on the database VM. It needs:

- Python 3. No packages are required if the `psql` command is installed.
- The read-only database login (created by the lab admin; we will supply it).
- To be run as a service that starts at boot (a `systemd` unit is given in
  `deployment-linux.md` §3.2). It listens on one local HTTP port (default
  8778).
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

1. **Documented account privileges do not match what the client does.**
   *(lab)* The deployment guides grant `lab_rw` only read and insert. But the
   schema deliberately leaves the descriptive tables (`subject`, `session`,
   `project`, `project_member`, `project_artifact`, `person`) editable, and
   the MATLAB client issues updates to `subject` and `session`. Under the
   documented grants those operations fail with a permission error. The grant
   script also lacks default-privilege rules, so tables added later would be
   invisible to `lab_rw`/`lab_ro` until re-granted. We will correct the grant
   script; IT only needs to know the final privilege set will include update
   on those specific tables and nothing else.

2. **Recording who made each entry depends on per-person logins.** *(IT +
   lab)* The original deployment guides had every researcher connect as one
   shared `lab_rw` login and identify themselves by an email address the
   client looks up in a `person` table; the database did not verify that
   claim. The lab has decided that the database must record which person
   made each change, so logins are now one per lab member (see §1). The
   client currently still records the self-declared email; we will change it
   to derive the person from the database login so the two cannot disagree.
   IT's part is only the admin login that can create the others and, if
   available, campus directory authentication for them.

3. **Encryption on the wire is unverified.** *(IT decision, then lab
   verification)* None of the clients (MATLAB, Python, `psql`) set an
   SSL/TLS option, so whether traffic is encrypted depends on the server
   configuration and each driver's default. If campus policy requires TLS on
   the database connection, the server needs `ssl = on` with a certificate and
   `hostssl`-only rules in `pg_hba.conf`; we will then confirm MATLAB's native
   PostgreSQL driver negotiates it before anyone relies on it.

4. **The live dashboard is not hardened.** *(lab / IT)* It is Python's
   built-in HTTP server, unauthenticated, plain HTTP, and it returns the
   complete metadata set to any client that reaches it. It is fit for an
   internal network or VPN behind a reverse proxy, not for direct exposure.
   We will not ask for it to be exposed beyond the lab subnet.

5. **There is no schema upgrade mechanism.** *(lab)* `schema.sql` builds a
   fresh, empty database only; it is not a migration script and there is no
   recorded schema version in the database. Once real data exists, every
   schema change will need a hand-written migration applied by the owner role
   in a maintenance window. IT should expect occasional short requests of that
   kind; we will supply the SQL.

6. **Single instance, no offline mode.** *(IT decision)* Clients write
   directly to the database and have no local queue. If the server is down,
   metadata cannot be recorded until it is back, although recordings on the
   rigs continue unaffected. We do not think this justifies a high-availability
   setup, but IT should tell us the expected recovery time for a VM failure so
   the lab can plan around it. Backups need only daily granularity.

7. **Administrative operations need a separate, protected login.** *(IT
   decision)* Renaming an animal's ID is the single sanctioned edit to the
   append-only tables and is implemented as a database function that ordinary
   roles cannot execute. Someone must hold the owner/admin credentials. We
   propose the lab PI and one IT contact; IT should say where such credentials
   are expected to be kept.

8. **Data classification.** *(lab to confirm)* The database holds animal
   research records and the names and emails of lab members. It contains no
   human-subject data and no file contents. We believe this is internal,
   non-sensitive data, but IT may want that stated formally for their records.

---

## 4. What we need back from IT

- Hostname and port of the PostgreSQL server, and which subnets/VPN can reach it.
- Confirmation of the PostgreSQL major version installed.
- Credentials (or a secure hand-off) for the lab admin login, with
  `CREATEROLE` and ownership of database `lab`. The lab creates every other
  login itself.
- The backup schedule, retention period, and where dumps are kept.
- Answers to the *IT decision* items in §3: whether campus directory
  authentication is available, TLS policy, expected recovery time, and where
  admin credentials should live.
- The dashboard's URL.
