# Live dashboard (`web/live/`)

A **database-backed** version of the Lab Metadata Explorer. It reuses the exact
markup, styling, and render/drill-down logic of the self-contained offline demo
(`web/lab-dashboard.html`), but instead of generating a synthetic dataset in the
browser it fetches the real data from Postgres.

```
web/live/
├── lab-dashboard-live.html   the dashboard page (fetches /api/data on load)
├── server.py                 tiny stdlib HTTP server: static files + /api/data
├── lab_data.sql              one query that emits the whole LAB_DATA payload
└── README.md                 this file
```

## How it fits together

1. `server.py` serves `lab-dashboard-live.html` and exposes one JSON endpoint,
   `GET /api/data`.
2. `/api/data` runs `lab_data.sql` against the live `lab` schema. That query
   returns a **single JSON object** shaped exactly like the `window.LAB_DATA`
   contract the dashboard consumes (one array per table; each event carries its
   class-table-inheritance row as a `detail` object; each artifact carries its
   latest `verification`; timestamps are UTC ISO-8601 strings and `NOW` is epoch
   milliseconds).
3. The page's loader assigns the response to `window.LAB_DATA` and boots the
   dashboard. Everything downstream — filters, KPIs, charts, timelines,
   provenance lineage — is the same code the offline demo runs.

Full history is returned (superseded rows included); active vs. superseded state
is derived in the browser from the `supersedes` links, mirroring the
`lab.event_active` / `lab.artifact_active` views. The **Active only** toggle
hides superseded rows; **↻ Refresh** re-queries the database.

## Running it

Prerequisite: a reachable Postgres with the schema applied
(`createdb lab && psql -d lab -f design_docs/schema.sql`).

From the repo root:

```bash
PGDATABASE=lab python web/live/server.py --port 8778
# then open http://127.0.0.1:8778/
```

On Windows PowerShell:

```powershell
$env:PGDATABASE = "lab"; python web/live/server.py --port 8778
```

Or start the **`lab-web-live`** launch configuration.

### Connection settings

Connection details come from the standard libpq environment variables — the
same ones `psql` uses — so there is nothing app-specific to configure:

| Variable     | Default            |
| ------------ | ------------------ |
| `PGHOST`     | local socket / localhost |
| `PGPORT`     | `5432`             |
| `PGDATABASE` | `lab`              |
| `PGUSER`     | current OS user    |
| `PGPASSWORD` | (or a `~/.pgpass` entry) |

`--db NAME` is a shortcut for setting `PGDATABASE`.

### Data-access backends

`server.py` reads the database through whichever of these is available, in
order — no Python package install is strictly required:

1. `psycopg` (v3), else
2. `psycopg2`, else
3. the `psql` CLI (shelled out; reads the same `PG*` variables).

If none can reach the database, `/api/data` returns HTTP 503 with a JSON
`{error, detail}` body, and the page shows an error card with a **Retry**
button rather than a blank screen.

## Static export (no server)

`lab_data.sql` is also usable standalone to snapshot the database to a file the
offline demo could load:

```bash
psql -tAXq -v ON_ERROR_STOP=1 -d lab -f web/live/lab_data.sql > lab-data.json
```

`-q` matters: `-t`/`-A` only control result-tuple formatting, so without it psql
also prints the `SET` command-status tag for the query's leading
`SET TIME ZONE` and the file is no longer valid JSON.

## Security notes

- The query is **read-only**; the schema additionally blocks `UPDATE`/`DELETE`
  via triggers. Point the server at a least-privilege, read-only role.
- The server binds to `127.0.0.1` by default. Only pass `--host 0.0.0.0` behind
  a trusted network or a reverse proxy — there is no authentication layer here.
- `/api/data` returns the full metadata payload to any client that can reach it;
  keep it on an internal network.
