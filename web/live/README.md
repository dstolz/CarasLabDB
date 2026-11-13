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
   latest `verification`; the tag vocabulary comes as `tagNamespaces` and
   `tags`, and the whole append-only tag log as `tagAssignments`, each row
   naming its entity by `entity_kind` + `entity_id`; timestamps are UTC
   ISO-8601 strings and `NOW` is epoch milliseconds).
3. The page's loader assigns the response to `window.LAB_DATA` and boots the
   dashboard. Everything downstream — filters, KPIs, charts, timelines,
   provenance lineage — is the same code the offline demo runs.

Full history is returned (superseded rows included); active vs. superseded state
is derived in the browser from the `supersedes` links, mirroring the
`lab.event_active` / `lab.artifact_active` views. Current tags are derived the
same way from the tag log, mirroring `lab.tag_current`: the latest row per
entity and tag by `assignment_id` counts if it is an `add`. The
**Active only** toggle hides superseded rows; **↻ Refresh** re-queries the
database.

What the page derives is meant to equal what the database's own views and
functions return, so the same question gets the same answer in MATLAB, in the
MCP server and here:

- **Latest weight** per subject uses the order of `lab.subject_current`
  (`occurred_at`, then `event_id`); `occurred_at` is exported with its
  microseconds for that reason.
- **Verification** is each artifact's row in `lab.artifact_verification_latest`:
  the latest check of the *file*, so a corrected artifact row keeps its file's
  state instead of reading "unverified".
- **Lineage** follows corrections like `lab.fn_artifact_lineage` does by
  default: every row listed is a current version, to the same depth cap of 64,
  and the dialog says so when the cap cut it short.
- **Storage totals** count each file (storage root, path, checksum) once, also
  with superseded rows shown.
- The **From/To** filter dates a file by the event that produced it, so an
  event and its files are always in or out together.

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

If none can reach the database, `/api/data` returns HTTP 503 with a fixed
JSON `{error, detail}` body, and the page shows an error card with a **Retry**
button rather than a blank screen. The driver's own message, which can name
the host and login, goes to the server's stderr log only.

### Caching and what is served

A finished export is reused for 5 seconds (`CACHE_SECONDS` in `server.py`),
counted from the moment it finished: requests inside that window, including a
press of `r`, get the same payload, however long the query took. Requests that
arrive while an export is running wait for that one rather than starting their
own, so a burst of page loads costs one query.

The export runs in a `READ ONLY` transaction that is rolled back, with a
connect timeout (`PGCONNECT_TIMEOUT`, default 10 s) and a statement timeout
(`LAB_DASHBOARD_STATEMENT_TIMEOUT`, seconds, default 120). A request never
waits longer than the two together plus a small margin; after that it gets a
503 with `Retry-After`, and an export that still has not returned is abandoned
so the next request starts a fresh one. After a failed export, requests in the
next 2 seconds are answered from that failure instead of each waiting out its
own connect timeout.

The payload is gzip-compressed for clients whose `Accept-Encoding` allows gzip
(`gzip;q=0` is honoured). `GET` and `HEAD` are answered for `/` (the page) and
`/api/data`; every other path is a 404, so nothing else in `web/live/` is ever
published. Every response carries `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY`, `Content-Security-Policy: frame-ancestors 'none'` and
`Referrer-Policy: no-referrer`; `/api/data` is `Cache-Control: no-store` and
the page `no-cache`, so an upgraded page is picked up on the next load.

### Charts

Chart.js (pinned version, with a Subresource Integrity hash) is the one thing
the page loads from outside, from `cdn.jsdelivr.net`. It is loaded without
blocking: the tables and KPIs render at once, the charts appear when the
library arrives, and if it fails or has not arrived 8 seconds after the page
started loading, a "Charts unavailable" notice takes their place. Nothing else
depends on it.

## Static export (no server)

`lab_data.sql` is also usable standalone to snapshot the database to a file the
offline demo could load:

```bash
PGTZ=UTC psql -tAXq -v ON_ERROR_STOP=1 -d lab -f web/live/lab_data.sql > lab-data.json
```

`lab_data.sql` is a single statement. `PGTZ=UTC` matches what `server.py`
does: top-level timestamps are rendered in UTC either way, and it makes the
offsets inside per-event `detail` objects UTC as well.

## Security notes

- **Run it as a read-only login.** Create a login that inherits `lab_ro`
  (`CREATE ROLE lab_dashboard LOGIN PASSWORD '...' IN ROLE lab_ro;` —
  `design_docs/grants.sql` sets up `lab_ro`) and set `PGUSER` to it. Do not run
  it as `lab_rw`, a personal login or the owner. The server opens the export in
  a `READ ONLY` transaction and rolls it back, but that is a second line of
  defence, not a substitute for a role that cannot write.
- **Keep it on `127.0.0.1` behind a reverse proxy.** The server has no
  authentication and speaks plain HTTP, and `/api/data` returns the full
  metadata payload to any client that can reach it. Leave `--host` at its
  default and put nginx/Apache with HTTPS and your campus login in front of it;
  it prints a warning at start-up when bound to anything else.
- Every string on the page comes from the database and was typed by a lab
  member or written by a script. The page escapes all of it, links only
  `http`/`https` URIs, and never renders a `file:` link from a served page
  (browsers refuse to follow them, so the folder is shown as text).
