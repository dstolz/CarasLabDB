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
the database.** That invariant is upheld in layers — no write tools and no
tool that takes SQL, read-only session and transaction settings, and a
`SELECT`-only role. They are not equally strong; §2 says what each one stops
and what it does not.

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

An agent's answer is only as good as what the tools tell it, so the tools are
built to fail loudly rather than answer plausibly: a truncated result says so
before its rows, a superseded row is never returned as if it were current, a
tag filter that cannot match is an error, and lineage follows corrections.

## 2. Architecture

```
mcp-server/
  pyproject.toml                    # deps: mcp, pydantic, psycopg[binary] (or psycopg2)
  src/caraslabdb_mcp/
    server.py                       # FastMCP app; registers all tool modules
    db.py                           # connection + READ ONLY transaction wrapper
    schema_map.py                   # fixed event_type -> detail table/columns map
    tools/
      __init__.py                   # OptText / OptNumber, the optional-filter parameter types
      reference.py                  # get_species, get_probes, get_pipelines, ...
      dimensions.py                 # get_persons, get_projects, get_subjects, ...
      events.py                     # get_events, get_event_detail, get_retractions
      artifacts.py                  # get_artifacts, get_event_inputs, ...
      provenance.py                 # get_artifact_lineage, get_provenance_edges
      tags.py                       # get_tag_namespaces, get_tags, get_entity_tags, find_by_tags
      variables.py                  # get_variable_definitions, get_variables, find_by_variable
      summary.py                    # get_counts (fixed aggregate questions)
      health.py                     # get_integrity_report
  tests/                            # pytest: unit (no DB) + integration
```

- **`server.py`** builds a `FastMCP("caraslabdb")` app and calls each tool
  module's `register(app)`, then runs over stdio. This is the process Claude
  Code/Desktop launches per the MCP stdio transport.
- **`db.py`** owns *all* SQL execution. `fetch_all(sql, params)` runs a
  parameterized query and returns rows as `column -> value` dicts.
  `fetch_limited(sql, params, limit, tag_check)` appends a `LIMIT`, returns
  the truncation envelope and, for a query that filters by tags, first
  validates the tokens in the same transaction (`check_tag_filter`).
  `read_only_cursor()` gives a tool several queries in one transaction, and
  `run_limited(cur, ...)` is `fetch_limited` on a cursor the tool already
  holds.
  `select_from(table, filters, limit, order_by, ci_filters, time_ranges,
  tag_filters, prefix_filters, num_ranges, active_entities, paged, cursor,
  resolve)` builds a `SELECT * FROM <table> WHERE <filters ANDed> ORDER BY
  <order>` for the common case (`ci_filters` compare case-insensitively;
  `time_ranges` maps a column to an inclusive lower and exclusive upper
  timestamptz bound; `tag_filters` is a `(kind, all_of, any_of, none_of)`
  tuple that adds the one fixed clause `lab.fn_tag_match(%s, <pk>::text,
  %s::text[], %s::text[], %s::text[])`, with `<pk>` taken from `db.TAG_PK`
  and omitted when all three lists are empty — see [tagging.md](tagging.md)
  for the tag syntax), where `filters` values that are `None` are dropped
  (i.e. "not filtering on this column", *not* an `IS NULL` test) and every
  non-`None` value is bound as a query parameter — never interpolated into
  SQL text. `prefix_filters` is a literal starts-with test (`col LIKE %s
  ESCAPE '\'`, with `%`, `_` and `\` in the bound prefix escaped by
  `db.like_prefix`); `num_ranges` are inclusive numeric bounds bound as text
  cast to `numeric`; `active_entities` (`"event"` / `"artifact"`) adds the
  fixed `db.ACTIVE_ENTITY_CLAUSE` that keeps rows referring to a current
  event or artifact; `paged`/`cursor` add keyset paging (§2, Bounded,
  ordered results); `resolve(cur)` runs on the query's own cursor before the
  SQL is built and returns further equality filters (how `get_variables`
  canonicalises a variable name with the database function in the same
  transaction). `table`, `order_by`, and the column names in `filters`,
  `ci_filters`, `time_ranges`, `prefix_filters` and `num_ranges` *are*
  interpolated as SQL text, so `db.py`
  validates them itself: `table` against `ALLOWED_TABLES`, `order_by` against
  `ALLOWED_ORDER_BY`, column names against `^[a-z_][a-z0-9_]*$`. That is a
  check, not a convention — a call site can't skip it. Both allowlists are
  derived from one map, `DEFAULT_ORDER_BY` (table → its default ordering), so
  a table cannot be made readable without being given a deterministic order.
- **`schema_map.py`** hardcodes the 9 event types to their detail
  table/columns (built by hand from `schema.sql`, not introspected at
  runtime). This is the one place `get_event_detail` needs a table name that
  depends on data read from the database (the event's `event_type` string);
  looking it up in this fixed dict means a caller can never smuggle an
  arbitrary table name in via that column's value. An integration test
  compares it with the catalog.
- **`tools/*.py`** each define a handful of `@app.tool()`-decorated functions
  with typed, named parameters (`OptText`, `bool`, `int`, ...). There is
  **no generic SQL/JSON-blob tool** — every filter parameter name is a real
  schema column, so the tool signatures double as documentation for the
  calling LLM.

### The read-only guarantee

Every query goes through `db.read_only_cursor()`. Four things stand between a
tool call and a write. They are listed strongest first, because they are not
interchangeable:

1. **No tool writes, and no tool takes SQL.** Every statement the server
   sends is fixed text in the source with the caller's values bound as
   parameters. Layers 3 and 4 below are *settings*, and a setting can be
   changed by SQL — but only by SQL the server gives a caller no way to send.
2. **The role.** Connect as a login that inherits `lab_ro` (§5), which holds
   `SELECT` and nothing else. A write is then refused on privilege grounds,
   and this is the one layer that nothing sent over the connection can switch
   off. Each time it opens a connection `db.py` asks whether its role could
   `INSERT` into `lab.event`; if so it logs a warning to stderr
   (`db.role_warning`) telling the operator to use a login that inherits
   `lab_ro`. The server keeps working — the layers below still refuse the
   write — but it is running without its backstop.
3. **The session default.** On connect `db.py` runs
   `SET default_transaction_read_only = on`, so that every transaction this
   session starts, by any means, begins read-only, and sets the driver's
   read-only flag (`conn.read_only = True` in psycopg 3,
   `conn.set_session(readonly=True)` in psycopg2) so that the `BEGIN` the
   driver sends is `BEGIN READ ONLY`. A `SET` is undone by `ROLLBACK`, so the
   transaction holding that one statement is committed; it is the only
   commit the server ever issues, and it contains nothing else.
4. **The transaction.** `SET TRANSACTION READ ONLY` is issued as the first
   statement of each transaction, before the tool's query, and the
   transaction is rolled back afterwards regardless of outcome.

What 3 and 4 do **not** do is survive hostile SQL: both set the same
PostgreSQL property, and `SET TRANSACTION READ WRITE` before a transaction's
first query (or `SET default_transaction_read_only = off`) sets it back. They
stop an accidental write from a future bug; they would not stop a tool that
executed caller-written SQL, which is why there is none and why the role is
not optional. (In earlier versions of this server the driver flag was the
whole of layer 3. It is not a server-side session default: a statement that
committed and began its own transaction got a writable one.)

Layer 4 only lands as the first statement of an implicit transaction
*because* both drivers default to `autocommit=False`; `db.py` asserts that
(raising `RuntimeError` if `conn.autocommit` is true). This mirrors the
defense pattern in `@CarasLabDB/runReadOnlyQuery.m`.

The integration tests exercise each layer through the server's own
connection: writes and `lab.fn_tag` refused by the transaction, the session
default reported `on` and holding across a `COMMIT; BEGIN`, and — as a
temporary login that inherits `lab_ro` — a write refused by the role after
the transaction has deliberately been switched back to read-write.

The same wrapper also bounds how long a query may hold the server: the
connection is opened with `connect_timeout=10` (an unreachable `PGHOST` would
otherwise block the stdio server for the libpq default of minutes), and each
transaction sets `statement_timeout = '30s'` and
`idle_in_transaction_session_timeout = '60s'`. Tools are synchronous, so a
slow query holds the whole stdio server for up to those 30 seconds.

One connection is opened on first use and reused for every call, behind a
lock; each call is still its own READ ONLY transaction, rolled back at the
end. A rollback that raises (a dead backend or a dropped socket) discards the
connection, and a connection found dead at the start of a call is replaced
once, so a server restart costs the caller nothing. `get_event_detail` makes
its queries through one cursor, so they see the same snapshot. On each new
connection `db.py` reads `lab.schema_version`; if it is not the version the
server was written for (`db.SCHEMA_VERSION`, currently 1), it logs a warning
and every result carries a `schema_warning` string — list envelopes before
their rows, and `get_event_detail`'s row as its first key.

A time-range bound without a UTC offset (e.g. `occurred_from="2026-09-01"`)
is read in the session time zone, which libpq takes from `PGTZ` when set and
otherwise from the server default.

### Bounded, ordered results

No tool returns an unbounded result set. `select_from`/`fetch_limited`
always apply a `LIMIT` (`db.DEFAULT_LIMIT` = 200, capped at `db.MAX_LIMIT` =
1000), fetch one row beyond it to detect truncation, and return an envelope:

```python
{"row_count": 12, "limit": 200, "truncated": False, "rows": [...]}
```

The flags come **before** the rows (and `schema_warning`, when there is one,
between them). A page of 200 artifact rows is on the order of 100 KiB of
JSON, and 1000 rows several times that; an MCP client that caps a long tool
result cuts it at the end, and the part it cuts must not be the field that
says the answer is incomplete.

Every list tool takes `limit: int = 200` and returns that envelope — with
`next_cursor` after `truncated` on the pageable tools, and `question` on
`get_counts` (only
`get_event_detail`, which is single-row by construction, returns a bare dict;
it selects on a primary key). A negative `limit` raises `ValueError`;
`limit=0` — which used to mean "no limit" — is now treated as the default, so
an LLM carrying the old convention gets a bounded answer rather than the
whole table.

Every query also carries an `ORDER BY` that ends in a unique key, so that
"the first 200" is the same 200 on every call rather than whatever the
planner returns (without one, a single unrelated `UPDATE` reshuffles the
page). `select_from` takes the order from `db.DEFAULT_ORDER_BY` unless the
tool passes one of the same literals: events newest-first by `occurred_at`,
artifacts by `created_at`, verifications by `verified_at`, each with a
unique-column tiebreaker; the tag log by `assignment_id` (the order
`lab.tag_current` uses to decide which row is the latest); every other table
by its primary or unique key (`subject_id`; `subject_id, label` for
sessions; `event_id, artifact_id` for consumption edges; `edge_type, from_id,
to_id` for provenance edges; and so on). The lineage walk is ordered by
`depth, event_id, artifact_id`, and the integrity report by severity, check,
subject and detail.

The `truncated` flag exists because the alternative — an LLM reading a
silently clipped result as the complete answer and telling a researcher
"there are 200 recordings for this subject" — is a wrong answer, not a slow
one.

**Paging.** The listings that grow without bound — `get_events`,
`get_artifacts`, `get_subjects`, `get_sessions`, `get_entity_tags` (current
tags and the assignment log), `get_variables`, `find_by_variable` and
`get_artifact_verifications` — take an opaque `cursor` and return
`next_cursor`: the cursor that continues after the last row of a truncated
page, `null` when nothing is left. Calling again with the same arguments and
`cursor=<next_cursor>` returns the next page; `limit` still caps each page
at 1000. The cursor is keyset, not offset: it holds the last row's values of
the ordering's columns (`db.PAGE_KEYS`, which spells out each pageable
`ORDER BY` as `(column, descending, cast)` keys — a unit test checks that it
matches the ordering column for column), and the next page is the predicate
`(k1 > v1) OR (k1 = v1 AND k2 > v2) ...` (`<` for a descending key; a row
comparison cannot mix directions). So a page boundary neither skips nor
repeats a row when rows are added between calls, ties on `occurred_at` are
broken by `event_id`, and timestamps in the cursor keep their microseconds
and offset. A cursor is tied to the ordering that issued it (one from
`get_events` is refused by `get_artifacts`) and must hold one scalar per key;
anything else is `Invalid cursor`. Its values are only ever bound as
parameters, cast with the fixed type from `PAGE_KEYS`, so a forged cursor can
at worst fail a cast. Every key column is `NOT NULL` in the base tables that
use it (an integration test checks the catalog), since a NULL would make the
predicate skip rows.

**Counting.** Listing cannot answer "how many", so `get_counts` (§3) runs
fixed aggregate SQL for an allowlisted set of questions and returns exact
counts however many rows they cover.

### Where SQL has dynamic structure

The only places a *tool* builds SQL with any dynamic structure (not just
bound parameter values) are:

- `events.get_event_detail`, which looks up the detail table name in
  `schema_map.EVENT_DETAIL_TABLE` — a fixed dict, not the raw `event_type`
  string.
- `provenance.get_artifact_lineage`, which validates `direction` is exactly
  `"up"` or `"down"` (raising `ValueError` otherwise) before passing it, as a
  bound value like `follow_corrections`, to `lab.fn_artifact_lineage(...)`.
- `tags.get_entity_tags`, which uses the entity's id column name as a filter
  key. `db.tag_pk(entity_kind)` takes it from the fixed `db.TAG_PK` map and
  raises `ValueError` for any kind outside event / artifact / subject /
  session / project, so the caller's string never becomes an identifier. (The
  tag filters on the list tools and `find_by_tags` use fixed templates with
  every value bound.)
- `events.get_events` / `artifacts.get_artifacts`, which choose between two
  fixed view names (`*_active` or `*_version`) on the `active_only` boolean,
  and `variables.get_variables`, which chooses `lab.variable_current` or
  `lab.variable_value` on `current_only` and the id column from `db.TAG_PK`.
- `summary.get_counts`, whose `question` selects one of six SQL builders in
  `summary.QUESTIONS` (an unknown question is a `ValueError`); each builder's
  SQL is a literal, with `lab.event_active` / `lab.event` (and the artifact
  pair) chosen on the `active_only` boolean. A unit test feeds every builder
  hostile strings and checks that none reaches the SQL text.
- The keyset predicate of a paged listing (`db.keyset_clause`), whose
  columns, directions and casts come from `db.PAGE_KEYS`; only the cursor's
  values are bound.

Every other tool parameter flows into `select_from`'s `filters` dict as a
bound value, never as SQL text — and the structural parts `select_from` does
interpolate (`table`, `order_by`, filter keys) are allowlist-checked inside
`db.py`, as described above.

## 3. Tool surface

All tools return the `{"row_count", "limit", "truncated", "rows"}` envelope
from §2 except `get_event_detail`, which returns a single `dict`. Every
optional parameter that's left out (or sent as JSON `null`) is simply
excluded from the `WHERE` clause, matching `@CarasLabDB`'s pattern of
omitting unset Name=Value args from a query — note this means "don't filter",
never "where this column IS NULL"; there is no way to ask for the latter
through these tools. Every list tool also takes `limit: int = 200`.

| Module | Tools |
|---|---|
| `reference.py` | `get_species`, `get_storage_roots`, `get_probes`, `get_pipelines`, `get_event_types`, `get_artifact_roles`, `get_acquisition_systems` |
| `dimensions.py` | `get_persons`, `get_projects`, `get_project_members`, `get_project_artifacts`, `get_subjects`, `get_sessions`, `get_subject_current` |
| `events.py` | `get_events` (filter by `event_type`/`subject_id`/`session_id`/`supersedes`, by `occurred_from` (inclusive) / `occurred_before` (exclusive), and by `tags`/`any_tags`/`none_tags`; `active_only` chooses `event_active` or, for full history, `event_version`; pageable), `get_event_detail` (joins the event to its type-specific detail table; always carries `is_current` / `superseded_by` / `is_retracted` and the retraction's reason; refuses a superseded or retracted event unless `active_only=False`), `get_retractions(entity_kind, event_id, artifact_id)` (`lab.retraction`, newest first) |
| `artifacts.py` | `get_artifacts` (filters incl. `checksum`, `supersedes`, the file lookup `storage_root_id` / `relative_path` / `relative_path_prefix` / `format`, a `created_from` / `created_before` range and `tags`/`any_tags`/`none_tags`; `active_only` chooses `artifact_active` or `artifact_version`, `present_only` `artifact_present`; pageable), `get_event_inputs` (rows as recorded), `get_artifact_verifications` (the log, or with `latest_per_file=True` the latest check of each artifact's file from `lab.artifact_verification_latest`; pageable), `get_artifact_dispositions` (what became of files: the log, or with `latest_per_file=True` each file's state from `lab.artifact_disposition_latest`; pageable) |
| `provenance.py` | `get_artifact_lineage` (wraps `lab.fn_artifact_lineage`, `direction="up"\|"down"`, `follow_corrections=True`), `get_provenance_edges` (rows as recorded) |
| `tags.py` | `get_tag_namespaces` (namespaces and their policy flags, `applies_to` as a JSON list), `get_tags(namespace, include_retired)` (the vocabulary), `get_entity_tags(entity_kind, entity_id, include_history)` (current tags from `lab.tag_current` ordered by tag, or with `include_history` the full assignment log, latest first by `assignment_id`; pageable), `find_by_tags(entity_kind, all_of, any_of, none_of, active_only)` (wraps `lab.fn_find_by_tags`; returns `entity_id` rows) |
| `variables.py` | `get_variable_definitions(entity_kind, include_retired)` (`lab.variable`), `get_variables(entity_kind, entity_id, name, current_only, active_only)` (current values from `lab.variable_current`, or with `current_only=False` the `lab.variable_value` log oldest first; pageable), `find_by_variable(entity_kind, name, equals, at_least, at_most, text_equals, active_only)` (entities by current value; pageable) |
| `summary.py` | `get_counts(question, subject_id, project_id, entity_kind, active_only)` — exact counts: `events_by_type`, `artifacts_by_role` (with `total_size_bytes`), `subjects_by_project_species`, `sessions_per_subject`, `current_tags_by_tag`, `current_variables_by_variable` |
| `health.py` | `get_integrity_report` (wraps `lab.fn_check_integrity()`, all 15 checks described in the docstring — an integration test compares the list with the function; errors first; empty means healthy) |

### Corrections: current rows, history, and lineage

`active_only` defaults to `True` everywhere it appears, so queries read the
`*_active` views (rows neither superseded nor retracted) by default — same
default as `@CarasLabDB`'s `UseActiveViews`.

With `active_only=False`, `get_events` and `get_artifacts` read
`lab.event_version` / `lab.artifact_version` rather than the base tables, so
every row of the history carries `is_current`, `superseded_by` (the id of
the correction that replaced it) and `is_retracted`. A superseded or
retracted row can then not be mistaken for a current one, and the `supersedes` filter finds the correction of a
given row directly (`get_events(supersedes=X, active_only=False)`).
`get_event_detail` reads `lab.event_version` in both modes: by default it
refuses a superseded event with an error that names the event which
superseded it, and a retracted one with an error that says so and quotes the
reason; with `active_only=False` it returns the row as recorded, marked
`is_current: false`, with `retraction_reason` / `retracted_at` /
`retracted_by` filled in for a retracted event.

**Retraction** (`lab.retraction`) withdraws an event or
artifact that should never have been written, with a reason; nothing
replaces it. The `*_active` views leave retracted rows out, so every default
read does too (`get_events`, `get_artifacts`, `find_by_tags`, the
across-entity reads of `get_variables` / `find_by_variable`, `get_counts`).
`get_retractions` lists the retractions themselves. A "down" lineage walk
that follows corrections skips retracted consumers and products; an "up" walk
still returns a retracted ancestor (it is what the file was made from), and
`get_integrity_report` flags it as `input_retracted`.

`get_artifact_lineage` follows corrections by default
(`follow_corrections=True`, passed to `lab.fn_artifact_lineage`): the walk is
over current rows whichever version the caller names, and every id it returns
is a current one. Provenance edges are immutable, so after a correction they
still name the superseded rows; walking them as recorded says nothing was
derived from the current row of a corrected artifact. `follow_corrections=False`
gives that as-recorded walk for audit.

Two tools have **no** correction handling and say so in their docstrings:
`get_event_inputs` and `get_provenance_edges` read the edges exactly as
written, superseded rows included. An edge of a superseded event stays next
to the one re-declared on its correction, and an edge may point at an
artifact row that has since been corrected, so looking up a current row's id
there can return nothing. Use `get_artifact_lineage` for questions about what
derives from what.

Verification is by file, not by row: a correction gives the same file a new
artifact row, so the verification log filtered by the current row's id can be
empty although the file was checked.
`get_artifact_verifications(latest_per_file=True)` reads
`lab.artifact_verification_latest`, which takes the latest check across every
row describing the same file.

### Filters

`get_projects`, `get_subjects`, `get_sessions`, `get_events` and `get_artifacts`
also take `tags` (must have all), `any_tags` (at least one) and `none_tags`
(none of), each an optional list of tag strings. A tag is `namespace:value`;
a bare tag means `tag:<x>`; `namespace:*` matches any current tag in that
namespace; unset or empty lists are not applied. Only *current* tags count
(`lab.tag_current`), and the matching rules live in the database
(`lab.fn_tag_match`), so this server only binds the tokens. The full tag
syntax and policy flags are described in [tagging.md](tagging.md).

A tag filter is **validated before it is run**. `lab.fn_tag_match` treats an
unknown token as "no entity has it", which makes a typo silent:
`none_tags=["qc:fial"]` excludes nothing and returns the failed recordings.
So each query that filters by tags (the five list tools and `find_by_tags`)
first calls `lab.fn_tag_filter_problems(kind, tokens)` once, in the same
transaction, and raises a `ValueError` naming every faulty token and what is
wrong with it: a namespace that does not exist, a namespace that does not
apply to that kind of entity, or a tag that is not registered. An empty or
blank token is rejected too (the database would ignore it, turning the filter
into no filter).

Text filters are exact, case included (`subject_id="g-0421"` does not find
`G-0421`; ids are never folded). Two filters are normalised because the
database normalises the column: `get_persons` compares `email`
case-insensitively (`lower(email) = lower(%s)`), matching the schema's
`uq_person_email_lower` index, and `get_artifacts` strips and lower-cases
`checksum`, which the schema stores lower-case (hashing tools do not all
print it so).

Optional text parameters are annotated `OptText` (`tools/__init__.py`), not
`Optional[str]`. FastMCP JSON-decodes a string argument whenever the
parameter is not annotated exactly `str`, which turned the *text* `"null"`
into `None` and silently dropped the filter. `OptText` is `str` with a
validator that lets a real JSON `null` through and a JSON schema that still
says "string or null", so `"null"`, `"true"`, `"123"` are matched as the
strings they are, while `null` and omission both mean "no filter". An
integration test pins this against the installed FastMCP.

Number filters (`find_by_variable`'s `equals` / `at_least` / `at_most`) are
annotated `OptNumber`, also `str`-based: a JSON number or a numeric string,
turned into decimal text (a float by its shortest round-tripping `repr`, so
`0.1` is `"0.1"`) and cast to `numeric` in SQL, so `1200.5` matches a stored
`1200.50` exactly. `"null"`, `"NaN"`, `"inf"` and other non-numbers are
refused, never dropped.

### File lookup

`get_artifacts` answers "which artifact is this file?": `storage_root_id`
plus `relative_path` identify a file (`lab.artifact` keeps paths relative to
the storage root, forward slashes). `relative_path` and
`relative_path_prefix` are normalised as the schema's
`lab.fn_normalize_path` normalises a path on insert — backslashes to `/`,
surrounding whitespace trimmed — so a Windows path can be passed as is once
the storage root's own part (drive, share) is removed. The prefix is matched
literally: `LIKE` wildcards in it are escaped, so `G_0421/` does not match
`GX0421/`. A blank path or prefix is an error (a blank prefix would match
every file). `format` is matched exactly.

### User-defined variables

The schema has variables: named values on events, artifacts,
subjects, sessions and projects (`lab.variable` the definitions,
`lab.variable_value` the append-only log of `set` / `unset`,
`lab.variable_current` the latest `set` per entity and variable).
`get_variable_definitions` lists the definitions; `get_variables` reads the
current values of one entity, of one variable across entities, or both, or
with `current_only=False` the whole log oldest first; `find_by_variable`
finds entities by a current number (`equals`, inclusive `at_least` /
`at_most`) or text (`text_equals`). Names are canonicalised by
`lab.fn_canonical_variable` in the query's own transaction (`'Probe  Depth'`
= `'probe depth'`), and a name that is not defined, or does not apply to the
entity kind, is an error listing the defined variables — never an empty
result. A filter of the wrong kind for the variable's `value_type` is an
error too. `value_num` is `numeric` and comes back as an exact decimal
string. Across entities, `active_only` skips values on superseded or
retracted events and artifacts (a correction carries its predecessor's
values forward, so they would otherwise count twice); a named `entity_id` is
always read as named.

### Persons and logins

`get_persons` returns `lab.person` with `SELECT *`, which includes
`db_login`, the PostgreSQL login a person connects with —
what the `*_login` audit columns record. It is a role name, not a
credential; the docstring says so.

### Known limits

- `find_by_tags` and the lineage walk are bounded but not pageable; the
  reference tables, provenance edges and the integrity report are bounded
  and not pageable either (narrow the filters, or count with `get_counts`).
- Typed columns are exact (`numeric` is returned as a string, `timestamptz`
  with its offset and microseconds), but numbers inside `jsonb` values pass
  through a Python float.
- A timestamp outside Python's range (`'infinity'`, years past 9999) makes
  the call that returns it fail with a driver error rather than a wrong
  value; correct the row.
- Date bounds should be ISO-8601. PostgreSQL also accepts forms such as
  `01/09/2026` (read month-first) and `yesterday`; the tools do not reject
  them.
- `lab.row_history`, `lab.maintenance_log` and `lab.schema_version` are not
  exposed, so a subject rename or an in-place edit of a mutable table is not
  visible to the agent.

## 4. Install

```powershell
cd mcp-server
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e .
```

This installs the `mcp` SDK (1.30 or later, below 2), `pydantic` and
`psycopg[binary]` (v3). To use `psycopg2` instead: `pip install -e .[psycopg2]`
(`db.py` tries `psycopg` first, falls back to `psycopg2` on `ImportError`).

`mcp-server/.venv/` is git-ignored — the environment above is local to your
machine, not something committed to the repo.

## 5. Configure

Connection settings come from the standard libpq environment variables — the
same convention as `web/live/server.py`. (The MATLAB class does not read
them; it takes its connection settings as arguments.)

| Variable | Default |
|---|---|
| `PGHOST` | local socket / localhost |
| `PGPORT` | 5432 |
| `PGDATABASE` | `lab` — resolved once at import in `db.py`, with a warning logged to stderr if it was unset |
| `PGUSER` | OS user — set it to the read-only login below |
| `PGPASSWORD` | (or a `~/.pgpass` entry) |
| `PGTZ` | server default; set it (e.g. `America/New_York`) so a time-range bound without a UTC offset means midnight in the lab's zone |

There is no other server config — no config file, no port to open, no
network listener. The server speaks MCP over **stdio**; the client process
(Claude Code/Desktop) launches it as a subprocess and communicates over its
stdin/stdout.

The `PGDATABASE` fallback is deliberately noisy because its failure mode is
silent otherwise: an unset variable means the server queries the **production
`lab` database** while the operator may believe otherwise. Always set it
explicitly in the MCP client's server config (§6), not in the shell you run
the registration command from.

### Use a read-only login

Give the server a login that cannot write. Of the layers in §2 it is the one
that does not depend on what SQL is sent, so the read-only session and
transaction settings are a backstop rather than the only thing standing
between a bug and the database.

[`grants.sql`](grants.sql) creates `lab_ro` as a group role (`NOLOGIN`) and
gives it `SELECT` on every table and view, including tables added later
(default privileges). Apply it, then create a dedicated login that inherits
it. On the Windows 11 deployment machine, in PowerShell (if `psql` is not on
`PATH`, use its full path, e.g. `& "C:\Program Files\PostgreSQL\16\bin\psql.exe"`):

```powershell
psql -U postgres -d lab_test -v ON_ERROR_STOP=1 -f design_docs\grants.sql
psql -U postgres -d lab_test -c "CREATE ROLE lab_mcp LOGIN PASSWORD 'choose-one' IN ROLE lab_ro;"
```

On Linux or macOS the same commands work with `/` in the path (add
`sudo -u postgres` where the local login is by peer authentication).

Never make `lab_ro` itself a login (`CREATE ROLE lab_ro LOGIN ...` or
`ALTER ROLE lab_ro LOGIN`): it is the group every read-only service shares,
and once `grants.sql` has run it exists, so the `CREATE` fails anyway. A
login per service, inheriting the group, is what shows up in
`pg_stat_activity` and in the `*_login` audit columns. Point `PGUSER` at
`lab_mcp` and do the same on the production `lab` database. Roles are
cluster-wide, so the login is created once; `grants.sql` is per database.

Do **not** use `lab_rw`, a login that inherits it, or your own superuser
login: they hold `INSERT`. The server notices — on each new connection it
checks whether its role could insert into `lab.event` and logs

```
Connected as '<role>', a role that can write to the lab schema. ...
```

to stderr — but it does not refuse to start, so read the log once after
registering it.

For local testing against a scratch database, follow
[testing-locally.md](testing-locally.md) §1 to stand up `lab_test`, apply
`grants.sql` and create `lab_mcp` as above, and pass `PGDATABASE=lab_test` to
the server in §6.

## 6. Register with an MCP client

### Claude Code (personal, not committed to the repo)

```powershell
claude mcp add caraslabdb -e PGDATABASE=lab_test -e PGUSER=lab_mcp -- python -m caraslabdb_mcp.server
```

Environment variables must be passed with `-e`, which stores them in the
server's registration and applies them when Claude Code spawns the
subprocess. Setting `$env:PGDATABASE` in the shell you run `claude mcp add`
from does **not** reach that subprocess — a server registered that way silently
connects to production `lab`, which is exactly the mistake §5's warning is
there to catch. Switch to `-e PGDATABASE=lab` once you're happy with it. Keep
the password in `%APPDATA%\postgresql\pgpass.conf` on Windows (`~/.pgpass`
elsewhere) rather than in the registration.

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

   -- as lab_mcp, with no READ ONLY at all: the privilege layer
   INSERT INTO lab.person (full_name, email, role) VALUES ('x', 'y@z', 'PI');
   -- expect: ERROR: permission denied for table person
   ```
   and that the server's stderr carries no "role that can write" warning.
6. Confirm results are bounded: call `get_events` with no filters against a
   database holding more than 200 events and check the response starts with
   `"truncated": true` rather than holding the whole table. `limit=-1` should
   raise a `ValueError`.
7. Confirm a mistyped tag is refused: `get_artifacts(none_tags=["qc:fial"])`
   should raise an error naming `qc:fial`, not return rows; likewise
   `get_variables(entity_kind="session", name="no such variable")` should
   raise an error listing the defined variables.
8. Confirm paging and counting: `get_events(limit=5)` on a database with more
   than five events returns a `next_cursor`; passing it back as `cursor`
   returns the next five, and `get_counts(question="events_by_type")` gives
   the exact totals.

The automated equivalents are in `mcp-server/tests/`
(`python -m pytest tests`, with `CARASLABDB_TEST_DB` naming a scratch
database for the integration tests — `$env:CARASLABDB_TEST_DB = "lab_test"`
in PowerShell; see `mcp-server/README.md`).

## 8. Extending the tool surface

When adding a new read tool:

- Put it in the module matching its subject (reference/dimensions/events/
  artifacts/provenance/tags), or add a new module and register it in
  `server.py` if it's a new category.
- A tag filter on a list tool is not a SQL fragment: pass
  `tag_filters=(kind, tags, any_tags, none_tags)` to `db.select_from`, which
  emits the one fixed template `lab.fn_tag_match(%s, <pk>::text, %s::text[],
  %s::text[], %s::text[])` with `<pk>` taken from `db.TAG_PK` (an unknown
  `kind` raises `ValueError`) and everything else bound, and validates the
  tokens first. There is no generic "extra WHERE clause" hook, and there must
  not be one: it would break the "only values are bound" guarantee that
  `tests/test_db_unit.py` asserts textually. A new taggable entity kind needs
  a `db.TAG_PK` entry. A tool that calls a tag function itself passes
  `tag_check=(kind, tokens)` to `db.fetch_limited`, as `find_by_tags` does.
- Table and column names come from a fixed string literal or
  `schema_map`-style dict in the tool's own code — **never** from a
  parameter value. Only pass caller-supplied values through as bound query
  parameters (via `db.select_from`'s `filters` or `db.fetch_limited`'s
  `params`). A new table or view also has to be added to
  `db.DEFAULT_ORDER_BY` with an ordering that ends in a unique key, or
  `select_from` will reject it; that entry is what puts it on the allowlist.
- Give the tool a `limit: int = db.DEFAULT_LIMIT` parameter and route it
  through `db.select_from` or `db.fetch_limited` — never `db.fetch_all`
  directly, which is unbounded — so it returns the truncation envelope like
  every other tool. SQL handed to `fetch_limited` must carry its own total
  `ORDER BY`.
- A listing that can grow without bound should be pageable: give it
  `cursor: OptText = None` and pass `paged=True, cursor=cursor` to
  `db.select_from`. Its ordering must be in `db.PAGE_KEYS`, spelled key for
  key, with every key column `NOT NULL`; add the entry (and extend the
  catalog test) for a new ordering.
- A count is a new entry in `summary.QUESTIONS`: a builder returning a
  literal SQL string and its bound parameters, plus the optional arguments it
  accepts. Never a caller-chosen column to group by.
- Give every filter parameter a real column name and a type so the tool's
  schema stays a source of truth for field names, matching the "no generic
  SQL/JSON blob" rule in §2. An optional text filter is `OptText = None`,
  never `Optional[str] = None`, and an optional number filter that must be
  exact is `OptNumber = None` (§3, Filters).
- If a tool must validate a small fixed vocabulary (like `direction` in
  `get_artifact_lineage`), validate with an explicit allowlist check and
  raise `ValueError` before the value reaches SQL — don't rely on the
  database to reject it.
- Any table this server reads that participates in the supersede pattern
  from [database-design.md](database-design.md) should respect the same
  toggle as `get_events` and `get_artifacts` (`active_only: bool = True`
  reading the `*_active` view, and the `*_version` view otherwise so history
  rows carry `is_current` / `superseded_by`) — or say in its docstring, in so
  many words, that it returns rows as recorded.
- Docstrings are the only documentation the calling LLM sees. State what a
  default hides, how the result is ordered, and how a filter is matched.

A schema change that touches a table or column this server names has to be
mirrored here: `schema_map.py` for the event-detail tables, the per-tool
filter signatures, `db.DEFAULT_ORDER_BY`, and `db.SCHEMA_VERSION` (plus the
tests that assert it).

Write tools (event/artifact inserts, supersede corrections) are explicitly
out of scope for this server as it exists today. If that changes, it should
be a new, clearly-separated phase — not a quiet addition to the read-only
tool modules — so the "this server cannot write" guarantee in §1 stays true
by construction, not just by convention.
