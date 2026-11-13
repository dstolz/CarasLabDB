# Deploying CarasLabDB on a Synology NAS

> **The lab's production deployment is on Windows 11**: see
> [deployment-windows.md](deployment-windows.md), the complete guide (role
> model, TLS, scheduled jobs, restore and upgrade runbooks). This guide is an
> alternative for labs that want the database on their Synology NAS. It uses
> the same role model; nothing in it is specific to the Caras Lab's
> production setup.
>
> Nothing in this guide was run in this repository's testing: there is no
> Synology or Docker in it. The SQL is the same as in the other guides, where
> it was run on PostgreSQL 16, and the backup command line follows
> `tools/backup_lab.py`'s documented `--pg-exec` option. Treat DSM menus,
> Docker and compose details as *not verified*.

Many labs already keep raw ephys data on a Synology NAS — it's the "NAS
storage" component in [overview.md](overview.md). This guide covers running
the **database** and the **live dashboard** on that same box, so the metadata
lives next to the data it describes. Synology's DSM has no `systemd`, no
official PostgreSQL package, and services are managed through **Container
Manager** (Docker) or **Task Scheduler** instead of `apt`/`dnf`/`systemctl`.

1. **PostgreSQL** — run as a Docker container via Container Manager. There is
   no Package Center Postgres package worth relying on; Docker is the
   supported, repeatable path on DSM 7.
2. **The live web dashboard** (`web/live/`) — also run as a container, on the
   same Docker network as Postgres, behind a reverse proxy container that
   provides HTTPS and a login.
3. **The MATLAB interface** (`@CarasLabDB`/`@CarasLabDBApp`) — does **not**
   run on the NAS. MATLAB isn't available for DSM. Researcher workstations
   run MATLAB as usual (per [deployment-windows.md](deployment-windows.md) §2
   or [deployment-linux.md](deployment-linux.md) §2) and connect to the NAS's
   Postgres over the network, each with their own login.

The static offline dashboard (`web/lab-dashboard.html`) needs nothing NAS
-specific; Synology's **Web Station** package can serve it as a static site if
you want it hosted there, but any static host works.

---

## 0. Prerequisites overview

| Component | Requires | Where it runs |
|-----------|----------|---------------|
| Database | DSM 7.2+, **Container Manager** package, an x86_64 Synology model | The NAS |
| Live dashboard + proxy | Same Container Manager stack | The NAS |
| Backups | Python 3 on the NAS (to run `tools/backup_lab.py`) | The NAS |
| MATLAB interface + GUI | MATLAB **R2024b+** with **Database Toolbox** | Each researcher workstation |
| Static dashboard | Any modern browser; optionally Web Station | Anywhere |

**Check Docker support before committing to this plan.** Container Manager
(DSM's Docker front end) is only available on Synology models with an
**x86_64 (Intel/AMD) CPU** and enough RAM — the low-end ARM "j"/"+" models
(e.g. DS223j, DS220j) cannot run it at all. Check your model against
Synology's Container Manager compatibility list before proceeding. If your
NAS can't run Docker, see **§7 "No Docker" fallback** below.

This guide assumes:
- DSM 7.2 or later, with admin access to the DSM web UI.
- Container Manager installed from **Package Center**.
- A shared folder will host both the Postgres data directory and the compose
  project files — this guide uses `/volume1/docker/caraslabdb`.

The logins are those of [deployment-windows.md](deployment-windows.md) §0.1:
the `postgres` superuser (used only inside the container, never from the
LAN), a non-superuser owner `lab_admin`, the group roles `lab_rw` and
`lab_ro` (never logins), one login per lab member, and `lab_dashboard` (in
`lab_ro`) for the dashboard.

---

## 1. Prepare shared folders

**Control Panel → Shared Folder → Create**, or via File Station:

- `docker/caraslabdb/pgdata` — Postgres's data directory (must persist across
  container recreates/upgrades).
- `docker/caraslabdb/app` — where the repo (or just `design_docs/`, `tools/`
  and `web/live/`) lives.
- `docker/caraslabdb/backups` — backup sets (§5).
- `docker/caraslabdb/secrets` — the dashboard's password file and the
  proxy's certificate and password list; readable by administrators only.

Get the repo onto the NAS by whichever transfer method you already use —
`git clone` over SSH (if the **Git Server** package is installed), `rsync`,
`scp`, or dragging files into File Station from a workstation that has it
checked out:

```bash
# from a workstation with the repo checked out and SSH enabled on the NAS
rsync -av --exclude='@CarasLabDB' --exclude='@CarasLabDBApp' \
    ./ admin@nas.local:/volume1/docker/caraslabdb/app/
```

(The MATLAB class folders aren't needed on the NAS.)

---

## 2. Deploy PostgreSQL via Container Manager

### 2.1 Create the compose project

Container Manager (DSM 7.2+) supports docker-compose projects directly in its
UI (**Container Manager → Project → Create**), or you can SSH in and run
`docker compose` by hand. Either way, the compose file is the same. Save it as
`/volume1/docker/caraslabdb/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      # Only used to initialise the data directory; replace with a long
      # random value and keep it with the lab's admin credentials.
      POSTGRES_PASSWORD: CHANGE_ME_LONG_RANDOM
      TZ: America/New_York
    volumes:
      - /volume1/docker/caraslabdb/pgdata:/var/lib/postgresql/data
      - /volume1/docker/caraslabdb/app/design_docs:/schema:ro
    ports:
      - "5432:5432"
```

Pin the major version (`postgres:16`, not `latest`): a new major version
cannot read the old data directory and needs a dump and restore (§5).
Mounting `design_docs/` read-only into `/schema` gives you a path to apply
`schema.sql` from inside the container.

If you're using the Container Manager UI: **Project → Create**, point "Path"
at `/volume1/docker/caraslabdb`, paste the compose file, then **Build** →
**Done**. From SSH instead:

```bash
cd /volume1/docker/caraslabdb
sudo docker compose up -d
```

### 2.2 Keep the superuser off the LAN: `pg_hba.conf`

The image's default `pg_hba.conf` accepts every role from every address with
a password, including `postgres`. Edit
`/volume1/docker/caraslabdb/pgdata/pg_hba.conf` so that the superuser is
reachable only through the socket inside the container (`docker exec`), and
the lab's logins only from the lab subnet and the compose network:

```
# TYPE  DATABASE  USER        ADDRESS           METHOD
local   all       all                           trust          # inside the container only
host    lab       +lab_rw     192.168.1.0/24    scram-sha-256
host    lab       +lab_ro     192.168.1.0/24    scram-sha-256
host    lab       +lab_ro     172.16.0.0/12     scram-sha-256  # the compose network (dashboard)
```

and delete the image's `host all all all scram-sha-256` line. Then
`sudo docker compose restart postgres`. Whether connections from the LAN
arrive with their own address or with the Docker gateway's depends on how
DSM's Docker publishes the port: check `pg_stat_activity.client_addr` from a
workstation connection and adjust the subnets.

### 2.3 The owner role, the schema and the grants

Create the owner and the database as `postgres`, then apply the schema and
the grants **as the owner** (`docker exec` reaches the socket, where
`local ... trust` applies):

```bash
P="sudo docker exec -i caraslabdb-postgres-1 psql -X -v ON_ERROR_STOP=1"
$P -U postgres -d postgres -c "CREATE ROLE lab_admin LOGIN CREATEROLE PASSWORD 'CHANGE_ME_ADMIN';"
$P -U postgres -d postgres -c "CREATE DATABASE lab OWNER lab_admin;"
$P -U postgres -d postgres -c "REVOKE ALL ON DATABASE lab FROM PUBLIC;"
$P -U lab_admin -d lab -f /schema/schema.sql
$P -U lab_admin -d lab -f /schema/grants.sql
$P -U lab_admin -d lab -c "SELECT max(version) FROM lab.schema_version;"
```

(Container name may differ slightly — check with `sudo docker ps`; Compose
names containers `<project>-<service>-<n>`.) `grants.sql` creates the group
roles `lab_rw` and `lab_ro` without `LOGIN` and sets every privilege; see
[deployment-windows.md](deployment-windows.md) §1.3 for what they are. Re-run
it after every migration.

### 2.4 Logins

As `lab_admin` (`$P -U lab_admin -d lab`), one login per member, mapped to
their person row, and the dashboard's login:

```sql
CREATE ROLE jdoe LOGIN PASSWORD 'initial-password' IN ROLE lab_rw;
INSERT INTO lab.person (full_name, email, role, db_login)
VALUES ('Jane Doe', 'jdoe@example.edu', 'student', 'jdoe');
CREATE ROLE lab_dashboard LOGIN PASSWORD 'CHANGE_ME_DASH' IN ROLE lab_ro;
```

Offboarding is `ALTER ROLE jdoe NOLOGIN;` (never `DROP ROLE`: the name is in
the log). Seed the reference rows (`storage_root`, `species`, ...) before real use;
members may add them, only `lab_admin` can edit them.

### 2.5 Auto-start on reboot

`restart: unless-stopped` plus Container Manager's own "start at boot"
setting (on by default once a container is running) means Postgres comes back
up automatically after a NAS reboot or power loss — no `systemctl enable`
equivalent needed.

---

## 3. Deploy the live dashboard as a container

`web/live/server.py` needs Python 3 and either `psycopg`/`psycopg2` or the
`psql` CLI. It has **no authentication** and speaks plain HTTP, so it is not
published on the NAS at all; a proxy container on the same compose network
provides HTTPS and a login.

### 3.1 Dockerfile

Save as `/volume1/docker/caraslabdb/app/web/live/Dockerfile` (this file is
specific to the Synology deployment and is not in the repository):

```dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]"
WORKDIR /app
COPY . /app
EXPOSE 8778
# 0.0.0.0 inside the container's own network namespace; the port is not
# published to the NAS, only the proxy reaches it.
CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "8778"]
```

### 3.2 Add it and the proxy to the compose project

The password goes in a libpq password file, not in the compose file:
`/volume1/docker/caraslabdb/secrets/dashboard.pgpass`, mode `600`,
containing `postgres:5432:lab:lab_dashboard:CHANGE_ME_DASH`. Extend
`docker-compose.yml`:

```yaml
  dashboard:
    build: ./app/web/live
    restart: unless-stopped
    environment:
      PGHOST: postgres
      PGPORT: "5432"
      PGDATABASE: lab
      PGUSER: lab_dashboard
      PGPASSFILE: /run/secrets/pgpass
    volumes:
      - /volume1/docker/caraslabdb/secrets/dashboard.pgpass:/run/secrets/pgpass:ro
    depends_on:
      - postgres

  proxy:
    image: nginx:1.27
    restart: unless-stopped
    volumes:
      - /volume1/docker/caraslabdb/secrets/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /volume1/docker/caraslabdb/secrets/tls:/etc/nginx/tls:ro
      - /volume1/docker/caraslabdb/secrets/htpasswd:/etc/nginx/htpasswd:ro
    ports:
      - "8443:443"
    depends_on:
      - dashboard
```

with `nginx.conf`:

```nginx
server {
    listen 443 ssl;
    ssl_certificate     /etc/nginx/tls/dashboard.crt;
    ssl_certificate_key /etc/nginx/tls/dashboard.key;
    auth_basic           "Caras Lab";
    auth_basic_user_file /etc/nginx/htpasswd;
    location / { proxy_pass http://dashboard:8778; }
}
```

The certificate can be the one DSM holds for the NAS's name (exported from
**Control Panel → Security → Certificate**), and `htpasswd` holds one line per
person who may view the dashboard. Redeploy the project (**Container Manager
→ Project → Build**, or `sudo docker compose up -d --build` over SSH) and open
`https://<nas-name>:8443/`.

A finished export is reused for 5 seconds, so page loads inside that window
share one query.

---

## 4. Networking and firewall

DSM's firewall lives in **Control Panel → Security → Firewall**, not
`ufw`/`firewalld`. Create rules restricting ports **5432** (Postgres) and
**8443** (dashboard proxy) to your lab's LAN subnet, same principle as §1.5 of
`deployment-linux.md`:

- **Control Panel → Security → Firewall → Edit Rules**
- Create a rule per port: **Ports** = single port, **Source IP** = your LAN
  subnet (e.g. `192.168.1.0/24`), **Action** = Allow; leave the implicit
  deny-all after it.

Do **not** forward 5432 or 8443 on your router to the public internet. If
remote access is needed, use Synology's **VPN Server** package or Tailscale
instead of port-forwarding.

Give the NAS a DHCP reservation or static IP (**Control Panel → Network**) so
researcher workstations' `Server=` / `PGHOST=` settings don't break when a
lease renews.

---

## 5. Backups, restore and checks

Back up the whole database logically, with its roles, using
`tools/backup_lab.py`; don't rely on a filesystem-level snapshot of a live
Postgres data directory. `--pg-exec` runs each PostgreSQL program inside the
container while the files land on the NAS. It needs Python 3 on the NAS
(Package Center's Python 3 package; whether DSM's own `python3` is enough:
check `python3 --version` over SSH).

**Task Scheduler → Create → Scheduled Task → User-defined script**, user
`root` (it runs `docker exec`), nightly:

```bash
python3 /volume1/docker/caraslabdb/app/tools/backup_lab.py \
    --pg-exec "docker exec -i -e PGUSER=postgres caraslabdb-postgres-1" \
    -d lab --log-file /volume1/docker/caraslabdb/backups/backup.log \
    /volume1/docker/caraslabdb/backups
```

It writes the dump, the roles and a manifest, verifies the dump before
keeping it, and prunes sets older than 30 days only after a new one is in
place. A second daily task monitors it; it fails when there is no readable
dump newer than 26 hours, and Task Scheduler can e-mail on failure:

```bash
python3 /volume1/docker/caraslabdb/app/tools/backup_lab.py \
    --pg-exec "docker exec -i -e PGUSER=postgres caraslabdb-postgres-1" \
    --check 26 -d lab /volume1/docker/caraslabdb/backups
```

**Off-machine copy.** Either add `--copy-to /volume1/<mounted remote share>`
to the backup task (the copy is verified), or point **Hyper Backup** at the
`docker/caraslabdb/backups` folder. The `.globals.sql` files hold every
login's password hash: keep the folder and its copies restricted.

**Restore** with `tools/restore_lab.py` into a new database, the same way:

```bash
python3 /volume1/docker/caraslabdb/app/tools/restore_lab.py \
    --pg-exec "docker exec -i -e PGUSER=postgres caraslabdb-postgres-1" \
    /volume1/docker/caraslabdb/backups/lab_20261113_023000.dump lab_restored
```

It reports row counts against the manifest and `fn_check_integrity()`. To
bring a restored copy into service, and for schema upgrades, follow
[deployment-windows.md](deployment-windows.md) §5 and §6 with
`docker exec ... psql` in place of `psql`.

**Integrity report**, a daily task:

```bash
docker exec caraslabdb-postgres-1 psql -X -tA -U lab_admin -d lab \
    -c "SELECT * FROM lab.fn_check_integrity()"
```

An empty result is healthy. **File verification** (`tools/verify_artifacts.py`)
needs `psycopg` and a mount of the data; run it weekly on a workstation or
server that mounts the NAS shares, as a login in `lab_rw`, per
[deployment-windows.md](deployment-windows.md) §4.2.

---

## 6. Quick verification checklist

- [ ] `sudo docker ps` shows the `postgres`, `dashboard` and `proxy`
      containers as **Up**.
- [ ] `sudo docker exec -it caraslabdb-postgres-1 psql -U lab_admin -d lab -c "\dt lab.*"`
      lists the schema tables, owned by `lab_admin`.
- [ ] A member's own login can `SELECT`/`INSERT` from a workstation, cannot
      `UPDATE` an event, and `SELECT lab.fn_current_person()` returns their
      person.
- [ ] `psql -h <nas-ip> -U postgres` from a workstation is **refused**.
- [ ] `https://<nas-name>:8443/` asks for a login and then renders the
      dashboard; port 8778 is not reachable from the LAN.
- [ ] A workstation's MATLAB can `CarasLabDB(Server="<nas-ip>", ...)` and
      construct without error.
- [ ] DSM firewall rules restrict 5432/8443 to the LAN; neither port is
      forwarded on the router.
- [ ] The nightly backup task has produced a set in `docker/caraslabdb/backups`
      and the check task succeeds; a restore into `lab_restored` ended with
      `restore_lab: OK`.
- [ ] After a NAS reboot, the containers come back up on their own (check
      **Container Manager → Container** a few minutes after boot).

---

## 7. "No Docker" fallback

If your Synology model can't run Container Manager, keep Postgres off the NAS
entirely — run it on a Windows or Linux server per
[deployment-windows.md](deployment-windows.md) or
[deployment-linux.md](deployment-linux.md) — and use the NAS only for what
it's already doing: file storage, plus optionally the lightweight live
dashboard reading over the network.

To run just `web/live/server.py` natively:

1. Install **Python 3** from Package Center.
2. Copy `web/live/` to a shared folder, e.g. `/volume1/docker/caraslabdb/app/web/live`.
3. Package Center's Python has no `psycopg` wheel readily available and `pip
   install --user` support varies by DSM version — it's simplest to rely on
   the `psql` CLI fallback `server.py` already supports; install the
   **PostgreSQL client** community package (SynoCommunity) so `psql` is on
   `PATH`.
4. Put `lab_dashboard`'s password in a password file readable only by the
   user that runs the task (mode `600`), not on the command line.
5. **Task Scheduler → Create → Triggered Task → Boot-up**, running a
   user-defined script that launches the server in the background, bound to
   the NAS itself, and logs to a file:

   ```bash
   PGHOST=<db-host> PGDATABASE=lab PGUSER=lab_dashboard \
   PGPASSFILE=/volume1/docker/caraslabdb/secrets/dashboard.pgpass \
       nohup python3 /volume1/docker/caraslabdb/app/web/live/server.py \
       --host 127.0.0.1 --port 8778 \
       >> /volume1/docker/caraslabdb/app/web/live/server.log 2>&1 &
   ```

6. Put a proxy in front of it that provides HTTPS **and** a login. DSM's
   built-in reverse proxy (**Control Panel → Login Portal → Advanced →
   Reverse Proxy**) provides HTTPS; whether your DSM version can also
   require a login there, check before relying on it, and otherwise keep the
   dashboard reachable only over the VPN.

This keeps working across reboots (the boot-up trigger re-runs it) but
doesn't restart the process if it crashes mid-uptime the way
`restart: unless-stopped` does — Docker is the more resilient option
whenever your model supports it.
