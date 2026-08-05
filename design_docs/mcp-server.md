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
without breaking its one hard invariant: **it must not be able to write to
the database.** That invariant is upheld by three independent layers (no
write tools, a read-only session/transaction, and a `SELECT`-only role), each
of which is assumed to be fallible on its own — see §2.

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
  `fetch_limited(sql, params, limit)` wraps it with a `LIMIT` and a
  truncation flag. `select_from(table, filters, limit, order_by)` builds a
  `SELECT * FROM <table> WHERE <filters ANDed>` for the common case, where
  `filters` values that are `None` are dropped (i.e. "not filtering on this
  column", *not* an `IS NULL` test) and every non-`None` value is bound as a
  query parameter — never interpolated into SQL text. `table`, `order_by`,
  and the keys of `filters` *are* interpolated as SQL text, so `db.py`
  validates them itself: `table` against `ALLOWED_TABLES`, `order_by` against
  `ALLOWED_ORDER_BY`, filter keys against `^[a-z_][a-z0-9_]*$`. That is a
  check, not a convention — a call site can't skip it.
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

Every query goes through `db._read_only_cursor()`, which stacks three
independent defenses so that no one of them has to be right:

1. **The role.** Connect as `lab_ro` (§5), which holds `SELECT` and nothing
   else. A write is then rejected on privilege grounds before any of the
   below matters.
2. **The session.** `conn.read_only = True` (psycopg 3) /
   `conn.set_session(readonly=True)` (psycopg2) makes read-only the
   session default, which holds regardless of transaction bookkeeping.
3. **The transaction.** `SET TRANSACTION READ ONLY` is still issued as the
   first statement of each transaction, before any tool-supplied SQL, and
   the connection is rolled back and closed afterward regardless of outcome.

Layer 3 alone was the original design, but it only lands as the first
statement of an implicit transaction *because* both drivers default to
`autocommit=False` — an assumption that used to be unwritten and unchecked.
`db.py` now asserts it (raising `RuntimeError` if `conn.autocommit` is true)
in addition to setting layer 2, which does not depend on it. Together with
"there are no write tools in the first place", the result is that a bug in
any single layer does not produce a write. This mirrors the defense pattern
in `@CarasLabDB/runReadOnlyQuery.m`.

The same wrapper also bounds how long a query may hold the server: the
connection is opened with `connect_timeout=10` (an unreachable `PGHOST` would
otherwise block the stdio server for the libpq default of minutes), and each
transaction sets `statement_timeout = '30s'` and
`idle_in_transaction_session_timeout = '60s'`. Teardown rolls back inside its
own `try`, with `close()` in a nested `finally` — a rollback that raises
against a dead backend must not be able to skip the close, since the server
opens a connection per query and would otherwise leak one file descriptor per
failure against a flapping database.

### Bounded results

No tool returns an unbounded result set. `select_from`/`fetch_limited`
always apply a `LIMIT` (`db.DEFAULT_LIMIT` = 200, capped at `db.MAX_LIMIT` =
1000), fetch one row beyond it to detect truncation, and return an envelope:

```python
{"rows": [...], "row_count": 12, "limit": 200, "truncated": False}
```

Every list tool takes `limit: int = 200` and returns that envelope (only
`get_event_detail`, which is single-row by construction, returns a bare dict
— it is also the only caller left on the unbounded `fetch_all`, and only
because it selects on a primary key). A negative `limit` raises
`ValueError`; `limit=0` — which used to mean
"no limit" — is now treated as the default, so an LLM carrying the old
convention gets a bounded answer rather than the whole table. Tools whose
tables grow without bound also pass a deterministic `ORDER BY` (events by
`occurred_at DESC`, artifacts by `created_at DESC`, verifications by
`verified_at DESC`, each with a unique-column tiebreaker) so that "the first
200" is a stable, meaningful set rather than whatever the planner returns.

The `truncated` flag exists because the alternative — an LLM reading a
silently clipped result as the complete answer and telling a researcher
"there are 200 recordings for this subject" — is a wrong answer, not a slow
one.

The only two places a *tool* builds SQL with any dynamic structure (not just
bound parameter values) are:

- `events.get_event_detail`, which looks up the detail table name in
  `schema_map.EVENT_DETAIL_TABLE` — a fixed dict, not the raw `event_type`
  string.
- `provenance.get_artifact_lineage`, which validates `direction` is exactly
  `"up"` or `"down"` (raising `ValueError` otherwise) before passing it to
  `lab.fn_artifact_lineage(...)`.

Every other tool parameter flows into `select_from`'s `filters` dict as a
bound value, never as SQL text — and the structural parts `select_from` does
interpolate (`table`, `order_by`, filter keys) are allowlist-checked inside
`db.py`, as described above.

## 3. Tool surface

All tools return the `{"rows", "row_count", "limit", "truncated"}` envelope
from §2 except `get_event_detail`, which returns a single `dict`. Every
optional parameter that's left as `None`/default is simply excluded from the
`WHERE` clause, matching `@CarasLabDB`'s pattern of omitting unset Name=Value
args from a query — note this means `None` is "don't filter", never "where
this column IS NULL"; there is no way to ask for the latter through these
tools. Every list tool also takes `limit: int = 200`.

| Module | Tools |
|---|---|
| `reference.py` | `get_species`, `get_storage_roots`, `get_probes`, `get_pipelines`, `get_event_types`, `get_artifact_roles`, `get_acquisition_systems` |
| `dimensions.py` | `get_persons`, `get_projects`, `get_project_members`, `get_project_artifacts`, `get_subjects`, `get_sessions`, `get_subject_current` |
| `events.py` | `get_events` (filter by `event_type`/`subject_id`/`session_id`, `active_only` toggles `event_active` vs. `event`), `get_event_detail` (joins base event to its type-specific detail table; `active_only` toggles the same way) |
| `artifacts.py` | `get_artifacts` (`active_only` toggles `artifact_active` vs. `artifact`), `get_event_inputs`, `get_artifact_verifications` |
| `provenance.py` | `get_artifact_lineage` (wraps `lab.fn_artifact_lineage`, `direction="up"\|"down"`), `get_provenance_edges` |

`active_only` defaults to `True` everywhere it appears, so queries read the
`*_active` views (non-superseded rows) by default — same default as
`@CarasLabDB`'s `UseActiveViews`. Pass `active_only=False` to see full
correction history, including superseded rows.

Two tools have **no** `active_only` toggle and always walk full history:
`get_provenance_edges` and `get_artifact_lineage`. That is inherent, not an
oversight — `lab.provenance_edge` and `lab.fn_artifact_lineage` are defined
over the raw `lab.artifact` / `lab.event_input` tables, and filtering a
superseded artifact out of a lineage chain would break the chain that runs
through it. Their docstrings say so; cross-check an id against
`get_artifacts` if you need to know whether a row in a lineage is current.

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
| `PGDATABASE` | `lab` — resolved once at import in `db.py`, with a warning logged to stderr if it was unset |
| `PGUSER` | OS user |
| `PGPASSWORD` | (or a `~/.pgpass` entry) |

There is no other server config — no config file, no port to open, no
network listener. The server speaks MCP over **stdio**; the client process
(Claude Code/Desktop) launches it as a subprocess and communicates over its
stdin/stdout.

The `PGDATABASE` fallback is deliberately noisy because its failure mode is
silent otherwise: an unset variable means the server queries the **production
`lab` database** while the operator may believe otherwise. Always set it
explicitly in the MCP client's server config (§6), not in the shell you run
the registration command from.

### Use a read-only role

Give the server a role that cannot write, so the read-only session and
transaction wrapper in §2 are a backstop rather than the only thing standing
between a bug and the database:

```powershell
psql -U postgres -d lab_test -c "CREATE ROLE lab_ro LOGIN PASSWORD 'ro-pw';"
psql -U postgres -d lab_test -c "GRANT USAGE ON SCHEMA lab TO lab_ro;"
psql -U postgres -d lab_test -c "GRANT SELECT ON ALL TABLES IN SCHEMA lab TO lab_ro;"
```

(`GRANT SELECT ON ALL TABLES` covers views too. Re-run it, or add
`ALTER DEFAULT PRIVILEGES IN SCHEMA lab GRANT SELECT ON TABLES TO lab_ro;`,
after adding tables to the schema.) Point `PGUSER` at `lab_ro` and do the
same on the production `lab` database.

Do **not** reuse the `lab_rw` role from [testing-locally.md](testing-locally.md)
§1 here: it holds `INSERT`, so an `INSERT` that somehow escaped the
transaction wrapper would succeed. `lab_ro` makes that escape harmless, which
is the whole point of having more than one layer.

For local testing against a scratch database, follow
[testing-locally.md](testing-locally.md) §1 to stand up `lab_test`, create
`lab_ro` in it as above, and pass `PGDATABASE=lab_test` to the server in §6.

## 6. Register with an MCP client

### Claude Code (personal, not committed to the repo)

```powershell
claude mcp add caraslabdb -e PGDATABASE=lab_test -e PGUSER=lab_ro -- python -m caraslabdb_mcp.server
```

Environment variables must be passed with `-e`, which stores them in the
server's registration and applies them when Claude Code spawns the
subprocess. Setting `$env:PGDATABASE` in the shell you run `claude mcp add`
from does **not** reach that subprocess — a server registered that way silently
connects to production `lab`, which is exactly the mistake §5's warning is
there to catch. Switch to `-e PGDATABASE=lab` once you're happy with it.

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
5. Confirm the read-only layers independently. There is no tool that performs
   an `INSERT`/`UPDATE`/`DELETE`, but check that a hypothetical one would be
   stopped twice over — once by the transaction wrapper and once by the role:
   ```sql
   -- as any role: the transaction layer
   BEGIN;
   SET TRANSACTION READ ONLY;
   INSERT INTO lab.person (full_name, email, role) VALUES ('x', 'y@z', 'PI');
   -- expect: ERROR: cannot execute INSERT in a read-only transaction
   ROLLBACK;

   -- as lab_ro, with no READ ONLY at all: the privilege layer
   INSERT INTO lab.person (full_name, email, role) VALUES ('x', 'y@z', 'PI');
   -- expect: ERROR: permission denied for table person
   ```
6. Confirm results are bounded: call `get_events` with no filters against a
   database holding more than 200 events and check the response comes back
   with `truncated: true` rather than the whole table. `limit=-1` should
   raise a `ValueError`.

## 8. Extending the tool surface

When adding a new read tool:

- Put it in the module matching its subject (reference/dimensions/events/
  artifacts/provenance), or add a new module and register it in
  `server.py` if it's a new category.
- Table and column names come from a fixed string literal or
  `schema_map`-style dict in the tool's own code — **never** from a
  parameter value. Only pass caller-supplied values through as bound query
  parameters (via `db.select_from`'s `filters` or `db.fetch_all`'s `params`).
  A new table also has to be added to `db.ALLOWED_TABLES`, and a new sort
  order to `db.ALLOWED_ORDER_BY`, or `select_from` will reject it.
- Give the tool a `limit: int = db.DEFAULT_LIMIT` parameter and route it
  through `db.select_from` or `db.fetch_limited` — never `db.fetch_all`
  directly, which is unbounded — so it returns the truncation envelope like
  every other tool. If the table can grow without bound, give it a
  deterministic `ORDER BY` too.
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
