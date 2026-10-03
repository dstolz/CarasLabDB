"""Read-only Postgres access for the CarasLabDB MCP server.

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD / ~/.pgpass) -- the same
convention web/live/server.py uses. Read-only is enforced in layers: the
session is opened read-only, every query additionally runs inside a
rolled-back READ ONLY transaction (mirroring
@CarasLabDB/runReadOnlyQuery.m's defense pattern), and the role the server
connects as should itself hold only SELECT (see design_docs/mcp-server.md
§5). No single one of those is trusted on its own.

Results are always bounded. An LLM asking an open question ("list the
artifacts") should not be able to pull a million rows through the context
window, and a silently-clipped answer is worse than a clipped one that says
so -- hence the {rows, truncated, ...} envelope every helper returns.

One connection is opened on first use and reused; each call still runs in
its own READ ONLY transaction that is rolled back afterwards. A connection
that has died is discarded and reopened once.

Timestamp *inputs* without a UTC offset (e.g. occurred_from='2026-09-01')
are read in the session time zone. libpq sets that from PGTZ when it is
set; otherwise it is the server's default. Timestamp outputs always carry
their offset.
"""

import logging
import os
import re
import threading
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
# mismatch is logged and repeated in every list result as `schema_warning`.
SCHEMA_VERSION = 2

# `table` and `order_by` are interpolated as raw SQL text (only *values* are
# bound), so both are restricted to fixed literals rather than left to the
# convention that call sites never pass anything caller-derived.
ALLOWED_TABLES = frozenset({
    "lab.person", "lab.storage_root", "lab.species", "lab.probe",
    "lab.pipeline", "lab.event_type", "lab.artifact_role",
    "lab.acquisition_system", "lab.project", "lab.project_member",
    "lab.project_artifact", "lab.subject", "lab.session",
    "lab.event", "lab.event_active",
    "lab.artifact", "lab.artifact_active",
    "lab.event_input", "lab.artifact_verification",
    "lab.provenance_edge", "lab.subject_current",
}) | frozenset(schema_map.EVENT_DETAIL_TABLE.values())

# Inclusive lower / exclusive upper bound operators for `time_ranges`.
_RANGE_OPS = (">=", "<")

# Each entry ends in a unique column so the ordering is total -- a bare
# `occurred_at DESC` leaves ties in an arbitrary order, which makes a LIMIT
# non-deterministic across calls.
ORDER_BY_EVENT = "occurred_at DESC, event_id"
ORDER_BY_ARTIFACT = "created_at DESC, artifact_id"
ORDER_BY_VERIFICATION = "verified_at DESC, verification_id DESC"
ALLOWED_ORDER_BY = frozenset({
    ORDER_BY_EVENT, ORDER_BY_ARTIFACT, ORDER_BY_VERIFICATION,
})

_FILTER_KEY_RE = re.compile(r"^[a-z_][a-z0-9_]*$")


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
    """Mark the *session* read-only, not just the next transaction.

    The per-transaction `SET TRANSACTION READ ONLY` below only lands as the
    first statement of an implicit transaction because both drivers default
    to autocommit=False -- an assumption nothing used to check. A session-
    level default holds either way, so set that first and assert the
    autocommit assumption rather than depending on it silently.
    """
    if hasattr(conn, "read_only"):
        conn.read_only = True            # psycopg 3
    else:
        conn.set_session(readonly=True)  # psycopg2 spells it differently
    if getattr(conn, "autocommit", False):
        raise RuntimeError(
            "Connection opened with autocommit=True; the READ ONLY "
            "transaction wrapper would not apply."
        )


_conn = None
_conn_lock = threading.Lock()
schema_warning = None


def _check_schema_version(conn):
    """Read lab.schema_version once per connection; record any mismatch."""
    global schema_warning
    cur = conn.cursor()
    try:
        # Version 1 had no schema_version table; probe rather than fail.
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
    found = ("unknown (no lab.schema_version table, i.e. version 1)"
             if version is None else str(version))
    schema_warning = (
        f"Database schema version is {found}; this MCP server is written for "
        f"version {SCHEMA_VERSION}. Rows may be missing columns. Upgrade the "
        f"database with design_docs/migrations/ or use a matching server."
    )
    log.warning(schema_warning)


def _discard_conn():
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except Exception:  # noqa: BLE001 -- closing a dead connection may raise
            log.debug("close failed on discard", exc_info=True)
    _conn = None


def _get_conn():
    """The shared connection, opened (read-only, version-checked) on first use."""
    global _conn
    if _conn is not None and not _conn.closed:
        return _conn
    conn = _connect()
    try:
        _make_session_read_only(conn)
        _check_schema_version(conn)
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


def _envelope(rows, limit):
    """Wrap rows with the truncation flag callers need to see."""
    result = {
        "rows": rows[:limit],
        "row_count": min(len(rows), limit),
        "limit": limit,
        # True means the database had more matching rows than were returned;
        # narrow the filters or raise `limit` (up to MAX_LIMIT) to see them.
        "truncated": len(rows) > limit,
    }
    if schema_warning:
        result["schema_warning"] = schema_warning
    return result


def fetch_all(sql, params=()):
    """Run a SELECT and return rows as a list of column->value dicts.

    Unbounded: callers that expose a result to a tool should use
    `fetch_limited` or `select_from` instead.
    """
    with read_only_cursor() as cur:
        cur.execute(sql, tuple(params))
        return rows(cur)


def fetch_limited(sql, params=(), limit=DEFAULT_LIMIT):
    """Run a SELECT with a LIMIT appended, returning an `_envelope` dict.

    `sql` must not already carry its own LIMIT clause. One extra row is
    fetched beyond the limit purely to detect truncation; it is dropped
    before returning.
    """
    limit = _effective_limit(limit)
    rows = fetch_all(f"{sql} LIMIT %s", list(params) + [limit + 1])
    return _envelope(rows, limit)


def select_from(table, filters, limit=DEFAULT_LIMIT, order_by=None,
                ci_filters=None, time_ranges=None):
    """SELECT * FROM <table> WHERE <filters ANDed> [ORDER BY ...] LIMIT n.

    `table` and the column names in `filters`, `ci_filters` and
    `time_ranges` are interpolated as raw SQL text, so all are validated
    here (allowlist / identifier pattern) rather than trusted to come from
    fixed internal call sites. `order_by` likewise accepts only the literals
    in ALLOWED_ORDER_BY. Only *values* may originate from tool arguments,
    and those are always bound as query parameters.

    `filters` are equality tests; `ci_filters` are equality tests compared
    case-insensitively (lower(col) = lower(value)). `time_ranges` maps a
    column to a (lower, upper) pair of timestamptz bounds, lower inclusive
    and upper exclusive; either may be None.

    A `None` filter value means "do not filter on this column" -- it is not
    an `IS NULL` test, and there is no way to ask for one through this
    helper. Returns an `_envelope` dict, not a bare list.
    """
    if table not in ALLOWED_TABLES:
        raise ValueError(f"Unknown table {table!r}.")
    if order_by is not None and order_by not in ALLOWED_ORDER_BY:
        raise ValueError(f"Unsupported order_by {order_by!r}.")
    clauses, params = [], []

    def column_ok(column):
        if not _FILTER_KEY_RE.match(column):
            raise ValueError(f"Invalid filter column name {column!r}.")
        return column

    for column, value in filters.items():
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
    sql = f"SELECT * FROM {table}"
    if clauses:
        sql += " WHERE " + " AND ".join(clauses)
    if order_by:
        sql += f" ORDER BY {order_by}"
    return fetch_limited(sql, params, limit)
