#!/usr/bin/env python3
"""Live backend for the Caras Lab metadata dashboard.

Serves the static dashboard page (web/live/lab-dashboard-live.html) and a
single JSON endpoint, ``/api/data``, that runs ``lab_data.sql`` against the
live Postgres database and returns the whole ``LAB_DATA`` payload the
dashboard expects. Everything the browser needs comes from the same origin,
so there are no CORS concerns.

The query is executed per request, so the dashboard always reflects the
current database state. Database connection settings are taken from the
standard libpq environment variables:

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
import json
import os
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_PATH = os.path.join(HERE, "lab_data.sql")


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
    proc = subprocess.run(
        ["psql", "-tAX", "-v", "ON_ERROR_STOP=1", "-f", SQL_PATH],
        capture_output=True, text=True, env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "psql failed")
    return proc.stdout.strip()


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
# HTTP handler: static files from this directory + the /api/data endpoint.
# --------------------------------------------------------------------------
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=HERE, **kwargs)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/api/data":
            self.handle_api_data()
            return
        if self.path in ("/", ""):
            self.path = "/lab-dashboard-live.html"
        super().do_GET()

    def handle_api_data(self):
        try:
            payload = fetch_lab_data(SQL).encode("utf-8")
        except Exception as exc:  # DB down, bad creds, missing schema, ...
            body = json.dumps({
                "error": "Could not read the database.",
                "detail": str(exc),
            }).encode("utf-8")
            self.send_response(503)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

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
