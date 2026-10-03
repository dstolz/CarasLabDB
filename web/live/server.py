#!/usr/bin/env python3
"""Live backend for the Caras Lab metadata dashboard.

Serves the static dashboard page (web/live/lab-dashboard-live.html) and a
single JSON endpoint, ``/api/data``, that runs ``lab_data.sql`` against the
live Postgres database and returns the whole ``LAB_DATA`` payload the
dashboard expects. Everything the browser needs comes from the same origin,
so there are no CORS concerns.

The query runs at most once every CACHE_SECONDS (5 s): concurrent page loads
and refreshes within that window share one export, and the response is
gzip-compressed for clients that accept it. Only the page itself and
/api/data are served; any other path is a 404, so nothing else in this
directory (source files, or a stray .env / .pgpass) is ever published.
Database errors are logged to stderr and answered with a fixed message, so
host and user names in a driver error never reach the browser.

Database connection settings are taken from the standard libpq environment
variables:

    PGHOST      (default: local socket / localhost)
    PGPORT      (default: 5432)
    PGDATABASE  (default: lab)
    PGUSER      (default: OS user)
    PGPASSWORD  (or a ~/.pgpass entry)

Data access uses psycopg (v3) or psycopg2 if importable, otherwise it shells
out to ``psql`` (which reads the same PG* variables) -- so no Python package
install is strictly required as long as psql is on PATH.

Usage:
    # from the repo root, with the schema applied to database "lab":
    PGDATABASE=lab python web/live/server.py --port 8778
    # then open http://127.0.0.1:8778/
"""

import argparse
import gzip
import json
import os
import subprocess
import sys
import threading
import time
import traceback
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_PATH = os.path.join(HERE, "lab_data.sql")
PAGE = "/lab-dashboard-live.html"
CACHE_SECONDS = 5.0

# lab_data.sql renders timestamps in UTC; the session zone only affects the
# offsets inside per-event `detail` objects, but pinning it keeps the payload
# identical whichever zone the server or the login defaults to. It is set on
# the connection rather than in the SQL file, which keeps that file a single
# statement.
SESSION_TIME_ZONE = "UTC"


# --------------------------------------------------------------------------
# Data access -- three interchangeable backends, tried in order of niceness.
# --------------------------------------------------------------------------
def _load_sql():
    with open(SQL_PATH, "r", encoding="utf-8") as fh:
        return fh.read()


def _fetch_via_psycopg(sql):
    """psycopg v3 or v2, using libpq env vars for connection settings."""
    conn = None
    try:
        import psycopg  # noqa: F401  (psycopg 3)

        conn = psycopg.connect()
    except ImportError:
        import psycopg2  # psycopg 2

        conn = psycopg2.connect()
    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("SET TIME ZONE '%s'" % SESSION_TIME_ZONE)
            cur.execute(sql)
            value = cur.fetchone()[0]
        # A json/jsonb column comes back already parsed; a text column is a str.
        if isinstance(value, (dict, list)):
            return json.dumps(value)
        return value
    finally:
        conn.close()


def _fetch_via_psql(sql):
    """Fallback: pipe the query through the psql CLI (reads PG* env vars)."""
    env = dict(os.environ)
    env.setdefault("PGDATABASE", "lab")
    # libpq sets the session time zone from PGTZ; override any inherited value.
    env["PGTZ"] = SESSION_TIME_ZONE
    # -q keeps psql from echoing a command-status tag in front of the JSON.
    # The query text comes in on stdin so this backend and the psycopg one run
    # exactly the same SQL string.
    proc = subprocess.run(
        ["psql", "-tAXq", "-v", "ON_ERROR_STOP=1"],
        input=sql, capture_output=True, text=True, env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "psql failed")
    # Belt and braces: the payload is the single result tuple, so take the last
    # non-empty line rather than trusting stdout to hold nothing else.
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if not lines:
        raise RuntimeError("psql returned no rows")
    return lines[-1].strip()


def fetch_lab_data(sql):
    """Return the LAB_DATA payload as a JSON string, or raise on failure."""
    try:
        import psycopg  # noqa: F401
        return _fetch_via_psycopg(sql)
    except ImportError:
        pass
    try:
        import psycopg2  # noqa: F401
        return _fetch_via_psycopg(sql)
    except ImportError:
        pass
    return _fetch_via_psql(sql)


# --------------------------------------------------------------------------
# Short-lived payload cache, shared by all request threads.
# --------------------------------------------------------------------------
_cache_lock = threading.Lock()
_cache = {"at": None, "raw": None, "gz": None}


def cached_payload():
    """(raw bytes, gzip bytes) of the export, re-queried every CACHE_SECONDS.

    The lock is held across the query, so a burst of requests after expiry
    runs it once rather than once per request.
    """
    with _cache_lock:
        now = time.monotonic()
        if _cache["at"] is None or now - _cache["at"] >= CACHE_SECONDS:
            raw = fetch_lab_data(SQL).encode("utf-8")
            _cache.update(at=now, raw=raw, gz=gzip.compress(raw, compresslevel=6))
        return _cache["raw"], _cache["gz"]


# --------------------------------------------------------------------------
# HTTP handler: the page itself + the /api/data endpoint, nothing else.
# --------------------------------------------------------------------------
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=HERE, **kwargs)

    def _route(self):
        """Map the request path to PAGE or "/api/data"; None for anything else."""
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path in ("/", "", PAGE):
            return PAGE
        if path == "/api/data":
            return path
        return None

    def do_GET(self):
        route = self._route()
        if route == "/api/data":
            self.handle_api_data()
        elif route == PAGE:
            self.path = PAGE
            super().do_GET()
        else:
            self.send_error(404)

    def do_HEAD(self):
        if self._route() == PAGE:
            self.path = PAGE
            super().do_HEAD()
        else:
            self.send_error(404)

    def _send(self, status, body, extra_headers=()):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in extra_headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def handle_api_data(self):
        try:
            raw, gz = cached_payload()
        except Exception:  # DB down, bad creds, missing schema, ...
            # The driver's message can name the host, port and login; keep it
            # in the server log and send the browser a fixed message.
            sys.stderr.write("/api/data failed:\n" + traceback.format_exc())
            body = json.dumps({
                "error": "Could not read the database.",
                "detail": "Could not read the database. The dashboard server's "
                          "log has the cause.",
            }).encode("utf-8")
            self._send(503, body)
            return
        accepts = self.headers.get("Accept-Encoding", "")
        if "gzip" in [e.split(";")[0].strip().lower() for e in accepts.split(",")]:
            self._send(200, gz, [("Content-Encoding", "gzip"), ("Vary", "Accept-Encoding")])
        else:
            self._send(200, raw, [("Vary", "Accept-Encoding")])

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


SQL = _load_sql()


def main():
    ap = argparse.ArgumentParser(description="Live Caras Lab dashboard server.")
    ap.add_argument("--host", default="127.0.0.1", help="bind address (default 127.0.0.1)")
    ap.add_argument("--port", type=int, default=8778, help="HTTP port (default 8778)")
    ap.add_argument("--db", help="database name (overrides/sets PGDATABASE)")
    args = ap.parse_args()

    if args.db:
        os.environ["PGDATABASE"] = args.db
    os.environ.setdefault("PGDATABASE", "lab")

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    url = "http://%s:%d/" % (args.host, args.port)
    print("Caras Lab live dashboard serving at %s" % url)
    print("  database : %s" % os.environ.get("PGDATABASE"))
    print("  data API : %sapi/data" % url)
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
