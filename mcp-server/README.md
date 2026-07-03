# CarasLabDB MCP server (read-only, v1)

A small Model Context Protocol (MCP) server that lets an LLM agent (e.g.
Claude Code/Desktop) query the CarasLabDB `lab` Postgres schema directly
during a conversation — "what recordings exist for subject G-0421", "walk
the lineage of this artifact", "list superseded husbandry events for this
animal" — without opening MATLAB or the dashboard.

**This is a read-only tool.** There is no insert/update/supersede surface;
every query runs inside a rolled-back `SET TRANSACTION READ ONLY` transaction
(same defense pattern as `@CarasLabDB/runReadOnlyQuery.m`), so nothing this
server does can ever write to the database. Write tools (event/artifact
inserts, supersede corrections) are an intentional future phase, not
included here.

It is a fourth, independent interface to the same `lab` schema, alongside
`@CarasLabDB/` (MATLAB class), `@CarasLabDBApp/` (MATLAB GUI), and `web/`
(dashboard). It shares no code with those — only the schema and the
env-var-driven connection convention already used by `web/live/server.py`.

## What's exposed

Read tools mirroring `@CarasLabDB`'s `get*` method surface:

- **Reference/lookup**: `get_species`, `get_storage_roots`, `get_probes`,
  `get_pipelines`, `get_event_types`, `get_artifact_roles`,
  `get_acquisition_systems`.
- **Dimensions**: `get_persons`, `get_projects`, `get_project_members`,
  `get_project_artifacts`, `get_subjects`, `get_sessions`,
  `get_subject_current`.
- **Events**: `get_events` (filterable by type/subject/session, toggles
  `event`/`event_active` via `active_only`), `get_event_detail` (joins a
  base event to its type-specific detail table).
- **Artifacts/provenance**: `get_artifacts`, `get_event_inputs`,
  `get_artifact_verifications`, `get_artifact_lineage` (wraps
  `lab.fn_artifact_lineage`), `get_provenance_edges`.

Every tool has named, typed parameters (no generic SQL/JSON blob) so the
tool's schema is a real source of field names for the calling LLM. No tool
accepts a table or column name as a free string.

## Install

```powershell
cd mcp-server
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e .
```

This installs the `mcp` SDK and `psycopg[binary]` (v3). If you'd rather use
`psycopg2` instead, install with the optional extra: `pip install -e .[psycopg2]`.

## Configure

Connection settings come from the standard libpq environment variables —
same as `web/live/server.py` and the MATLAB class:

| Variable | Default |
|---|---|
| `PGHOST` | local socket / localhost |
| `PGPORT` | 5432 |
| `PGDATABASE` | `lab` |
| `PGUSER` | OS user |
| `PGPASSWORD` | (or a `~/.pgpass` entry) |

For local testing against a scratch database, follow
[`design_docs/testing-locally.md`](../design_docs/testing-locally.md) §1 to
stand up `lab_test`, then set `PGDATABASE=lab_test` before registering the
server.

## Register with Claude Code (personal, not committed to the repo)

Register the server for your own Claude Code setup only — this does **not**
add a repo-tracked `.mcp.json`, so nothing changes for anyone else who
clones the repo:

```powershell
$env:PGDATABASE = "lab_test"   # or "lab" once you're happy with it
claude mcp add caraslabdb -- python -m caraslabdb_mcp.server
```

(Run this from inside the activated `.venv`, or use the venv's absolute
`python.exe` path in the command if Claude Code is launched from a shell
where the venv isn't active.)

To remove it: `claude mcp remove caraslabdb`.

## Verify

1. Stand up `lab_test` per `design_docs/testing-locally.md` §1 and seed a
   bit of data (either the manual steps there, or `examples/carasLabDB_demo.m`
   via MATLAB).
2. Smoke-test tools directly with the MCP Inspector before wiring up a full
   conversation:
   ```powershell
   npx @modelcontextprotocol/inspector python -m caraslabdb_mcp.server
   ```
3. Or register via `claude mcp add` (above) and ask Claude things like "what
   sessions exist for subject X" or "show me the lineage of artifact Y".
4. Confirm the identifier allowlists hold: calling `get_artifact_lineage`
   with a `direction` outside `up`/`down` should raise a clear error before
   any SQL runs, not a database error.
