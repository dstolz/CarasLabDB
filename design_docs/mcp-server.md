# MCP Server — Read-Only LLM Access to the `lab` Schema

This document describes `mcp-server/`, a [Model Context Protocol](https://modelcontextprotocol.io)
server that lets an LLM agent (Claude Code, Claude Desktop, or any other MCP
client) query the `lab` Postgres schema directly during a conversation. It is
a **fourth, independent interface** to the same schema described in
[overview.md](overview.md) and [database-design.md](database-design.md),
alongside `@CarasLabDB/` (MATLAB class), `@CarasLabDBApp/` (MATLAB GUI), and
`web/` (dashboard). It shares no code with those — only the schema and the
libpq environment-variable connection convention already used by
`web/live/server.py`.

The implementation lives at `mcp-server/src/caraslabdb_mcp/`. This doc covers
why it's built the way it is, how to stand it up, and how to extend it
without breaking its one hard invariant: **it cannot write to the database.**

---

## 1. Why this exists

The other three interfaces all require a MATLAB session or a browser tab open
to a specific dashboard. An LLM agent working in this repo — reviewing a
schema change, debugging a MATLAB method, or just answering "what recordings
exist for subject G-0421" — has no way to look at live data without one of
those. The MCP server closes that gap: it gives the agent typed, read-only
tools that mirror `@CarasLabDB`'s `get*` method surface, callable directly
from the conversation.

Write access (event/artifact inserts, supersede corrections) is an
intentional future phase, not part of v1. Keeping v1 read-only means an LLM
agent can be given this tool with much lower review burden than a write
surface would require.

## 2. Architecture

```
mcp-server/
  pyproject.toml                    # deps: mcp, psycopg[binary] (or psycopg2)
  src/caraslabdb_mcp/
    server.py                       # FastMCP app; registers all tool modules
    db.py                           # connection + READ ONLY transaction wrapper
    schema_map.py                   # fixed event_type -> detail table/columns map
    tools/
      reference.py                  # get_species, get_probes, get_pipelines, ...
      dimensions.py                 # get_persons, get_projects, get_subjects, ...
      events.py                     # get_events, get_event_detail
      artifacts.py                  # get_artifacts, get_event_inputs, ...
      provenance.py                 # get_artifact_lineage, get_provenance_edges
```

- **`server.py`** builds a `FastMCP("caraslabdb")` app and calls each tool
  module's `register(app)`, then runs over stdio. This is the process Claude
  Code/Desktop launches per the MCP stdio transport.
- **`db.py`** owns *all* SQL execution. `fetch_all(sql, params)` runs a
  parameterized query and returns rows as `column -> value` dicts.
  `select_from(table, filters, limit, order_by)` builds a `SELECT * FROM
  <table> WHERE <filters ANDed>` for the common case, where `filters` values
  that are `None` are dropped (i.e. "not filtering on this column") and every
  non-`None` value is bound as a query parameter — never interpolated into
  SQL text.
- **`schema_map.py`** hardcodes the 8 event types to their detail
  table/columns (built by hand from `schema.sql`, not introspected at
  runtime). This is the one place `get_event_detail` needs a table name that
  depends on data read from the database (the event's `event_type` string);
  looking it up in this fixed dict means a caller can never smuggle an
  arbitrary table name in via that column's value.
- **`tools/*.py`** each define a handful of `@app.tool()`-decorated functions
  with typed, named parameters (`Optional[str]`, `bool`, `int`, ...). There is
  **no generic SQL/JSON-blob tool** — every parameter name is a real schema
  column, so the tool signatures double as documentation for the calling LLM.

### The read-only guarantee

Every query goes through `db._read_only_cursor()`:

```python
cur.execute("SET TRANSACTION READ ONLY")
...
conn.rollback()
conn.close()
```

`SET TRANSACTION READ ONLY` must be the first statement in the transaction to
take effect — `db.py` issues it before any tool-supplied SQL runs. Even if a
future tool had a bug that built an `INSERT`/`UPDATE`/`DELETE` statement,
Postgres itself would reject it at the transaction level, and the connection
is rolled back and closed afterward regardless. This mirrors the defense
pattern in `@CarasLabDB/runReadOnlyQuery.m` — belt-and-suspenders on top of
"we just don't write insert code here."

The only two places a tool builds SQL with any dynamic structure (not just
bound parameter values) are:

- `events.get_event_detail`, which looks up the detail table name in
  `schema_map.EVENT_DETAIL_TABLE` — a fixed dict, not the raw `event_type`
  string.
- `provenance.get_artifact_lineage`, which validates `direction` is exactly
  `"up"` or `"down"` (raising `ValueError` otherwise) before passing it to
  `lab.fn_artifact_lineage(...)`.

Every other tool parameter flows into `select_from`'s `filters` dict as a
bound value, never as SQL text.

## 3. Tool surface

All tools return `list[dict]` (one dict per row) except `get_event_detail`,
which returns a single `dict`. Every optional parameter that's left as
`None`/default is simply excluded from the `WHERE` clause, matching
`@CarasLabDB`'s pattern of omitting unset Name=Value args from a query.

| Module | Tools |
|---|---|
| `reference.py` | `get_species`, `get_storage_roots`, `get_probes`, `get_pipelines`, `get_event_types`, `get_artifact_roles`, `get_acquisition_systems` |
| `dimensions.py` | `get_persons`, `get_projects`, `get_project_members`, `get_project_artifacts`, `get_subjects`, `get_sessions`, `get_subject_current` |
| `events.py` | `get_events` (filter by `event_type`/`subject_id`/`session_id`, `active_only` toggles `event_active` vs. `event`), `get_event_detail` (joins base event to its type-specific detail table) |
| `artifacts.py` | `get_artifacts` (`active_only` toggles `artifact_active` vs. `artifact`), `get_event_inputs`, `get_artifact_verifications` |
| `provenance.py` | `get_artifact_lineage` (wraps `lab.fn_artifact_lineage`, `direction="up"\|"down"`), `get_provenance_edges` |

`active_only` defaults to `True` everywhere it appears, so queries read the
`*_active` views (non-superseded rows) by default — same default as
`@CarasLabDB`'s `UseActiveViews`. Pass `active_only=False` to see full
correction history, including superseded rows.

## 4. Install

```powershell
cd mcp-server
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e .
```

This installs the `mcp` SDK and `psycopg[binary]` (v3). To use `psycopg2`
instead: `pip install -e .[psycopg2]` (`db.py` tries `psycopg` first, falls
back to `psycopg2` on `ImportError`).

`mcp-server/.venv/` is git-ignored — the environment above is local to your
machine, not something committed to the repo.

## 5. Configure

Connection settings come from the standard libpq environment variables — the
same convention as `web/live/server.py` and the MATLAB class:

| Variable | Default |
|---|---|
| `PGHOST` | local socket / localhost |
| `PGPORT` | 5432 |
| `PGDATABASE` | `lab` (set by `db.py` via `os.environ.setdefault` if unset) |
| `PGUSER` | OS user |
| `PGPASSWORD` | (or a `~/.pgpass` entry) |

There is no other server config — no config file, no port to open, no
network listener. The server speaks MCP over **stdio**; the client process
(Claude Code/Desktop) launches it as a subprocess and communicates over its
stdin/stdout.

For local testing against a scratch database, follow
[testing-locally.md](testing-locally.md) §1 to stand up `lab_test`, then set
`PGDATABASE=lab_test` before registering the server. Point it at the
**`lab_rw`** role from that guide (`SELECT`/`INSERT` only, no `UPDATE`) if you
want a second layer of protection beyond the `READ ONLY` transaction —
though note `lab_rw` still has `INSERT`, so the transaction wrapper is what
actually prevents writes, not the role's grants.

## 6. Register with an MCP client

### Claude Code (personal, not committed to the repo)

```powershell
$env:PGDATABASE = "lab_test"   # or "lab" once you're happy with it
claude mcp add caraslabdb -- python -m caraslabdb_mcp.server
```

Run this from inside the activated `.venv`, or use the venv's absolute
`python.exe` path (e.g. `C:\src\CarasLabDB\mcp-server\.venv\Scripts\python.exe`)
if Claude Code is launched from a shell where the venv isn't active. This adds
the server to your personal Claude Code config — it does **not** create a
repo-tracked `.mcp.json`, so nothing changes for anyone else who clones the
repo.

To remove it: `claude mcp remove caraslabdb`.

### Any other MCP client

Point the client at the command `python -m caraslabdb_mcp.server` (or the
installed console script `caraslabdb-mcp`, per `pyproject.toml`'s
`[project.scripts]`) with the environment variables from §5 set in the
launching environment. Any stdio-transport MCP client works the same way —
there's nothing Claude-specific in the server itself.

## 7. Verify

1. Stand up `lab_test` per [testing-locally.md](testing-locally.md) §1 and
   seed a bit of data (either the manual steps there, or
   `examples/carasLabDB_demo.m` via MATLAB).
2. Smoke-test tools directly with the MCP Inspector before wiring up a full
   conversation:
   ```powershell
   npx @modelcontextprotocol/inspector python -m caraslabdb_mcp.server
   ```
3. Or register via `claude mcp add` (§6) and ask Claude things like "what
   sessions exist for subject X" or "show me the lineage of artifact Y".
4. Confirm the identifier allowlists hold: calling `get_artifact_lineage`
   with a `direction` outside `up`/`down` should raise a clear `ValueError`
   before any SQL runs, not a database error.
5. Confirm the read-only guarantee: there is no tool that performs an
   `INSERT`/`UPDATE`/`DELETE`, and even a hypothetical one would be rejected
   by `SET TRANSACTION READ ONLY` — you can sanity-check this directly with
   `psql`:
   ```sql
   BEGIN;
   SET TRANSACTION READ ONLY;
   INSERT INTO lab.person (full_name, email, role) VALUES ('x', 'y@z', 'PI');
   -- expect: ERROR: cannot execute INSERT in a read-only transaction
   ROLLBACK;
   ```

## 8. Extending the tool surface

When adding a new read tool:

- Put it in the module matching its subject (reference/dimensions/events/
  artifacts/provenance), or add a new module and register it in
  `server.py` if it's a new category.
- Table and column names come from a fixed string literal or
  `schema_map`-style dict in the tool's own code — **never** from a
  parameter value. Only pass caller-supplied values through as bound query
  parameters (via `db.select_from`'s `filters` or `db.fetch_all`'s `params`).
- Give every parameter a real column name and a type (`Optional[str]`,
  `bool`, `int`, ...) so the tool's schema stays a source of truth for field
  names, matching the "no generic SQL/JSON blob" rule in §2.
- If a tool must validate a small fixed vocabulary (like `direction` in
  `get_artifact_lineage`), validate with an explicit allowlist check and
  raise `ValueError` before the value reaches SQL — don't rely on the
  database to reject it.
- Any table this server reads should respect the same `*_active` /
  full-history toggle (`active_only: bool = True`) as `get_events` and
  `get_artifacts` if the table participates in the supersede pattern from
  [database-design.md](database-design.md).

Write tools (event/artifact inserts, supersede corrections) are explicitly
out of scope for this server as it exists today. If that changes, it should
be a new, clearly-separated phase — not a quiet addition to the read-only
tool modules — so the "this server cannot write" guarantee in §1 stays true
by construction, not just by convention.
