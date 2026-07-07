# Deploying CarasLabDB on a Synology NAS

Many labs already keep raw ephys data on a Synology NAS — it's the "NAS
storage" component in [overview.md](overview.md). This guide covers running
the **database** and the **live dashboard** on that same box, so the metadata
lives next to the data it describes. It follows the same three-part structure
as [deployment-linux.md](deployment-linux.md), but every step is DSM-specific:
Synology's DSM has no `systemd`, no official PostgreSQL package, and services
are managed through **Container Manager** (Docker) or **Task Scheduler**
instead of `apt`/`dnf`/`systemctl`.

1. **PostgreSQL** — run as a Docker container via Container Manager. There is
   no Package Center Postgres package worth relying on; Docker is the
   supported, repeatable path on DSM 7.
2. **The live web dashboard** (`web/live/`) — also run as a container, on the
   same Docker network as Postgres.
3. **The MATLAB interface** (`@CarasLabDB`/`@CarasLabDBApp`) — does **not**
   run on the NAS. MATLAB isn't available for DSM. Researcher workstations
   run MATLAB as usual (per [deployment-windows.md](deployment-windows.md) or
   §2 of `deployment-linux.md`) and connect to the NAS's Postgres over the
   network.

The static offline dashboard (`web/lab-dashboard.html`) needs nothing NAS
-specific; Synology's **Web Station** package can serve it as a static site if
you want it hosted there, but any static host works.

---

## 0. Prerequisites overview

| Component | Requires | Where it runs |
|-----------|----------|---------------|
| Database | DSM 7.2+, **Container Manager** package, an x86_64 Synology model | The NAS |
| Live dashboard | Same Container Manager stack | The NAS |
| MATLAB interface + GUI | MATLAB **R2025a+** with **Database Toolbox** | Each researcher workstation |
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

---

## 1. Prepare shared folders

**Control Panel → Shared Folder → Create**, or via File Station:

- `docker/caraslabdb/pgdata` — Postgres's data directory (must persist across
  container recreates/upgrades).
- `docker/caraslabdb/app` — where the repo (or just `design_docs/schema.sql`
  and `web/live/`) lives.

Get the repo onto the NAS by whichever transfer method you already use —
`git clone` over SSH (if the **Git Server** package is installed), `rsync`,
`scp`, or dragging files into File Station from a workstation that has it
checked out:

```bash
# from a workstation with the repo checked out and SSH enabled on the NAS
rsync -av --exclude='@CarasLabDB' --exclude='@CarasLabDBApp' \
    ./ admin@nas.local:/volume1/docker/caraslabdb/app/
```

(The MATLAB class folders aren't needed on the NAS — only `design_docs/` and
`web/live/` are used here.)

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
      POSTGRES_PASSWORD: CHANGE_ME
      POSTGRES_DB: lab
      TZ: America/New_York
    volumes:
      - /volume1/docker/caraslabdb/pgdata:/var/lib/postgresql/data
      - /volume1/docker/caraslabdb/app/design_docs:/schema:ro
    ports:
      - "5432:5432"
```

Mounting `design_docs/` read-only into `/schema` gives you a path to apply
`schema.sql` from inside the container without copying it in separately.

If you're using the Container Manager UI: **Project → Create**, point "Path"
at `/volume1/docker/caraslabdb`, paste the compose file, then **Build** →
**Done**. From SSH instead:

```bash
cd /volume1/docker/caraslabdb
sudo docker compose up -d
```

### 2.2 Apply the schema

```bash
sudo docker exec -it caraslabdb-postgres-1 \
    psql -U postgres -d lab -f /schema/schema.sql
```

(Container name may differ slightly — check with `sudo docker ps`; Compose
names containers `<project>-<service>-<n>`.) Verify:

```bash
sudo docker exec -it caraslabdb-postgres-1 \
    psql -U postgres -d lab -c "\dt lab.*"
```

### 2.3 Create the application role

Same append-only privilege model as every other deployment — `SELECT` +
`INSERT`, never `UPDATE`:

```bash
sudo docker exec -it caraslabdb-postgres-1 psql -U postgres -d lab <<'SQL'
CREATE ROLE lab_rw LOGIN PASSWORD 'CHANGE_ME';
GRANT USAGE ON SCHEMA lab TO lab_rw;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA lab TO lab_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA lab TO lab_rw;
SQL
```

Seed at least one `person` row and your reference/lookup data before real use
— the MATLAB client resolves a "current person" at connect time.

### 2.4 Auto-start on reboot

`restart: unless-stopped` plus Container Manager's own "start at boot"
setting (on by default once a container is running) means Postgres comes back
up automatically after a NAS reboot or power loss — no `systemctl enable`
equivalent needed.

---

## 3. Deploy the live dashboard as a container

`web/live/server.py` needs Python 3 and either `psycopg`/`psycopg2` or the
`psql` CLI. Rather than fighting with Package Center's Python3 package and
`pip --user` installs, build a small image so the dependency set is pinned
and reproducible.

### 3.1 Dockerfile

Save as `/volume1/docker/caraslabdb/app/web/live/Dockerfile` (this file is
project-specific to the Synology deployment — it doesn't need to be checked
into the repo unless you want to reuse it elsewhere):

```dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]"
WORKDIR /app
COPY . /app
EXPOSE 8778
CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "8778"]
```

### 3.2 Add it to the compose project

Extend the same `docker-compose.yml` from §2.1 with a second service on the
same Docker network as Postgres, addressed by service name (`postgres`)
instead of an IP:

```yaml
  dashboard:
    build: ./app/web/live
    restart: unless-stopped
    environment:
      PGHOST: postgres
      PGPORT: "5432"
      PGDATABASE: lab
      PGUSER: lab_rw
      PGPASSWORD: CHANGE_ME
    ports:
      - "8778:8778"
    depends_on:
      - postgres
```

Redeploy the project (**Container Manager → Project → Build**, or
`sudo docker compose up -d --build` over SSH). Open
`http://<nas-ip>:8778/` from any machine on the LAN.

Point it at `lab_rw` (or a dedicated read-only role, per
[mcp-server.md](mcp-server.md) §5's suggestion) rather than the Postgres
superuser — the query itself is read-only and the schema blocks
`UPDATE`/`DELETE` regardless, but least privilege costs nothing here.

---

## 4. Networking and firewall

DSM's firewall lives in **Control Panel → Security → Firewall**, not
`ufw`/`firewalld`. Create rules restricting ports **5432** (Postgres) and
**8778** (dashboard) to your lab's LAN subnet, same principle as §1.4 of
`deployment-linux.md`:

- **Control Panel → Security → Firewall → Edit Rules**
- Create a rule per port: **Ports** = single port, **Source IP** = your LAN
  subnet (e.g. `192.168.1.0/24`), **Action** = Allow; leave the implicit
  deny-all after it.

Do **not** forward 5432 or 8778 on your router to the public internet — both
have no auth beyond DB credentials (5432) or nothing at all (8778's
`/api/data` is unauthenticated, per
[web/live/README.md](../web/live/README.md)'s security notes). If remote
access is needed, use Synology's **VPN Server** package or Tailscale instead
of port-forwarding.

Give the NAS a DHCP reservation or static IP (**Control Panel → Network**) so
researcher workstations' `Server=` / `PGHOST=` settings don't break when a
lease renews.

---

## 5. Backups

Same principle as `deployment-linux.md` §5 — back up the whole database
logically, don't rely on a filesystem-level snapshot of a live Postgres data
directory for point-in-time consistency.

**Task Scheduler → Create → Scheduled Task → User-defined script**, running
nightly, with a script like:

```bash
mkdir -p /volume1/docker/caraslabdb/backups
sudo docker exec caraslabdb-postgres-1 \
    pg_dump -U postgres -Fc lab > \
    /volume1/docker/caraslabdb/backups/lab_$(date +%Y%m%d).dump
# prune anything older than 30 days
find /volume1/docker/caraslabdb/backups -name '*.dump' -mtime +30 -delete
```

Point **Hyper Backup** or **Snapshot Replication** at the
`docker/caraslabdb/backups` shared folder for offsite/versioned copies of the
dumps — that gets you both a Postgres-consistent backup (the dump) and
Synology's own backup infrastructure for retention, without needing either
tool to understand Postgres internals.

Restore into a fresh container the same way as any other Postgres instance:
`pg_restore -U postgres -d lab_restored backup.dump`.

---

## 6. Quick verification checklist

- [ ] `sudo docker ps` shows `caraslabdb-postgres-1` and `caraslabdb-dashboard-1`
      (or your project's container names) as **Up**.
- [ ] `sudo docker exec -it caraslabdb-postgres-1 psql -U postgres -d lab -c "\dt lab.*"`
      lists the schema tables.
- [ ] `lab_rw` can `SELECT`/`INSERT` but not `UPDATE`.
- [ ] `curl -s http://<nas-ip>:8778/api/data` returns JSON, not an error object.
- [ ] `http://<nas-ip>:8778/` renders the dashboard in a browser on the LAN.
- [ ] A workstation's MATLAB can `CarasLabDB(Server="<nas-ip>", ...)` and
      construct without error.
- [ ] DSM firewall rules restrict 5432/8778 to the LAN; neither port is
      forwarded on the router.
- [ ] Task Scheduler's nightly dump job has produced at least one `.dump` file
      in `docker/caraslabdb/backups`.
- [ ] After a NAS reboot, both containers come back up on their own (check
      **Container Manager → Container** a few minutes after boot).

---

## 7. "No Docker" fallback

If your Synology model can't run Container Manager, keep Postgres off the NAS
entirely — run it on a Linux server or workstation per
[deployment-linux.md](deployment-linux.md) §1 — and use the NAS only for what
it's already doing: file storage, plus optionally the lightweight live
dashboard reading over the network.

To run just `web/live/server.py` natively:

1. Install **Python 3** from Package Center.
2. Copy `web/live/` to a shared folder, e.g. `/volume1/docker/caraslabdb/app/web/live`
   (the folder name is just a path at this point, no Docker involved).
3. Package Center's Python has no `psycopg` wheel readily available and `pip
   install --user` support varies by DSM version — it's simplest to rely on
   the `psql` CLI fallback `server.py` already supports; install the
   **PostgreSQL client** community package (SynoCommunity) so `psql` is on
   `PATH`.
4. **Task Scheduler → Create → Triggered Task → Boot-up**, running a
   user-defined script that launches the server in the background and logs
   to a file, since DSM has no `systemd`/service manager for user scripts:

   ```bash
   PGHOST=<db-host> PGDATABASE=lab PGUSER=lab_rw PGPASSWORD=CHANGE_ME \
       nohup python3 /volume1/docker/caraslabdb/app/web/live/server.py \
       --host 0.0.0.0 --port 8778 \
       >> /volume1/docker/caraslabdb/app/web/live/server.log 2>&1 &
   ```

This keeps working across reboots (the boot-up trigger re-runs it) but
doesn't restart the process if it crashes mid-uptime the way
`restart: unless-stopped` does — Docker is the more resilient option
whenever your model supports it.
