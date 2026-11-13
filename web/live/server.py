#!/usr/bin/env python3
"""Live backend for the Caras Lab metadata dashboard.

Serves the static dashboard page (web/live/lab-dashboard-live.html) and a
single JSON endpoint, ``/api/data``, that runs ``lab_data.sql`` against the
live Postgres database and returns the whole ``LAB_DATA`` payload the
dashboard expects. Everything the browser needs comes from the same origin,
so there are no CORS concerns.

A finished export is reused for CACHE_SECONDS (5 s), counted from the moment
it finished, so page loads and refreshes inside that window share it however
long the query took. Requests that arrive while an export is running wait for
that one instead of starting their own. The export runs in a READ ONLY
transaction that is rolled back, with a connect timeout and a statement
timeout; a request never waits longer than those two together, and an export
that still has not returned by then is abandoned so that the next request
starts a fresh one rather than queueing behind it for ever. The response is
gzip-compressed for clients that accept it.

Only the page itself and /api/data are served; any other path is a 404, so
nothing else in this directory (source files, or a stray .env / .pgpass) is
ever published. Database errors are logged to stderr and answered with a
fixed message, so host and user names in a driver error never reach the
browser.

There is no authentication. Run it bound to 127.0.0.1 (the default) behind a
reverse proxy that provides HTTPS and login, as a database login that
inherits ``lab_ro`` (see README.md).

Database connection settings are taken from the standard libpq environment
variables:

    PGHOST      (default: local socket / localhost)
    PGPORT      (default: 5432)
    PGDATABASE  (default: lab)
    PGUSER      (default: OS user)
    PGPASSWORD  (or a ~/.pgpass entry)
    PGCONNECT_TIMEOUT                   (default: 10 s)
    LAB_DASHBOARD_STATEMENT_TIMEOUT     (seconds, default: 120)

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
# After a failed export, answer from the failure for this long instead of
# making every queued request wait out its own connect timeout.
ERROR_RETRY_SECONDS = 2.0
CONNECT_TIMEOUT = 10        # seconds; PGCONNECT_TIMEOUT overrides
STATEMENT_TIMEOUT = 120     # seconds; LAB_DASHBOARD_STATEMENT_TIMEOUT overrides

# lab_data.sql renders timestamps in UTC; the session zone only affects the
# offsets inside per-event `detail` objects, but pinning it keeps the payload
# identical whichever zone the server or the login defaults to. It is set on
# the connection rather than in the SQL file, which keeps that file a single
# statement.
SESSION_TIME_ZONE = "UTC"


def _env_seconds(name, default):
    """A positive number of seconds from the environment, else the default."""
    try:
        value = float(os.environ.get(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


def connect_timeout():
    return max(1, int(_env_seconds("PGCONNECT_TIMEOUT", CONNECT_TIMEOUT)))


def statement_timeout():
    return _env_seconds("LAB_DASHBOARD_STATEMENT_TIMEOUT", STATEMENT_TIMEOUT)


def export_deadline():
    """The longest a request waits for an export, and the age at which a
    still-running export is given up on: both timeouts plus a margin for
    compressing and handing over a large payload."""
    return connect_timeout() + statement_timeout() + 15.0


# --------------------------------------------------------------------------
# Data access -- three interchangeable backends, tried in order of niceness.
# Each runs the export in one READ ONLY transaction that is rolled back.
# --------------------------------------------------------------------------
def _load_sql():
    with open(SQL_PATH, "r", encoding="utf-8") as fh:
        return fh.read()


def _fetch_via_psycopg(sql):
    """psycopg v3 or v2, using libpq env vars for connection settings."""
    conn = None
    is_v3 = True
    try:
        import psycopg  # noqa: F401  (psycopg 3)

        conn = psycopg.connect(connect_timeout=connect_timeout())
    except ImportError:
        import psycopg2  # psycopg 2

        is_v3 = False
        conn = psycopg2.connect(connect_timeout=connect_timeout())
    try:
        # Take the json column as the text Postgres sent. Parsing 100 MB into
        # Python objects only to serialise it again doubles the export time,
        # and the round trip rewrites numbers (75.00 -> 75.0).
        try:
            if is_v3:
                from psycopg.types.json import set_json_loads

                set_json_loads(lambda data: data, conn)
            else:
                from psycopg2.extras import register_default_json

                register_default_json(conn_or_curs=conn, loads=lambda data: data)
        except Exception:  # an older driver: fall back to parse + dump below
            pass
        conn.autocommit = False
        with conn.cursor() as cur:
            # The driver opens the transaction with the first statement, and
            # READ ONLY has to be set before any query runs in it.
            cur.execute("SET TRANSACTION READ ONLY")
            cur.execute("SET LOCAL statement_timeout = %d" % int(statement_timeout() * 1000))
            cur.execute("SET LOCAL TIME ZONE '%s'" % SESSION_TIME_ZONE)
            cur.execute(sql)
            value = cur.fetchone()[0]
        if isinstance(value, (dict, list)):
            return json.dumps(value)
        if isinstance(value, (bytes, bytearray, memoryview)):
            return bytes(value).decode("utf-8")
        return value
    finally:
        try:
            conn.rollback()
        except Exception:
            pass
        conn.close()


def _fetch_via_psql(sql):
    """Fallback: pipe the query through the psql CLI (reads PG* env vars)."""
    env = dict(os.environ)
    env.setdefault("PGDATABASE", "lab")
    # libpq sets the session time zone from PGTZ; override any inherited value.
    env["PGTZ"] = SESSION_TIME_ZONE
    # Both directions are UTF-8 whatever the machine's locale says: without
    # this a Windows code page mangles every non-ASCII character in the data
    # and fails outright on some (a curly quote in a note is enough).
    env["PGCLIENTENCODING"] = "UTF8"
    env["PGCONNECT_TIMEOUT"] = str(connect_timeout())
    # -q keeps psql from echoing a command-status tag in front of the JSON.
    # The query text comes in on stdin so this backend and the psycopg one run
    # exactly the same SQL string, inside the same kind of transaction.
    script = ("BEGIN TRANSACTION READ ONLY;\n"
              "SET LOCAL statement_timeout = %d;\n" % int(statement_timeout() * 1000)
              + sql.rstrip() + "\nROLLBACK;\n")
    proc = subprocess.run(
        ["psql", "-tAXq", "-v", "ON_ERROR_STOP=1"],
        input=script, capture_output=True, text=True, encoding="utf-8", env=env,
        timeout=export_deadline(),
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
class ExportFailed(Exception):
    """The export raised; the cause is in the server log."""


class ExportBusy(Exception):
    """The export did not finish within export_deadline()."""


class _Export:
    """One run of the export, and the event its waiters block on."""

    def __init__(self):
        self.started = time.monotonic()
        self.done = threading.Event()
        self.raw = None
        self.gz = None
        self.failed = False


_lock = threading.Lock()      # guards _cache and _inflight; never held across the query
_cache = {"at": None, "raw": None, "gz": None, "failed_at": None}
_inflight = None


def _run_export(job):
    global _inflight
    try:
        raw = fetch_lab_data(SQL).encode("utf-8")
        job.raw, job.gz = raw, gzip.compress(raw, compresslevel=6)
    except Exception:  # DB down, bad creds, missing schema, timeout, ...
        # The driver's message can name the host, port and login; it stays in
        # the server log.
        sys.stderr.write("/api/data export failed:\n" + traceback.format_exc())
        job.failed = True
    with _lock:
        # An export that was given up on (see cached_payload) still ends up
        # here if it ever returns; its result is older than whatever replaced
        # it, so only its own waiters see it.
        if _inflight is job:
            _inflight = None
            if job.failed:
                _cache["failed_at"] = time.monotonic()
            else:
                # Stamped when the export FINISHED: stamping the start would
                # make any export slower than CACHE_SECONDS stale on arrival,
                # i.e. no caching at all exactly when it matters most.
                _cache.update(at=time.monotonic(), raw=job.raw, gz=job.gz, failed_at=None)
    job.done.set()


def cached_payload():
    """(raw bytes, gzip bytes) of the export, at most CACHE_SECONDS old.

    Concurrent callers share one export. Raises ExportFailed if it failed and
    ExportBusy if it has not finished within export_deadline().
    """
    global _inflight
    deadline = export_deadline()
    with _lock:
        now = time.monotonic()
        if _cache["at"] is not None and now - _cache["at"] < CACHE_SECONDS:
            return _cache["raw"], _cache["gz"]
        if _cache["failed_at"] is not None and now - _cache["failed_at"] < ERROR_RETRY_SECONDS:
            raise ExportFailed()
        job = _inflight
        if job is None or now - job.started > deadline:
            # Nothing running, or what is running has outlived both timeouts
            # (a connection that hangs without erroring): start afresh and
            # leave the old thread to die on its own.
            job = _inflight = _Export()
            threading.Thread(target=_run_export, args=(job,), name="lab-export",
                             daemon=True).start()
    if not job.done.wait(deadline):
        raise ExportBusy()
    if job.failed:
        raise ExportFailed()
    return job.raw, job.gz


def accepts_gzip(header):
    """Whether an Accept-Encoding header allows gzip: named with q > 0, or
    covered by ``*`` with q > 0 and not itself refused (``gzip;q=0``)."""
    named = None
    star = None
    for part in (header or "").split(","):
        bits = [b.strip() for b in part.split(";")]
        coding = bits[0].lower()
        if not coding:
            continue
        q = 1.0
        for bit in bits[1:]:
            if bit.lower().startswith("q="):
                try:
                    q = float(bit[2:])
                except ValueError:
                    q = 0.0
        if coding in ("gzip", "x-gzip"):
            named = q
        elif coding == "*":
            star = q
    if named is not None:
        return named > 0
    return bool(star)


# --------------------------------------------------------------------------
# HTTP handler: the page itself + the /api/data endpoint, nothing else.
# --------------------------------------------------------------------------
class Handler(SimpleHTTPRequestHandler):
    server_version = "CarasLabDashboard"
    sys_version = ""            # do not advertise the Python version

    def __init__(self, *args, **kwargs):
        self._is_page = False
        super().__init__(*args, directory=HERE, **kwargs)

    def _route(self):
        """Map the request path to PAGE or "/api/data"; None for anything else."""
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path in ("/", "", PAGE):
            return PAGE
        if path == "/api/data":
            return path
        return None

    def end_headers(self):
        # On every response, errors included. The page is metadata about
        # unpublished experiments: it must not be framed by another site, and
        # a browser must not second-guess the declared content types.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        if self._is_page:
            # Revalidate each time, so an upgraded page is picked up at once.
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def guess_type(self, path):
        ctype = super().guess_type(path)
        return ctype + "; charset=utf-8" if ctype == "text/html" else ctype

    def _handle(self, send_body):
        route = self._route()
        if route == "/api/data":
            self.handle_api_data(send_body)
        elif route == PAGE:
            self.path = PAGE
            self._is_page = True
            if send_body:
                super().do_GET()
            else:
                super().do_HEAD()
        else:
            self.send_error(404)

    def do_GET(self):
        self._handle(send_body=True)

    def do_HEAD(self):
        self._handle(send_body=False)

    def _send(self, status, body, extra_headers=(), send_body=True):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in extra_headers:
            self.send_header(name, value)
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def handle_api_data(self, send_body=True):
        try:
            raw, gz = cached_payload()
        except ExportBusy:
            body = json.dumps({
                "error": "The database export is taking too long.",
                "detail": "The database export has not finished yet. Try again in a "
                          "moment; the dashboard server's log has more.",
            }).encode("utf-8")
            self._send(503, body, [("Retry-After", "30")], send_body)
            return
        except Exception:  # ExportFailed, or anything unexpected in the cache
            body = json.dumps({
                "error": "Could not read the database.",
                "detail": "Could not read the database. The dashboard server's "
                          "log has the cause.",
            }).encode("utf-8")
            self._send(503, body, [("Retry-After", "5")], send_body)
            return
        if accepts_gzip(self.headers.get("Accept-Encoding", "")):
            self._send(200, gz, [("Content-Encoding", "gzip"), ("Vary", "Accept-Encoding")],
                       send_body)
        else:
            self._send(200, raw, [("Vary", "Accept-Encoding")], send_body)

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
    print("  timeouts : connect %d s, export %d s" % (connect_timeout(), statement_timeout()))
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print("  WARNING  : listening on %s with no authentication and no TLS -- "
              "anyone who can reach this port can read the whole database export."
              % args.host)
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
