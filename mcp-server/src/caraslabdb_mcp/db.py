"""Read-only Postgres access for the CarasLabDB MCP server.

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD / ~/.pgpass) -- the same
convention web/live/server.py uses. Read-only is enforced in layers: the
session's default transaction mode is set to read-only (on the server and in
the driver), every query additionally runs inside a rolled-back READ ONLY
transaction (mirroring @CarasLabDB/runReadOnlyQuery.m's defense pattern), and
the role the server connects as should itself hold only SELECT (see
design_docs/mcp-server.md §5). The first two are settings SQL text could set
back, which is why no tool takes SQL; the role is the layer nothing sent over
the connection can undo, so a role that can write is logged as a warning.

Results are always bounded and always ordered. An LLM asking an open
question ("list the artifacts") should not be able to pull a million rows
through the context window, a silently-clipped answer is worse than a clipped
one that says so -- hence the {row_count, limit, truncated, rows} envelope
every helper returns -- and "the first 200" must be the same 200 on every
call, hence an ORDER BY ending in a unique key on every query.

One connection is opened on first use and reused; each call still runs in
its own READ ONLY transaction that is rolled back afterwards. A connection
that has died is discarded and reopened once.

Timestamp *inputs* without a UTC offset (e.g. occurred_from='2026-09-01')
are read in the session time zone. libpq sets that from PGTZ when it is
set; otherwise it is the server's default. Timestamp outputs always carry
their offset.
"""

import base64
import datetime
import json
import logging
import os
import re
import threading
import uuid
from contextlib import contextmanager

from . import schema_map

log = logging.getLogger(__name__)

# Connecting to the wrong database is the failure mode that matters here:
# unset PGDATABASE used to fall through to production `lab` from deep inside
# the per-query path, invisibly. Resolve it once, at import, and say so.
DEFAULT_DATABASE = "lab"
if not os.environ.get("PGDATABASE"):
    os.environ["PGDATABASE"] = DEFAULT_DATABASE
    log.warning(
        "PGDATABASE is not set; defaulting to %r. Set PGDATABASE explicitly "
        "in the MCP client's server config (e.g. `claude mcp add caraslabdb "
        "-e PGDATABASE=lab_test -- ...`) to query a scratch database instead.",
        DEFAULT_DATABASE,
    )

# An unreachable PGHOST otherwise blocks the whole stdio server for the
# libpq default (minutes), with no way for the client to tell why.
CONNECT_TIMEOUT_S = 10

DEFAULT_LIMIT = 200
MAX_LIMIT = 1000

# The lab.schema_version this server's hard-coded table and column names
# (schema_map.py, the per-tool filters) were written against. A database at
# another version may return incomplete rows rather than an error, so a
# mismatch is logged and repeated in every result as `schema_warning`.
SCHEMA_VERSION = 1

# Inclusive lower / exclusive upper bound operators for `time_ranges`.
_RANGE_OPS = (">=", "<")

# Each ordering ends in a unique column (or unique column set) so it is
# total -- a bare `occurred_at DESC` leaves ties in an arbitrary order, and no
# ORDER BY at all lets one unrelated UPDATE reshuffle the page, which makes a
# LIMIT non-deterministic across calls.
ORDER_BY_EVENT = "occurred_at DESC, event_id"
ORDER_BY_ARTIFACT = "created_at DESC, artifact_id"
ORDER_BY_VERIFICATION = "verified_at DESC, verification_id DESC"
# assignment_id, not applied_at: it is the order lab.tag_current uses to
# decide which row of the log is the latest.
ORDER_BY_TAG_ASSIGNMENT = "assignment_id DESC"
ORDER_BY_TAG_CURRENT = "tag, assignment_id"
# value_id, oldest first: insertion order, which is also the order
# lab.variable_current uses to decide which row of the log is the latest.
ORDER_BY_VARIABLE_VALUE = "value_id"
# Unique: one current value per (entity, variable).
ORDER_BY_VARIABLE_CURRENT = "entity_kind, entity_id, variable"
ORDER_BY_RETRACTION = "retracted_at DESC, retraction_id DESC"
ORDER_BY_DISPOSITION = "disposition_id DESC"
ORDER_BY_DISPOSITION_LATEST = "artifact_id"
ORDER_BY_SUBJECT = "subject_id"
ORDER_BY_SESSION = "subject_id, label"
ORDER_BY_VERIFICATION_LATEST = "artifact_id"

# Every table or view `select_from` may read, with the ordering it gets when
# the caller passes none. `table` and `order_by` are interpolated as raw SQL
# text (only *values* are bound), so both are restricted to these fixed
# literals rather than left to the convention that call sites never pass
# anything caller-derived -- and because the allowlist *is* this map, a table
# cannot be made readable without also being given a deterministic order.
DEFAULT_ORDER_BY = {
    "lab.person": "full_name, person_id",
    "lab.storage_root": "root_id",
    "lab.species": "code",
    "lab.probe": "probe_id",
    "lab.pipeline": "name",
    "lab.event_type": "code",
    "lab.artifact_role": "code",
    "lab.acquisition_system": "code",
    "lab.project": "name",
    "lab.project_member": "project_id, person_id",
    "lab.project_artifact": "project_id, title, project_artifact_id",
    "lab.subject": ORDER_BY_SUBJECT,
    "lab.session": ORDER_BY_SESSION,
    "lab.subject_current": ORDER_BY_SUBJECT,
    "lab.event": ORDER_BY_EVENT,
    "lab.event_active": ORDER_BY_EVENT,
    "lab.event_version": ORDER_BY_EVENT,
    "lab.artifact": ORDER_BY_ARTIFACT,
    "lab.artifact_active": ORDER_BY_ARTIFACT,
    "lab.artifact_version": ORDER_BY_ARTIFACT,
    "lab.artifact_present": ORDER_BY_ARTIFACT,
    "lab.event_input": "event_id, artifact_id",
    "lab.artifact_verification": ORDER_BY_VERIFICATION,
    "lab.artifact_verification_latest": ORDER_BY_VERIFICATION_LATEST,
    "lab.provenance_edge": "edge_type, from_id, to_id",
    "lab.tag_namespace": "namespace",
    "lab.tag": "tag",
    "lab.tag_assignment": ORDER_BY_TAG_ASSIGNMENT,
    "lab.tag_current": ORDER_BY_TAG_CURRENT,
    "lab.entity_tags": "entity_kind, entity_id",
    "lab.variable": "name",
    "lab.variable_value": ORDER_BY_VARIABLE_VALUE,
    "lab.variable_current": ORDER_BY_VARIABLE_CURRENT,
    "lab.retraction": ORDER_BY_RETRACTION,
    "lab.artifact_disposition": ORDER_BY_DISPOSITION,
    "lab.artifact_disposition_latest": ORDER_BY_DISPOSITION_LATEST,
}
DEFAULT_ORDER_BY.update({t: "event_id" for t in schema_map.EVENT_DETAIL_TABLE.values()})

ALLOWED_TABLES = frozenset(DEFAULT_ORDER_BY)
ALLOWED_ORDER_BY = frozenset(DEFAULT_ORDER_BY.values())

# The orderings a caller can page through with a `cursor`, as the ordered
# (column, descending, SQL type) keys of each. A cursor holds the last row's
# values of exactly these columns, and the next page is the keyset predicate
# "after that row in this order" -- so every column here must be NOT NULL in
# the tables that use the ordering, and the set must be unique (the ORDER BY
# is total), or a page boundary could skip or repeat rows. The SQL type is
# the cast applied to the bound cursor value; like the column, it is a fixed
# literal from this map.
PAGE_KEYS = {
    ORDER_BY_EVENT: (("occurred_at", True, "timestamptz"), ("event_id", False, "uuid")),
    ORDER_BY_ARTIFACT: (("created_at", True, "timestamptz"), ("artifact_id", False, "uuid")),
    ORDER_BY_VERIFICATION: (("verified_at", True, "timestamptz"),
                            ("verification_id", True, "bigint")),
    ORDER_BY_VERIFICATION_LATEST: (("artifact_id", False, "uuid"),),
    ORDER_BY_TAG_ASSIGNMENT: (("assignment_id", True, "bigint"),),
    ORDER_BY_DISPOSITION: (("disposition_id", True, "bigint"),),
    ORDER_BY_TAG_CURRENT: (("tag", False, "text"), ("assignment_id", False, "bigint")),
    ORDER_BY_SUBJECT: (("subject_id", False, "text"),),
    ORDER_BY_SESSION: (("subject_id", False, "text"), ("label", False, "text")),
    ORDER_BY_VARIABLE_VALUE: (("value_id", False, "bigint"),),
    ORDER_BY_VARIABLE_CURRENT: (("entity_kind", False, "text"), ("entity_id", False, "text"),
                                ("variable", False, "text")),
}

# The clause that keeps only active (not superseded, not retracted) events or
# artifacts in a table that refers to them by id -- fixed text per kind.
ACTIVE_ENTITY_CLAUSE = {
    "event": "event_id IN (SELECT x.event_id FROM lab.event_active x)",
    "artifact": "artifact_id IN (SELECT x.artifact_id FROM lab.artifact_active x)",
}

# The taggable entity kinds and the primary-key column of the table each is
# stored in -- also the id column of lab.tag_assignment / lab.tag_current that
# holds the entity's id. The pk is interpolated as SQL text, so it comes from
# this fixed map and never from a caller.
TAG_PK = {
    "event": "event_id",
    "artifact": "artifact_id",
    "subject": "subject_id",
    "session": "session_id",
    "project": "project_id",
}
TAG_KINDS = tuple(TAG_PK)

_FILTER_KEY_RE = re.compile(r"^[a-z_][a-z0-9_]*$")


def tag_pk(kind):
    """The pk column for a taggable entity kind; ValueError for any other."""
    if kind not in TAG_PK:
        raise ValueError(
            f"Unknown entity kind {kind!r}; expected one of "
            f"{', '.join(TAG_KINDS)}.")
    return TAG_PK[kind]


def tag_array(tokens):
    """A tag-token list as a bound array value; empty or None means NULL.

    lab.fn_tag_match treats NULL and an empty array alike (no constraint), so
    both are sent as NULL. It also ignores a blank element, which would turn
    `tags=[""]` into "no filter" without saying so; that is rejected here.
    """
    if tokens is None:
        return None
    if isinstance(tokens, str):
        raise ValueError("Tag filters must be a list of strings, not a string.")
    tokens = [str(t) for t in tokens]
    if any(not t.strip() for t in tokens):
        raise ValueError(
            "Tag filters must not contain empty strings; leave the list out "
            "to apply no filter.")
    return tokens or None


def tag_tokens(*arrays):
    """Every token of a tag filter, whichever list it came from."""
    return [t for a in arrays if a for t in a]


def check_tag_filter(cur, kind, tokens):
    """Raise ValueError if a tag filter names something that cannot match.

    lab.fn_tag_match treats an unknown token as "no entity has it". That is
    right for matching and wrong for a caller: none_tags=["qc:fial"] excludes
    nothing and returns the failed recordings. lab.fn_tag_filter_problems
    reports each such token (a namespace that does not exist, one that does
    not apply to `kind`, a tag nobody registered) and this turns the report
    into an error, so a typo is never answered with a plausible result. Runs
    on the caller's cursor: the check and the query share one transaction.
    """
    tag_pk(kind)
    if not tokens:
        return
    cur.execute(
        "SELECT token, problem FROM lab.fn_tag_filter_problems(%s, %s::text[])",
        (kind, list(tokens)))
    problems = list(dict.fromkeys((token, problem) for token, problem in cur.fetchall()))
    if problems:
        raise ValueError(
            "Tag filter rejected (nothing was queried): "
            + "; ".join(f"{token!r}: {problem}" for token, problem in problems)
            + ". See get_tag_namespaces and get_tags for the vocabulary.")


def entity_id_value(kind, entity_id):
    """An entity id as the text lab.*_current views hold it, checked first.

    The uuid kinds are normalised to the canonical lower-case hyphenated form
    (entity_id in lab.tag_current / lab.variable_current is uuid::text), and
    a malformed uuid is a ValueError rather than a database cast error; a
    subject id is text and is returned exactly as given.
    """
    tag_pk(kind)
    if entity_id is None:
        return None
    if kind == "subject":
        return entity_id
    try:
        return str(uuid.UUID(str(entity_id).strip()))
    except ValueError:
        raise ValueError(f"{kind} ids are uuids; {entity_id!r} is not one.") from None


def _cursor_value(value):
    """One keyset value as JSON: exact, and castable back by PAGE_KEYS' type."""
    if isinstance(value, datetime.datetime):
        if value.tzinfo is None:
            raise ValueError("cannot page on a timestamp without a time zone")
        return value.isoformat()     # microseconds and offset kept: exact
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError(f"cannot page on a {type(value).__name__} value")
    return value


def encode_cursor(order_by, row):
    """The opaque cursor that continues after `row` in `order_by` order."""
    keys = PAGE_KEYS[order_by]
    payload = {"o": order_by, "k": [_cursor_value(row[col]) for col, _, _ in keys]}
    raw = json.dumps(payload, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(order_by, cursor):
    """The keyset values a cursor carries; ValueError for anything else.

    A cursor is only valid for the ordering it was issued for (so one from
    get_events cannot be replayed against get_artifacts), and must hold one
    scalar per key column. Its values are only ever bound as parameters.
    """
    if order_by not in PAGE_KEYS:
        raise ValueError("this listing cannot be paged with a cursor")
    bad = ValueError(
        "Invalid cursor: pass back the next_cursor of the previous page of the "
        "same tool, unchanged.")
    try:
        text = str(cursor).strip()
        raw = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
        payload = json.loads(raw)
    except (ValueError, TypeError):
        raise bad from None
    if not isinstance(payload, dict) or payload.get("o") != order_by:
        raise bad
    values = payload.get("k")
    if (not isinstance(values, list) or len(values) != len(PAGE_KEYS[order_by])
            or any(isinstance(v, bool) or not isinstance(v, (int, str)) for v in values)):
        raise bad
    return values


def keyset_clause(order_by, values):
    """The predicate "comes after `values` in `order_by` order", and its params.

    For keys (k1, k2, ...) it is (k1 > v1) OR (k1 = v1 AND k2 > v2) OR ...,
    with < for a descending key: a row comparison (k1, k2) > (v1, v2) would
    be shorter but cannot mix ascending and descending keys. Columns,
    directions and casts all come from PAGE_KEYS; only the values are bound.
    """
    keys = PAGE_KEYS[order_by]
    terms, params = [], []
    for i, (column, descending, cast) in enumerate(keys):
        parts = [f"{c} = %s::{t}" for c, _, t in keys[:i]]
        parts.append(f"{column} {'<' if descending else '>'} %s::{cast}")
        terms.append("(" + " AND ".join(parts) + ")")
        params.extend(values[:i + 1])
    return "(" + " OR ".join(terms) + ")", params


def like_prefix(prefix):
    r"""A LIKE pattern matching strings that start with `prefix`, literally.

    `%`, `_` and the escape character itself are escaped (ESCAPE '\'), so a
    path such as "G_0421/" matches that text and not "GX0421/".
    """
    escaped = prefix.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return escaped + "%"


def _driver():
    try:
        import psycopg as driver
    except ImportError as exc:
        try:
            import psycopg2 as driver
        except ImportError:
            # Chain the psycopg (v3) failure: a psycopg that imports but can't
            # find libpq raises ImportError too, and reporting only the
            # psycopg2 miss would send the reader down the wrong path.
            raise ImportError(
                "No usable Postgres driver: neither psycopg (v3) nor psycopg2 "
                "could be imported. Install with `pip install -e .` or "
                "`pip install -e .[psycopg2]`."
            ) from exc
    return driver


def _connect():
    return _driver().connect(connect_timeout=CONNECT_TIMEOUT_S)


def _make_session_read_only(conn):
    """Make read-only the default for every transaction of this session.

    Two settings, neither of which is the per-transaction statement below:

    - on the server, `default_transaction_read_only = on`, so a transaction
      started by any means on this session begins read-only. A SET is undone
      by ROLLBACK, so the transaction that holds it is committed; it is the
      one commit this module issues, and it contains nothing else.
    - in the driver, read_only, so that the BEGIN it sends is BEGIN READ ONLY.

    The per-transaction `SET TRANSACTION READ ONLY` only lands as the first
    statement of an implicit transaction because both drivers default to
    autocommit=False -- an assumption nothing used to check, so it is
    asserted here.

    All of these are settings, and SQL text can set them back (SET
    TRANSACTION READ WRITE before the first query, for one). They stop an
    accidental write, not SQL written to get around them, which is why no
    tool accepts SQL and why the SELECT-only role matters.
    """
    if getattr(conn, "autocommit", False):
        raise RuntimeError(
            "Connection opened with autocommit=True; the READ ONLY "
            "transaction wrapper would not apply."
        )
    cur = conn.cursor()
    cur.execute("SET default_transaction_read_only = on")
    conn.commit()
    if hasattr(conn, "read_only"):
        conn.read_only = True            # psycopg 3
    else:
        conn.set_session(readonly=True)  # psycopg2 spells it differently


_conn = None
_conn_lock = threading.Lock()
schema_warning = None
role_warning = None


def _check_schema_version(conn):
    """Read lab.schema_version once per connection; record any mismatch."""
    global schema_warning
    cur = conn.cursor()
    try:
        # The first pre-launch schema had no schema_version table; probe
        # rather than fail.
        cur.execute("SELECT to_regclass('lab.schema_version') IS NOT NULL")
        version = None
        if cur.fetchone()[0]:
            cur.execute("SELECT max(version) FROM lab.schema_version")
            version = cur.fetchone()[0]
    finally:
        conn.rollback()
    if version == SCHEMA_VERSION:
        schema_warning = None
        return
    found = ("unknown (no lab.schema_version table: a pre-launch prototype)"
             if version is None else str(version))
    schema_warning = (
        f"Database schema version is {found}; this MCP server is written for "
        f"version {SCHEMA_VERSION}. Rows may be missing columns. Upgrade the "
        f"database with design_docs/migrations/ or use a matching server."
    )
    log.warning(schema_warning)


def _check_role_cannot_write(conn):
    """Warn, once per connection, when the login could write to the event log.

    The read-only transaction still refuses the write, so this is not an
    error; but the role is the one layer no statement can switch off, and a
    server left on the OS user or on lab_rw is running without it.
    """
    global role_warning
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT current_user, coalesce(has_table_privilege("
            "current_user, to_regclass('lab.event')::oid, 'INSERT'), false)")
        user, can_write = cur.fetchone()
    finally:
        conn.rollback()
    if not can_write:
        role_warning = None
        return
    role_warning = (
        f"Connected as {user!r}, a role that can write to the lab schema. "
        f"Writes are still refused by the read-only transaction, but the "
        f"server is meant to run with a role that cannot write at all: set "
        f"PGUSER to a login that inherits lab_ro (design_docs/mcp-server.md §5)."
    )
    log.warning(role_warning)


def _discard_conn():
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except Exception:  # noqa: BLE001 -- closing a dead connection may raise
            log.debug("close failed on discard", exc_info=True)
    _conn = None


def _get_conn():
    """The shared connection, opened (read-only, version- and role-checked) on first use."""
    global _conn
    if _conn is not None and not _conn.closed:
        return _conn
    conn = _connect()
    try:
        _make_session_read_only(conn)
        _check_schema_version(conn)
        _check_role_cannot_write(conn)
    except Exception:
        conn.close()
        raise
    _conn = conn
    return conn


def _begin_read_only(conn):
    cur = conn.cursor()
    # Must be the first statement of the transaction to take effect.
    cur.execute("SET TRANSACTION READ ONLY")
    # A runaway lineage walk or an unindexed scan must not hang the stdio
    # server; kill the query, and the idle transaction if the client dies.
    cur.execute("SET LOCAL statement_timeout = '30s'")
    cur.execute("SET LOCAL idle_in_transaction_session_timeout = '60s'")
    return cur


@contextmanager
def read_only_cursor():
    """A cursor inside a READ ONLY transaction that is always rolled back.

    Queries made through one cursor share one transaction, and so one
    snapshot. Calls are serialized on the shared connection.
    """
    with _conn_lock:
        conn = _get_conn()
        try:
            cur = _begin_read_only(conn)
        except _driver().OperationalError:
            # The reused connection died while idle (server restart, dropped
            # socket). That is not the caller's error: reconnect once.
            log.info("shared connection lost; reconnecting", exc_info=True)
            _discard_conn()
            conn = _get_conn()
            cur = _begin_read_only(conn)
        try:
            yield cur
        finally:
            try:
                conn.rollback()
            except Exception:  # noqa: BLE001 -- a dead connection is replaced
                # A dead backend (statement_timeout kill, dropped socket) makes
                # rollback raise. Drop the connection so the next call opens a
                # fresh one instead of failing on this one.
                log.debug("rollback failed; discarding connection", exc_info=True)
                _discard_conn()


def rows(cur):
    """The current result of `cur` as a list of column->value dicts."""
    columns = [d[0] for d in cur.description]
    return [dict(zip(columns, row)) for row in cur.fetchall()]


def _effective_limit(limit):
    """Resolve a caller's `limit` to a bounded, always-present row cap."""
    if limit is None:
        return DEFAULT_LIMIT
    limit = int(limit)
    if limit < 0:
        raise ValueError(f"limit must be >= 0, got {limit}.")
    # 0 used to mean "no limit"; it now means "use the default" so an LLM
    # carrying the old convention gets a bounded answer, not an unbounded one.
    if limit == 0:
        return DEFAULT_LIMIT
    return min(limit, MAX_LIMIT)


def _envelope(rows, limit, page_order=None, extra=None):
    """Wrap rows with the truncation flag callers need to see.

    The flags come *before* the rows: a client that caps a long tool result
    cuts it at the end, and what it cuts must not be the one field that says
    the answer is incomplete.

    `page_order` is the ordering of a pageable listing (a PAGE_KEYS key): the
    envelope then carries `next_cursor`, the cursor that continues after the
    last row returned when the result was truncated, and None when it was
    not. `extra` is a dict of further keys, placed before the rows too.
    """
    truncated = len(rows) > limit
    result = {
        "row_count": min(len(rows), limit),
        "limit": limit,
        # True means the database had more matching rows than were returned;
        # narrow the filters, raise `limit` (up to MAX_LIMIT) or, where the
        # tool takes one, pass next_cursor back as `cursor` to see them.
        "truncated": truncated,
    }
    if page_order is not None:
        result["next_cursor"] = (
            encode_cursor(page_order, rows[limit - 1]) if truncated and limit else None)
    if schema_warning:
        result["schema_warning"] = schema_warning
    result.update(extra or {})
    result["rows"] = rows[:limit]
    return result


def fetch_all(sql, params=()):
    """Run a SELECT and return rows as a list of column->value dicts.

    Unbounded: callers that expose a result to a tool should use
    `fetch_limited` or `select_from` instead.
    """
    with read_only_cursor() as cur:
        cur.execute(sql, tuple(params))
        return rows(cur)


def run_limited(cur, sql, params=(), limit=DEFAULT_LIMIT, tag_check=None,
                page_order=None, extra=None):
    """`fetch_limited` on a cursor the caller already holds (one transaction)."""
    limit = _effective_limit(limit)
    if tag_check is not None:
        check_tag_filter(cur, *tag_check)
    cur.execute(f"{sql} LIMIT %s", tuple(params) + (limit + 1,))
    return _envelope(rows(cur), limit, page_order=page_order, extra=extra)


def fetch_limited(sql, params=(), limit=DEFAULT_LIMIT, tag_check=None,
                  page_order=None, extra=None):
    """Run a SELECT with a LIMIT appended, returning an `_envelope` dict.

    `sql` must not already carry its own LIMIT clause, and must carry an
    ORDER BY that is total. One extra row is fetched beyond the limit purely
    to detect truncation; it is dropped before returning.

    `tag_check` is a (kind, tokens) pair for a query that filters by tags:
    the tokens are validated with `check_tag_filter` in the same transaction,
    before the query runs. `page_order` makes the envelope carry
    `next_cursor` (see `_envelope`); the SQL must then be ordered by exactly
    that PAGE_KEYS ordering, and must apply `keyset_clause` itself when the
    caller passed a cursor.
    """
    limit = _effective_limit(limit)
    with read_only_cursor() as cur:
        return run_limited(cur, sql, params, limit, tag_check=tag_check,
                           page_order=page_order, extra=extra)


def select_from(table, filters, limit=DEFAULT_LIMIT, order_by=None,
                ci_filters=None, time_ranges=None, tag_filters=None,
                prefix_filters=None, num_ranges=None, active_entities=None,
                paged=False, cursor=None, resolve=None):
    """SELECT * FROM <table> WHERE <filters ANDed> ORDER BY ... LIMIT n.

    `table` and the column names in `filters`, `ci_filters`, `time_ranges`,
    `prefix_filters` and `num_ranges` are interpolated as raw SQL text, so
    all are validated here (allowlist / identifier pattern) rather than
    trusted to come from fixed internal call sites. `order_by` likewise
    accepts only the literals in ALLOWED_ORDER_BY, and defaults to the
    table's entry in DEFAULT_ORDER_BY, so every query is ordered. Only
    *values* may originate from tool arguments, and those are always bound
    as query parameters.

    `filters` are equality tests; `ci_filters` are equality tests compared
    case-insensitively (lower(col) = lower(value)). `time_ranges` maps a
    column to a (lower, upper) pair of timestamptz bounds, lower inclusive
    and upper exclusive; either may be None. `num_ranges` maps a column to a
    (lower, upper) pair of numeric bounds, both inclusive, each bound as
    text cast to numeric (so it is compared exactly). `prefix_filters` maps a
    column to a prefix the value must start with, matched literally
    (`like_prefix`: LIKE wildcards in it are escaped).

    `tag_filters` is a (kind, all_of, any_of, none_of) tuple, `kind` one of
    TAG_KINDS and the rest lists of tag tokens (or None). It adds the one
    fixed clause `lab.fn_tag_match(%s, <pk>::text, %s::text[], %s::text[],
    %s::text[])`, where `<pk>` comes from TAG_PK and every other piece is a
    bound value; the clause is omitted when all three lists are empty. The
    table must have that kind's pk column. Token syntax and matching rules
    live in the database (lab.fn_tag_match), not here; the tokens are checked
    against the vocabulary first (`check_tag_filter`), and a token that
    cannot match raises ValueError instead of quietly matching nothing.

    `active_entities` is "event" or "artifact" (or None): it adds the fixed
    ACTIVE_ENTITY_CLAUSE for that kind, keeping only rows that refer to a
    current (not superseded, not retracted) event or artifact.

    `paged=True` makes the result pageable: the ordering must be in
    PAGE_KEYS, the envelope carries `next_cursor`, and `cursor` (a
    next_cursor from an earlier page) adds the keyset predicate that starts
    the page after it. A cursor on a listing that is not paged is an error.

    `resolve` is a callable run on the query's own cursor, inside the same
    read-only transaction, before the SQL is built; it returns a dict of
    further equality filters (e.g. a name canonicalised by a database
    function) or raises ValueError to refuse the query.

    A `None` filter value means "do not filter on this column" -- it is not
    an `IS NULL` test, and there is no way to ask for one through this
    helper. Returns an `_envelope` dict, not a bare list.
    """
    if table not in ALLOWED_TABLES:
        raise ValueError(f"Unknown table {table!r}.")
    if order_by is None:
        order_by = DEFAULT_ORDER_BY[table]
    elif order_by not in ALLOWED_ORDER_BY:
        raise ValueError(f"Unsupported order_by {order_by!r}.")
    if paged and order_by not in PAGE_KEYS:
        raise ValueError(f"Ordering {order_by!r} cannot be paged.")
    if cursor is not None and not paged:
        raise ValueError("This listing does not take a cursor.")
    if active_entities is not None and active_entities not in ACTIVE_ENTITY_CLAUSE:
        raise ValueError(f"Unknown active_entities kind {active_entities!r}.")
    after = decode_cursor(order_by, cursor) if cursor is not None else None
    page_order = order_by if paged else None

    def column_ok(column):
        if not _FILTER_KEY_RE.match(column):
            raise ValueError(f"Invalid filter column name {column!r}.")
        return column

    def build(all_filters):
        clauses, params = [], []
        tag_check = None
        for column, value in all_filters.items():
            column_ok(column)
            if value is None:
                continue
            clauses.append(f"{column} = %s")
            params.append(value)
        for column, value in (ci_filters or {}).items():
            column_ok(column)
            if value is None:
                continue
            clauses.append(f"lower({column}) = lower(%s)")
            params.append(value)
        for column, bounds in (time_ranges or {}).items():
            column_ok(column)
            for op, value in zip(_RANGE_OPS, bounds):
                if value is None:
                    continue
                clauses.append(f"{column} {op} %s::timestamptz")
                params.append(value)
        for column, bounds in (num_ranges or {}).items():
            column_ok(column)
            for op, value in zip((">=", "<="), bounds):
                if value is None:
                    continue
                clauses.append(f"{column} {op} %s::numeric")
                params.append(value)
        for column, prefix in (prefix_filters or {}).items():
            column_ok(column)
            if prefix is None:
                continue
            clauses.append(f"{column} LIKE %s ESCAPE '\\'")
            params.append(like_prefix(prefix))
        if active_entities is not None:
            clauses.append(ACTIVE_ENTITY_CLAUSE[active_entities])
        if tag_filters is not None:
            kind, all_of, any_of, none_of = tag_filters
            pk = tag_pk(kind)
            arrays = [tag_array(all_of), tag_array(any_of), tag_array(none_of)]
            if any(a is not None for a in arrays):
                clauses.append(
                    f"lab.fn_tag_match(%s, {pk}::text, %s::text[], %s::text[], %s::text[])")
                params.extend([kind, *arrays])
                tag_check = (kind, tag_tokens(*arrays))
        if after is not None:
            clause, keyset_params = keyset_clause(order_by, after)
            clauses.append(clause)
            params.extend(keyset_params)
        sql = f"SELECT * FROM {table}"
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        sql += f" ORDER BY {order_by}"
        return sql, params, tag_check

    if resolve is None:
        sql, params, tag_check = build(filters)
        return fetch_limited(sql, params, limit, tag_check=tag_check, page_order=page_order)
    limit = _effective_limit(limit)
    with read_only_cursor() as cur:
        sql, params, tag_check = build({**filters, **resolve(cur)})
        return run_limited(cur, sql, params, limit, tag_check=tag_check,
                           page_order=page_order)
