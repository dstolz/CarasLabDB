"""Read-only Postgres access for the CarasLabDB MCP server.

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD / ~/.pgpass) -- the same
convention web/live/server.py uses. Every query runs inside a rolled-back
READ ONLY transaction, mirroring @CarasLabDB/runReadOnlyQuery.m's defense
pattern, so this module can never commit a write even if a query builder
has a bug.
"""

import os
from contextlib import contextmanager


def _connect():
    try:
        import psycopg
        return psycopg.connect()
    except ImportError:
        import psycopg2
        return psycopg2.connect()


@contextmanager
def _read_only_cursor():
    os.environ.setdefault("PGDATABASE", "lab")
    conn = _connect()
    try:
        cur = conn.cursor()
        # Must be the first statement of the transaction to take effect.
        cur.execute("SET TRANSACTION READ ONLY")
        yield cur
    finally:
        conn.rollback()
        conn.close()


def fetch_all(sql, params=()):
    """Run a SELECT and return rows as a list of column->value dicts."""
    with _read_only_cursor() as cur:
        cur.execute(sql, tuple(params))
        columns = [d[0] for d in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]


def select_from(table, filters, limit=0, order_by=None):
    """SELECT * FROM <table> WHERE <filters ANDed> [ORDER BY ...] [LIMIT n].

    `table` and the keys of `filters` must always come from fixed internal
    call sites, never from a caller-supplied string. Only the *values* in
    `filters` may originate from tool arguments, and those are always bound
    as parameterized query params -- never interpolated into the SQL text.
    A `limit` of 0 means "no limit" (matches @CarasLabDB's pSelectFrom).
    """
    clauses, params = [], []
    for column, value in filters.items():
        if value is None:
            continue
        clauses.append(f"{column} = %s")
        params.append(value)
    sql = f"SELECT * FROM {table}"
    if clauses:
        sql += " WHERE " + " AND ".join(clauses)
    if order_by:
        sql += f" ORDER BY {order_by}"
    if limit:
        sql += " LIMIT %s"
        params.append(limit)
    return fetch_all(sql, params)
