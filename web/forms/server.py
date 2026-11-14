#!/usr/bin/env python3
"""Forms server: data entry for one session of one subject (design_docs/forms.md).

Serves the page (forms.html, forms.js, forms.css) and a JSON API under
/api/ that reads and writes the lab database through the SQL functions made
for it: lab.fn_publish_form (templates), lab.fn_add_subject_form (a template
put to use for a subject in a project), lab.fn_record_observation (an entry,
or its correction), lab.fn_set_entry_note and lab.fn_retract. After every
change to a subject's entries it regenerates that subject's CSV for the
project (csv_export.py) under --csv-root.

Every lab member signs in with their own database login. The server opens a
connection as that login and keeps it, in memory only, for the browser
session that signed in (an HttpOnly, SameSite=Strict cookie names it); the
password is used to connect and then dropped. So every row an entry writes
carries the member's own login, as it would from MATLAB, and the database's
privileges -- not this server -- decide what the member may do. There is
never a shared writing login. A session ends at sign-out, after
--idle-minutes without a request, after --max-hours in all, or when its
connection is lost.

Requests that change something must be POSTs carrying the header
X-CarasLab-Forms: 1 and, when the browser sends one, an Origin among
--public-origin (or the request's own host). Bodies are JSON, at most 1 MiB,
and may not contain a JSON number with a fraction or exponent: a value is
sent as the text the user typed, and the database stores that text.

Run it bound to 127.0.0.1 (the default) behind the reverse proxy that gives
the lab HTTPS and its campus sign-in (design_docs/deployment-windows.md);
the cookie is marked Secure unless --insecure-cookie is given for testing
on http://localhost.

CSV files the server could not write (on Windows, a file open in Excel is
locked) are retried every minute. Those retries, and --rebuild-csv, read
the database as the login in the PG* environment variables: a login that
inherits lab_ro (lab_forms in the deployment guide). Without one, a pending
file waits for the next change to that subject.

Connection settings for every login come from the libpq environment
(PGHOST, PGPORT, PGDATABASE, PGSSLMODE, ...); a member's login and password
come from the sign-in form. Requires psycopg 3.

Usage:
    PGDATABASE=lab python web/forms/server.py --csv-root D:\\LabForms
    # then open http://127.0.0.1:8779/  (with --insecure-cookie when testing over http)

    # regenerate every subject's CSV and exit (as the PG* login):
    PGDATABASE=lab PGUSER=lab_forms python web/forms/server.py --csv-root D:\\LabForms --rebuild-csv
"""

import argparse
import datetime as _dt
import decimal
import hashlib
import json
import os
import re
import secrets
import sys
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import csv_export  # noqa: E402

SCHEMA_VERSION = 1
MAX_BODY = 1 << 20
ZONED = re.compile(r"(Z|[+-][0-9]{2}(:?[0-9]{2})?)$")
CONNECT_TIMEOUT = 10
STATEMENT_TIMEOUT_MS = 30000
LIST_LIMIT = 50
CSV_RETRY_SECONDS = 60
FAILED_LOGIN_LIMIT = 5
FAILED_LOGIN_PAUSE = 30.0

STATIC = {
    "/": ("forms.html", "text/html; charset=utf-8"),
    "/forms.html": ("forms.html", "text/html; charset=utf-8"),
    "/forms.js": ("forms.js", "text/javascript; charset=utf-8"),
    "/forms.css": ("forms.css", "text/css; charset=utf-8"),
}
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
       "connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; "
       "frame-ancestors 'none'")

# The SQLSTATEs whose message is written by the schema for people to read
# (lab.fn_* RAISE EXCEPTION, constraint and privilege errors). Anything else
# is answered with a fixed message and logged.
READABLE_SQLSTATE_CLASSES = ("22", "23", "P0", "CL")


def _log(msg):
    sys.stderr.write("[%s] %s\n" % (_dt.datetime.now().isoformat(timespec="seconds"), msg))
    sys.stderr.flush()


def _psycopg():
    try:
        import psycopg
    except ImportError:
        sys.exit("forms server: psycopg 3 is required (python -m pip install \"psycopg[binary]\")")
    return psycopg


def _json_default(value):
    if isinstance(value, (_dt.datetime, _dt.date, _dt.time)):
        return value.isoformat()
    if isinstance(value, (uuid.UUID, decimal.Decimal)):
        return str(value)
    raise TypeError("cannot send %r" % type(value))


def _no_float(text):
    raise ValueError("a JSON number with a fraction or exponent: send values as text")


class ApiError(Exception):
    """An error answered to the browser as {"error": message, ...extra}."""

    def __init__(self, status, message, **extra):
        super().__init__(message)
        self.status = status
        self.message = message
        self.extra = extra


# --------------------------------------------------------------------------
# Sessions: one database connection per signed-in browser session.
# --------------------------------------------------------------------------
class Session:
    def __init__(self, conn, login, person_id, person_name, can_write):
        self.conn = conn
        self.login = login
        self.person_id = person_id
        self.person_name = person_name
        self.can_write = can_write
        self.lock = threading.Lock()
        self.created = time.monotonic()
        self.last_used = self.created

    def close(self):
        try:
            self.conn.close()
        except Exception:
            pass


class SessionStore:
    def __init__(self, idle_seconds, max_seconds, max_sessions=200):
        self.idle_seconds = idle_seconds
        self.max_seconds = max_seconds
        self.max_sessions = max_sessions
        self._sessions = {}
        self._lock = threading.Lock()
        self._failures = {}

    @staticmethod
    def _key(token):
        return hashlib.sha256(token.encode("ascii", "replace")).hexdigest()

    def add(self, session):
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._expire_locked()
            if len(self._sessions) >= self.max_sessions:
                oldest = min(self._sessions, key=lambda k: self._sessions[k].last_used)
                self._sessions.pop(oldest).close()
            self._sessions[self._key(token)] = session
        return token

    def get(self, token):
        if not token:
            return None
        with self._lock:
            self._expire_locked()
            s = self._sessions.get(self._key(token))
            if s is not None:
                s.last_used = time.monotonic()
            return s

    def remove(self, token):
        with self._lock:
            s = self._sessions.pop(self._key(token), None)
        if s is not None:
            s.close()

    def _expire_locked(self):
        now = time.monotonic()
        for k, s in list(self._sessions.items()):
            if now - s.last_used > self.idle_seconds or now - s.created > self.max_seconds \
                    or s.conn.closed:
                self._sessions.pop(k).close()

    def expire(self):
        with self._lock:
            self._expire_locked()

    # Repeated failed sign-ins for one login are slowed down.
    def check_failures(self, login):
        with self._lock:
            n, last = self._failures.get(login, (0, 0.0))
            if n >= FAILED_LOGIN_LIMIT and time.monotonic() - last < FAILED_LOGIN_PAUSE:
                return False
            return True

    def record_failure(self, login, failed):
        with self._lock:
            if failed:
                n, _ = self._failures.get(login, (0, 0.0))
                self._failures[login] = (n + 1, time.monotonic())
            else:
                self._failures.pop(login, None)


# --------------------------------------------------------------------------
# SQL. Every identifier is fixed here; requests supply values only.
# --------------------------------------------------------------------------
SQL_WHOAMI = """
SELECT session_user::text,
       pg_has_role(session_user, 'lab_rw', 'MEMBER') AS can_write,
       (SELECT rolsuper FROM pg_roles WHERE rolname = session_user) AS is_super,
       lab.fn_current_person() AS person_id,
       (SELECT full_name FROM lab.person WHERE person_id = lab.fn_current_person()) AS person_name,
       (SELECT max(version) FROM lab.schema_version) AS schema_version
"""

SQL_FORMS = """
SELECT f.name, f.label, f.description, f.retired_at, f.created_at,
       (SELECT max(v.version) FROM lab.form_version v WHERE v.form_name = f.name) AS latest_version,
       (SELECT count(*) FROM lab.subject_form sf WHERE sf.form_name = f.name) AS n_subject_forms,
       (SELECT count(*) FROM lab.observation_event o WHERE o.form_name = f.name) AS n_entries
FROM lab.form f
ORDER BY f.retired_at IS NOT NULL, lower(f.label), f.name
"""

SQL_FORM = "SELECT name, label, description, retired_at, created_at FROM lab.form WHERE name = %s"
SQL_FORM_VERSIONS = """
SELECT v.version, v.note, v.created_at, v.created_login, p.full_name AS created_by_name
FROM lab.form_version v LEFT JOIN lab.person p ON p.person_id = v.created_by
WHERE v.form_name = %s ORDER BY v.version
"""
SQL_FORM_VERSION = """
SELECT version, definition::text AS definition FROM lab.form_version
WHERE form_name = %s AND version = coalesce(%s, (SELECT max(version) FROM lab.form_version
                                                 WHERE form_name = %s))
"""
SQL_VARIABLES_NAMED = """
SELECT name, label, description, units, value_type, applies_to, retired_at
FROM lab.variable WHERE name = ANY(%s::text[])
"""
SQL_VARIABLE_SEARCH = """
SELECT name, label, description, units, value_type, applies_to, retired_at
FROM lab.variable
WHERE name <> 'entry note'
  AND (%s = '' OR name ILIKE '%%' || %s || '%%' OR label ILIKE '%%' || %s || '%%')
ORDER BY retired_at IS NOT NULL, name LIMIT %s
"""
SQL_SUBJECT_SEARCH = """
SELECT s.subject_id, p.name AS project, sp.common_name AS species, s.sex,
       sc.is_endpointed
FROM lab.subject s
JOIN lab.project p ON p.project_id = s.project_id
LEFT JOIN lab.species sp ON sp.code = s.species_code
JOIN lab.subject_current sc ON sc.subject_id = s.subject_id
WHERE %s = '' OR s.subject_id ILIKE '%%' || %s || '%%'
ORDER BY sc.is_endpointed, s.subject_id LIMIT %s
"""
SQL_PROJECTS = """
SELECT project_id, name, is_active FROM lab.project ORDER BY NOT is_active, lower(name)
"""
SQL_SUBJECT = """
SELECT s.subject_id, s.project_id, p.name AS project, s.species_code, sp.common_name AS species,
       s.sex, s.strain, s.genotype, s.source, s.date_of_birth, s.notes,
       sc.latest_weight_g, sc.latest_weight_at, sc.is_endpointed, sc.endpoint_at
FROM lab.subject s
JOIN lab.project p ON p.project_id = s.project_id
LEFT JOIN lab.species sp ON sp.code = s.species_code
JOIN lab.subject_current sc ON sc.subject_id = s.subject_id
WHERE s.subject_id = %s
"""
SQL_SUBJECT_FORMS = """
SELECT sf.subject_form_id, sf.subject_id, sf.project_id, p.name AS project, sf.form_name,
       f.label AS form_label, sf.form_version,
       (SELECT max(v.version) FROM lab.form_version v WHERE v.form_name = sf.form_name)
           AS latest_version,
       sf.notes, sf.retired_at, f.retired_at AS form_retired_at, sf.created_at,
       (SELECT count(*) FROM lab.observation_active oa
         WHERE oa.subject_form_id = sf.subject_form_id) AS n_entries,
       (SELECT max(oa.occurred_at) FROM lab.observation_active oa
         WHERE oa.subject_form_id = sf.subject_form_id) AS last_entry_at
FROM lab.subject_form sf
JOIN lab.project p ON p.project_id = sf.project_id
JOIN lab.form f ON f.name = sf.form_name
WHERE sf.subject_id = %s
ORDER BY sf.retired_at IS NOT NULL, lower(p.name), sf.created_at, sf.form_name
"""
SQL_SUBJECT_FORM = """
SELECT sf.subject_form_id, sf.subject_id, sf.project_id, p.name AS project,
       p.description AS project_description, p.started_on AS project_started_on,
       sf.form_name, f.label AS form_label, f.description AS form_description,
       sf.form_version, sf.retired_at,
       (SELECT max(v.version) FROM lab.form_version v WHERE v.form_name = sf.form_name)
           AS latest_version
FROM lab.subject_form sf
JOIN lab.project p ON p.project_id = sf.project_id
JOIN lab.form f ON f.name = sf.form_name
WHERE sf.subject_form_id = %s
"""
SQL_MEMBERS = """
SELECT p.full_name, m.role FROM lab.project_member m JOIN lab.person p USING (person_id)
WHERE m.project_id = %s ORDER BY m.role = 'PI' DESC, lower(p.full_name)
"""
SQL_SUBJECT_TAGS = """
SELECT display_tag FROM lab.tag_current WHERE entity_kind = 'subject' AND subject_id = %s
ORDER BY tag
"""
SQL_CURRENT_VARIABLES = """
SELECT c.variable, c.label, c.units, c.value, c.set_at
FROM lab.variable_current c
WHERE c.entity_kind = %s AND c.entity_id = %s AND c.variable = ANY(%s::text[])
"""
SQL_LAST_SURGERY = """
SELECT e.occurred_at, s.procedure, s.target_region, s.hemisphere, s.outcome
FROM lab.event_active e JOIN lab.surgery_event s USING (event_id)
WHERE e.subject_id = %s ORDER BY e.occurred_at DESC, e.event_id DESC LIMIT 1
"""
SQL_ENTRIES = """
SELECT oa.event_id, oa.entry_id, oa.supersedes, oa.form_name, oa.form_version, oa.session_label,
       oa.occurred_at, oa.recorded_at, oa.recorded_login, per.full_name AS entered_by,
       oa.field_values::text AS field_values, oa.note, oa.subject_form_id
FROM lab.observation_active oa
LEFT JOIN lab.person per ON per.person_id = oa.recorded_by
WHERE oa.subject_form_id = %s
ORDER BY oa.occurred_at DESC, oa.event_id DESC
LIMIT %s
"""
SQL_NOTE_HISTORY = """
SELECT vv.value_id, vv.op, vv.value_text, vv.set_at, vv.set_login, per.full_name AS set_by
FROM lab.variable_value vv LEFT JOIN lab.person per ON per.person_id = vv.set_by
WHERE vv.event_id = ANY(%s::uuid[]) AND vv.variable = 'entry note'
  AND coalesce(vv.note, '') NOT LIKE 'carried forward from %%'
ORDER BY vv.value_id
"""
SQL_ENTRY_KEY = """
SELECT sf.subject_form_id, sf.subject_id, sf.project_id
FROM lab.observation_event o JOIN lab.subject_form sf USING (subject_form_id)
WHERE o.event_id = %s
"""


# --------------------------------------------------------------------------
# The application: configuration, CSV bookkeeping, request handlers.
# --------------------------------------------------------------------------
class App:
    def __init__(self, csv_root, public_origins, secure_cookie, idle_minutes, max_hours,
                 csv_time_zone=None, service_login=True):
        self.psycopg = _psycopg()
        self.csv_root = os.path.abspath(csv_root) if csv_root else None
        self.public_origins = set(public_origins or ())
        self.secure_cookie = secure_cookie
        self.cookie_name = "__Host-caraslab-forms" if secure_cookie else "caraslab-forms"
        self.sessions = SessionStore(idle_minutes * 60.0, max_hours * 3600.0)
        self.csv_time_zone = csv_time_zone
        self.service_login = service_login
        self._pending = {}
        self._pending_lock = threading.Lock()
        self._service_conn = None
        self._stop = threading.Event()
        self._service_warned = 0.0

    # ---- connections ----
    def connect_member(self, login, password):
        params = {"user": login, "password": password, "connect_timeout": CONNECT_TIMEOUT,
                  "application_name": "caraslabdb-forms", "autocommit": True,
                  "options": "-c TimeZone=UTC -c statement_timeout=%d" % STATEMENT_TIMEOUT_MS}
        dbname = os.environ.get("PGDATABASE")
        if dbname:
            params["dbname"] = dbname
        return self.psycopg.connect(**params)

    def service_conn(self):
        """The PG* login used for CSV retries; None when it cannot connect."""
        if not self.service_login:
            return None
        conn = self._service_conn
        if conn is not None and not conn.closed:
            return conn
        try:
            conn = self.psycopg.connect(connect_timeout=CONNECT_TIMEOUT, autocommit=True,
                                        application_name="caraslabdb-forms-csv",
                                        options="-c TimeZone=UTC")
        except Exception as exc:
            if time.monotonic() - self._service_warned > 600:
                self._service_warned = time.monotonic()
                _log("CSV retries: cannot connect with the PG* login (%s); pending files "
                     "wait for the next change" % exc.__class__.__name__)
            return None
        self._service_conn = conn
        return conn

    # ---- CSV ----
    def csv_for(self, conn, subject_id, project_id):
        if not self.csv_root:
            return {"status": "disabled", "path": None, "set_aside": [], "message": ""}
        key = (subject_id, str(project_id))
        try:
            status = csv_export.export_subject(conn, self.csv_root, subject_id, project_id,
                                               self.csv_time_zone)
        except Exception:
            _log("CSV %s / %s failed:\n%s" % (subject_id, project_id, traceback.format_exc()))
            status = {"status": "pending", "path": None, "set_aside": [],
                      "message": "the CSV could not be regenerated; it is retried later"}
        with self._pending_lock:
            if status["status"] in ("pending", "conflict"):
                self._pending[key] = status
            else:
                self._pending.pop(key, None)
        if status["status"] != "written" and status["status"] != "unchanged":
            _log("CSV %s / %s: %s %s" % (subject_id, project_id, status["status"],
                                         status["message"]))
        for moved in status.get("set_aside") or ():
            _log("CSV %s / %s: set aside %s" % (subject_id, project_id, moved))
        return status

    def pending_csv(self):
        with self._pending_lock:
            return dict(self._pending)

    def retry_pending(self):
        pending = self.pending_csv()
        if not pending:
            return
        conn = self.service_conn()
        if conn is None:
            return
        for (subject_id, project_id), status in pending.items():
            if status["status"] == "conflict":
                continue
            try:
                self.csv_for(conn, subject_id, project_id)
            except Exception:
                _log("CSV retry failed:\n" + traceback.format_exc())
                try:
                    conn.close()
                except Exception:
                    pass
                return

    def background(self):
        while not self._stop.wait(CSV_RETRY_SECONDS):
            try:
                self.sessions.expire()
                self.retry_pending()
            except Exception:
                _log("background task failed:\n" + traceback.format_exc())

    def rebuild_all(self, conn):
        """Regenerate every subject's CSV; move files no subject form owns any
        more into _moved/. Returns (counts by status, list of moved paths)."""
        counts = {}
        with conn.transaction():
            cur = conn.cursor()
            cur.execute("SELECT DISTINCT subject_id, project_id FROM lab.subject_form "
                        "ORDER BY 1, 2")
            keys = cur.fetchall()
        for subject_id, project_id in keys:
            st = self.csv_for(conn, subject_id, project_id)
            counts[st["status"]] = counts.get(st["status"], 0) + 1
        moved = csv_export.move_stale(self.csv_root, csv_export.stale_entries(conn, self.csv_root))
        return counts, moved

    # ---- queries ----
    @staticmethod
    def rows(conn, sql, params=()):
        from psycopg.rows import dict_row
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, params)
            return cur.fetchall()

    def one(self, conn, sql, params=()):
        r = self.rows(conn, sql, params)
        return r[0] if r else None

    def variables(self, conn, names):
        out = {}
        for r in self.rows(conn, SQL_VARIABLES_NAMED, [list(names)]):
            out[r["name"]] = r
        return out

    def form_bundle(self, conn, name, version=None):
        form = self.one(conn, SQL_FORM, [name])
        if form is None:
            raise ApiError(404, "There is no form template named %s." % name)
        ver = self.one(conn, SQL_FORM_VERSION, [name, version, name])
        if ver is None:
            raise ApiError(404, "Form %s has no version %s." % (name, version))
        definition = json.loads(ver["definition"])
        names = set()
        for sec in definition.get("sections", []):
            for f in sec.get("fields", []):
                if f.get("variable"):
                    names.add(f["variable"])
        for h in definition.get("header", []):
            if h.get("variable"):
                names.add(h["variable"])
        return {"form": form, "version": ver["version"], "definition": definition,
                "versions": self.rows(conn, SQL_FORM_VERSIONS, [name]),
                "variables": self.variables(conn, names)}

    def subject_context(self, conn, subject_form_id):
        sf = self.one(conn, SQL_SUBJECT_FORM, [subject_form_id])
        if sf is None:
            raise ApiError(404, "That subject form does not exist.")
        bundle = self.form_bundle(conn, sf["form_name"], sf["form_version"])
        subject = self.one(conn, SQL_SUBJECT, [sf["subject_id"]])
        definition = bundle["definition"]
        subj_vars = [h["variable"] for h in definition.get("header", [])
                     if h.get("source") == "subject"] + ["baseline weight"]
        proj_vars = [h["variable"] for h in definition.get("header", [])
                     if h.get("source") == "project"]
        entries = self.entries(conn, subject_form_id, 1)
        return {
            "subject_form": sf,
            "form": bundle,
            "subject": subject,
            "members": self.rows(conn, SQL_MEMBERS, [sf["project_id"]]),
            "subject_tags": [r["display_tag"] for r in
                             self.rows(conn, SQL_SUBJECT_TAGS, [sf["subject_id"]])],
            "subject_variables": {r["variable"]: r for r in self.rows(
                conn, SQL_CURRENT_VARIABLES, ["subject", sf["subject_id"], subj_vars])},
            "project_variables": {r["variable"]: r for r in self.rows(
                conn, SQL_CURRENT_VARIABLES, ["project", str(sf["project_id"]), proj_vars])},
            "last_surgery": self.one(conn, SQL_LAST_SURGERY, [sf["subject_id"]]),
            "previous_entry": entries[0] if entries else None,
            "labels": [r["session_label"] for r in self.rows(
                conn, "SELECT session_label FROM lab.observation_active WHERE subject_form_id = %s",
                [subject_form_id])],
            "csv": self.pending_csv().get((sf["subject_id"], str(sf["project_id"]))),
        }

    def entries(self, conn, subject_form_id, limit=500):
        out = []
        for r in self.rows(conn, SQL_ENTRIES, [subject_form_id, limit]):
            r["field_values"] = json.loads(r["field_values"])
            out.append(r)
        return out


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
def make_handler(app):
    class Handler(BaseHTTPRequestHandler):
        server_version = "CarasLabForms"
        sys_version = ""

        # ---- plumbing ----
        def log_message(self, fmt, *args):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

        def _headers(self, status, ctype, length, extra=()):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy", CSP)
            self.send_header("Referrer-Policy", "no-referrer")
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()

        def _send_json(self, status, obj, extra=()):
            body = json.dumps(obj, default=_json_default).encode("utf-8")
            self._headers(status, "application/json; charset=utf-8", len(body),
                          [("Cache-Control", "no-store")] + list(extra))
            self.wfile.write(body)

        def _cookie(self):
            raw = self.headers.get("Cookie", "")
            for part in raw.split(";"):
                k, _, v = part.strip().partition("=")
                if k == app.cookie_name:
                    return v
            return None

        def _set_cookie(self, token, clear=False):
            attrs = ["%s=%s" % (app.cookie_name, "" if clear else token), "Path=/", "HttpOnly",
                     "SameSite=Strict"]
            if app.secure_cookie:
                attrs.append("Secure")
            if clear:
                attrs.append("Max-Age=0")
            return ("Set-Cookie", "; ".join(attrs))

        def _origin_ok(self):
            origin = self.headers.get("Origin")
            if origin is None:
                return True
            if origin in app.public_origins:
                return True
            host = self.headers.get("Host", "")
            parts = urlsplit(origin)
            return bool(host) and parts.netloc == host and parts.scheme in ("http", "https")

        def _body(self):
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                raise ApiError(400, "The request has no valid Content-Length.")
            if n > MAX_BODY:
                raise ApiError(413, "The request is larger than 1 MiB.")
            raw = self.rfile.read(n) if n else b"{}"
            try:
                obj = json.loads(raw.decode("utf-8"), parse_float=_no_float,
                                 parse_constant=_no_float)
            except ValueError as exc:
                raise ApiError(400, "The request is not valid JSON (%s)." % exc)
            if not isinstance(obj, dict):
                raise ApiError(400, "The request must be a JSON object.")
            return obj

        def _session(self, write=False):
            s = app.sessions.get(self._cookie())
            if s is None:
                raise ApiError(401, "You are signed out. Sign in again; entries not yet saved "
                                    "are kept in this browser.", signed_out=True)
            if write and not s.can_write:
                raise ApiError(403, "Your login %s may read but not record data." % s.login)
            return s

        # ---- dispatch ----
        def do_GET(self):
            path, _, query = self.path.partition("?")
            if path in STATIC:
                return self._static(*STATIC[path])
            if not path.startswith("/api/"):
                return self._send_json(404, {"error": "Not found."})
            self._api("GET", path, parse_qs(query, keep_blank_values=True))

        def do_POST(self):
            path = self.path.partition("?")[0]
            if not path.startswith("/api/"):
                return self._send_json(404, {"error": "Not found."})
            if self.headers.get("X-CarasLab-Forms") != "1" or not self._origin_ok():
                return self._send_json(403, {"error": "This request did not come from the "
                                                      "forms page."})
            self._api("POST", path, None)

        def _static(self, name, ctype):
            try:
                with open(os.path.join(HERE, name), "rb") as fh:
                    body = fh.read()
            except OSError:
                return self._send_json(404, {"error": "Not found."})
            self._headers(200, ctype, len(body), [("Cache-Control", "no-cache")])
            self.wfile.write(body)

        def _api(self, method, path, query):
            route = ROUTES.get((method, path))
            if route is None:
                return self._send_json(404, {"error": "Not found."})
            psycopg = app.psycopg
            extra = []
            try:
                if method == "POST":
                    body = self._body()
                else:
                    body = {k: v[-1] for k, v in query.items()}
                result = route(self, body, extra)
                self._send_json(200, result, extra)
            except ApiError as exc:
                out = {"error": exc.message}
                out.update(exc.extra)
                self._send_json(exc.status, out, extra)
            except psycopg.OperationalError:
                _log("database connection lost:\n" + traceback.format_exc())
                tok = self._cookie()
                if tok:
                    app.sessions.remove(tok)
                self._send_json(503, {"error": "The connection to the database was lost. Sign "
                                               "in again; entries not yet saved are kept in "
                                               "this browser.", "signed_out": True},
                                [self._set_cookie("", clear=True)])
            except psycopg.Error as exc:
                self._send_json(*db_error(exc))
            except Exception:
                _log("%s %s failed:\n%s" % (method, path, traceback.format_exc()))
                self._send_json(500, {"error": "The forms server failed; its log has the cause."})

    # ---- routes ----
    def need(body, key, kind=str):
        v = body.get(key)
        if v is None or (kind is str and not isinstance(v, str)) or \
                (kind is int and (not isinstance(v, int) or isinstance(v, bool))) or \
                (kind is dict and not isinstance(v, dict)):
            raise ApiError(400, "%s is missing or of the wrong type." % key)
        return v

    def opt(body, key, kind=str):
        return None if body.get(key) is None else need(body, key, kind)

    def as_uuid(text, what):
        try:
            return str(uuid.UUID(text))
        except (ValueError, TypeError, AttributeError):
            raise ApiError(400, "%s is not an id." % what)

    def r_session(h, body, extra):
        s = app.sessions.get(h._cookie())
        if s is None:
            return {"signed_in": False}
        return {"signed_in": True, "login": s.login, "person_id": s.person_id,
                "person_name": s.person_name, "can_write": s.can_write,
                "idle_minutes": app.sessions.idle_seconds / 60.0,
                "csv": app.csv_root is not None}

    def r_login(h, body, extra):
        login = need(body, "login").strip()
        password = need(body, "password")
        if not login or not password:
            raise ApiError(400, "Enter your database login and password.")
        if not app.sessions.check_failures(login):
            raise ApiError(429, "Too many failed sign-ins for %s; wait half a minute." % login)
        try:
            conn = app.connect_member(login, password)
        except app.psycopg.OperationalError as exc:
            msg = str(exc)
            if "authentication failed" in msg or "does not exist" in msg \
                    or "not permitted to log in" in msg:
                app.sessions.record_failure(login, True)
                raise ApiError(401, "The login or password is not right.")
            _log("sign-in for %s could not reach the database: %s" % (login, msg))
            raise ApiError(503, "The database cannot be reached; the forms server's log has "
                                "the cause.")
        try:
            who = App.rows(conn, SQL_WHOAMI)[0]
        except Exception:
            conn.close()
            raise
        if who["is_super"]:
            conn.close()
            raise ApiError(403, "Sign in with your own lab login, not an administrator's.")
        if who["schema_version"] != SCHEMA_VERSION:
            conn.close()
            raise ApiError(503, "The database is at schema version %s; this forms server "
                                "expects %s." % (who["schema_version"], SCHEMA_VERSION))
        if not who["can_write"]:
            conn.close()
            app.sessions.record_failure(login, False)
            raise ApiError(403, "Login %s is not a lab member's login (it does not inherit "
                                "lab_rw), so it cannot record data." % login)
        app.sessions.record_failure(login, False)
        token = app.sessions.add(Session(conn, who["session_user"], who["person_id"],
                                         who["person_name"], who["can_write"]))
        extra.append(h._set_cookie(token))
        out = {"signed_in": True, "login": who["session_user"], "person_id": who["person_id"],
               "person_name": who["person_name"], "can_write": who["can_write"],
               "idle_minutes": app.sessions.idle_seconds / 60.0,
               "csv": app.csv_root is not None}
        if who["person_id"] is None:
            out["warning"] = ("Your login is not mapped to a person in lab.person, so entries "
                              "name no person; ask the database administrator to set your "
                              "db_login.")
        return out

    def r_logout(h, body, extra):
        tok = h._cookie()
        if tok:
            app.sessions.remove(tok)
        extra.append(h._set_cookie("", clear=True))
        return {"signed_in": False}

    def with_conn(fn):
        def wrapped(h, body, extra, write=False):
            s = h._session(write)
            with s.lock:
                if s.conn.closed:
                    raise app.psycopg.OperationalError("connection closed")
                return fn(h, s, body, extra)
        return wrapped

    def writes(fn):
        inner = with_conn(fn)

        def wrapped(h, body, extra):
            return inner(h, body, extra, write=True)
        return wrapped

    @with_conn
    def r_forms(h, s, body, extra):
        return {"forms": app.rows(s.conn, SQL_FORMS)}

    @with_conn
    def r_form(h, s, body, extra):
        version = body.get("version")
        if version not in (None, ""):
            try:
                version = int(version)
            except ValueError:
                raise ApiError(400, "version is not a number.")
        else:
            version = None
        return app.form_bundle(s.conn, need(body, "name"), version)

    @with_conn
    def r_variables(h, s, body, extra):
        q = (body.get("q") or "").strip()
        return {"variables": app.rows(s.conn, SQL_VARIABLE_SEARCH, [q, q, q, LIST_LIMIT])}

    @with_conn
    def r_subjects(h, s, body, extra):
        q = (body.get("q") or "").strip()
        return {"subjects": app.rows(s.conn, SQL_SUBJECT_SEARCH, [q, q, LIST_LIMIT])}

    @with_conn
    def r_projects(h, s, body, extra):
        return {"projects": app.rows(s.conn, SQL_PROJECTS)}

    @with_conn
    def r_subject(h, s, body, extra):
        sid = need(body, "subject")
        subject = app.one(s.conn, SQL_SUBJECT, [sid])
        if subject is None:
            raise ApiError(404, "There is no subject %s." % sid)
        return {"subject": subject, "subject_forms": app.rows(s.conn, SQL_SUBJECT_FORMS, [sid])}

    @with_conn
    def r_context(h, s, body, extra):
        return app.subject_context(s.conn, as_uuid(need(body, "subject_form"), "subject_form"))

    @with_conn
    def r_entries(h, s, body, extra):
        sfid = as_uuid(need(body, "subject_form"), "subject_form")
        entries = app.entries(s.conn, sfid)
        return {"entries": entries}

    @with_conn
    def r_note_history(h, s, body, extra):
        eid = as_uuid(need(body, "event_id"), "event_id")
        chain = [r["v"] for r in app.rows(
            s.conn, "SELECT v::text AS v FROM lab.fn_event_versions(%s) v", [eid])]
        return {"history": app.rows(s.conn, SQL_NOTE_HISTORY, [chain])}

    @with_conn
    def r_form_validate(h, s, body, extra):
        definition = need(body, "definition", dict)
        problems = app.rows(s.conn, "SELECT ord, path, problem FROM "
                                    "lab.fn_form_definition_problems(%s::jsonb, false)",
                            [json.dumps(definition)])
        return {"problems": problems}

    @writes
    def r_form_publish(h, s, body, extra):
        definition = need(body, "definition", dict)
        with s.conn.transaction():
            r = app.one(s.conn, "SELECT version_number, is_new FROM lab.fn_publish_form("
                                "%s, %s::jsonb, p_label => %s, p_description => %s, "
                                "p_note => %s)",
                        [need(body, "name"), json.dumps(definition), opt(body, "label"),
                         opt(body, "description"), opt(body, "note")])
            name = app.one(s.conn, "SELECT lab.fn_canonical_variable(%s) AS n",
                           [body["name"]])["n"]
        return {"name": name, "version": r["version_number"], "is_new": r["is_new"]}

    @writes
    def r_form_retire(h, s, body, extra):
        retired = body.get("retired")
        if not isinstance(retired, bool):
            raise ApiError(400, "retired must be true or false.")
        with s.conn.transaction():
            n = s.conn.execute("UPDATE lab.form SET retired_at = CASE WHEN %s THEN now() END "
                               "WHERE name = %s", [retired, need(body, "name")]).rowcount
        if n != 1:
            raise ApiError(404, "There is no form template named %s." % body["name"])
        return {"name": body["name"], "retired": retired}

    @writes
    def r_subject_form_add(h, s, body, extra):
        project = opt(body, "project_id")
        with s.conn.transaction():
            r = app.one(s.conn, "SELECT lab.fn_add_subject_form(%s, %s, %s::uuid) AS id",
                        [need(body, "subject_id"), need(body, "form_name"),
                         as_uuid(project, "project_id") if project else None])
        return {"subject_form_id": r["id"]}

    @writes
    def r_subject_form_update(h, s, body, extra):
        sfid = as_uuid(need(body, "subject_form_id"), "subject_form_id")
        sets, params = [], []
        if body.get("form_version") is not None:
            sets.append("form_version = %s")
            params.append(need(body, "form_version", int))
        if isinstance(body.get("retired"), bool):
            sets.append("retired_at = CASE WHEN %s THEN now() END")
            params.append(body["retired"])
        if not sets:
            raise ApiError(400, "Nothing to change.")
        with s.conn.transaction():
            n = s.conn.execute("UPDATE lab.subject_form SET " + ", ".join(sets)
                               + " WHERE subject_form_id = %s", params + [sfid]).rowcount
        if n != 1:
            raise ApiError(404, "That subject form does not exist.")
        return {"subject_form_id": sfid}

    @with_conn
    def r_entry_check(h, s, body, extra):
        values = need(body, "values", dict)
        problems = app.rows(s.conn, "SELECT field, problem FROM lab.fn_observation_problems("
                                    "%s, %s, %s::jsonb)",
                            [need(body, "form_name"), need(body, "form_version", int),
                             json.dumps(values)])
        return {"problems": problems}

    @writes
    def r_entry_submit(h, s, body, extra):
        eid = as_uuid(need(body, "event_id"), "event_id")
        sfid = as_uuid(need(body, "subject_form_id"), "subject_form_id")
        values = need(body, "values", dict)
        occurred_at = need(body, "occurred_at")
        if not ZONED.search(occurred_at):
            raise ApiError(400, "occurred_at must carry its UTC offset (Z or +hh:mm), so that "
                                "it is not read in another time zone.")
        supersedes = opt(body, "supersedes")
        attributes = {"client": "caraslabdb-forms"}
        entered_at = opt(body, "entered_at")
        if entered_at:
            attributes["entered_at"] = entered_at
        with s.conn.transaction():
            outcome = app.one(s.conn, """
                SELECT lab.fn_record_observation(
                    %s::uuid, %s::uuid, %s::timestamptz, %s, %s::jsonb, %s,
                    p_supersedes => %s::uuid, p_attributes => %s::jsonb) AS outcome""",
                [eid, sfid, occurred_at, need(body, "session_label"),
                 json.dumps(values), opt(body, "note"),
                 as_uuid(supersedes, "supersedes") if supersedes else None,
                 json.dumps(attributes)])["outcome"]
            key = app.one(s.conn, SQL_ENTRY_KEY, [eid])
        csv_status = app.csv_for(s.conn, key["subject_id"], key["project_id"])
        return {"event_id": eid, "outcome": outcome, "csv": csv_status}

    @writes
    def r_entry_note(h, s, body, extra):
        eid = as_uuid(need(body, "event_id"), "event_id")
        note = body.get("note")
        if note is not None and not isinstance(note, str):
            raise ApiError(400, "note must be text.")
        with s.conn.transaction():
            outcome = app.one(s.conn, "SELECT lab.fn_set_entry_note(%s::uuid, %s) AS o",
                              [eid, note])["o"]
            key = app.one(s.conn, SQL_ENTRY_KEY, [eid])
        csv_status = app.csv_for(s.conn, key["subject_id"], key["project_id"]) \
            if outcome != "unchanged" else {"status": "unchanged"}
        return {"event_id": eid, "outcome": outcome, "csv": csv_status}

    @writes
    def r_entry_withdraw(h, s, body, extra):
        eid = as_uuid(need(body, "event_id"), "event_id")
        reason = need(body, "reason").strip()
        if not reason:
            raise ApiError(400, "Say why the entry is withdrawn.")
        with s.conn.transaction():
            key = app.one(s.conn, SQL_ENTRY_KEY, [eid])
            if key is None:
                raise ApiError(404, "That entry does not exist.")
            rid = app.one(s.conn, "SELECT lab.fn_retract('event', %s::uuid, %s) AS id",
                          [eid, reason])["id"]
        csv_status = app.csv_for(s.conn, key["subject_id"], key["project_id"])
        return {"event_id": eid, "retraction_id": rid, "csv": csv_status}

    ROUTES = {
        ("GET", "/api/session"): r_session,
        ("POST", "/api/login"): r_login,
        ("POST", "/api/logout"): r_logout,
        ("GET", "/api/forms"): r_forms,
        ("GET", "/api/form"): r_form,
        ("GET", "/api/variables"): r_variables,
        ("GET", "/api/subjects"): r_subjects,
        ("GET", "/api/projects"): r_projects,
        ("GET", "/api/subject"): r_subject,
        ("GET", "/api/context"): r_context,
        ("GET", "/api/entries"): r_entries,
        ("GET", "/api/note-history"): r_note_history,
        ("POST", "/api/form/validate"): r_form_validate,
        ("POST", "/api/form/publish"): r_form_publish,
        ("POST", "/api/form/retire"): r_form_retire,
        ("POST", "/api/subject-form/add"): r_subject_form_add,
        ("POST", "/api/subject-form/update"): r_subject_form_update,
        ("POST", "/api/entry/check"): r_entry_check,
        ("POST", "/api/entry/submit"): r_entry_submit,
        ("POST", "/api/entry/note"): r_entry_note,
        ("POST", "/api/entry/withdraw"): r_entry_withdraw,
    }
    return Handler


def db_error(exc):
    """(status, body) for a database error raised by a request."""
    diag = getattr(exc, "diag", None)
    state = getattr(exc, "sqlstate", None) or ""
    message = (diag.message_primary if diag else None) or str(exc)
    hint = diag.message_hint if diag else None
    if state == "CLB02":
        problems = []
        try:
            problems = json.loads(diag.message_detail or "[]")
        except ValueError:
            pass
        return 422, {"error": message, "problems": problems, "code": state}
    if state in ("CLB01", "CLB03"):
        return 409, {"error": message, "hint": hint, "code": state}
    if state == "42501":
        return 403, {"error": "Your login may not do that (%s)." % message, "code": state}
    if state[:2] in READABLE_SQLSTATE_CLASSES:
        return 422, {"error": message, "hint": hint, "code": state}
    _log("database error %s: %s" % (state, exc))
    return 500, {"error": "The database refused the request; the forms server's log has the "
                          "cause.", "code": state}


def make_server(app, host, port):
    httpd = ThreadingHTTPServer((host, port), make_handler(app))
    httpd.daemon_threads = True
    return httpd


def main(argv=None):
    ap = argparse.ArgumentParser(description="Caras Lab forms server (design_docs/forms.md).")
    ap.add_argument("--host", default="127.0.0.1", help="bind address (default 127.0.0.1)")
    ap.add_argument("--port", type=int, default=8779, help="HTTP port (default 8779)")
    ap.add_argument("--db", help="database name (sets PGDATABASE)")
    ap.add_argument("--csv-root", help="folder the per-subject CSV files are written under")
    ap.add_argument("--no-csv", action="store_true", help="write no CSV files")
    ap.add_argument("--csv-time-zone",
                    help="IANA time zone of the times in the CSV files (default: the "
                         "database's default zone)")
    ap.add_argument("--public-origin", action="append", default=[],
                    help="origin the page is opened from through the proxy, e.g. "
                         "https://labserver.example.edu (repeatable)")
    ap.add_argument("--insecure-cookie", action="store_true",
                    help="session cookie without Secure, for testing on http://localhost only")
    ap.add_argument("--idle-minutes", type=float, default=30.0,
                    help="sign a browser out after this long without a request (default 30)")
    ap.add_argument("--max-hours", type=float, default=12.0,
                    help="sign a browser out this long after sign-in (default 12)")
    ap.add_argument("--rebuild-csv", action="store_true",
                    help="regenerate every subject's CSV as the PG* login, then exit")
    args = ap.parse_args(argv)

    if args.db:
        os.environ["PGDATABASE"] = args.db
    os.environ.setdefault("PGDATABASE", "lab")
    if not args.no_csv and not args.csv_root:
        ap.error("--csv-root is required (or --no-csv)")
    app = App(None if args.no_csv else args.csv_root, args.public_origin,
              not args.insecure_cookie, args.idle_minutes, args.max_hours, args.csv_time_zone)
    if app.csv_root:
        os.makedirs(app.csv_root, exist_ok=True)

    if args.rebuild_csv:
        if not app.csv_root:
            ap.error("--rebuild-csv needs --csv-root")
        conn = app.service_conn()
        if conn is None:
            sys.exit("forms server: cannot connect with the PG* login")
        counts, moved = app.rebuild_all(conn)
        print("rebuild-csv: %s" % ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items()))
              if counts else "rebuild-csv: no subject forms")
        for m in moved:
            print("  moved %s (no subject form owns it any more)" % m)
        sys.exit(0 if set(counts) <= {"written", "unchanged"} else 1)

    httpd = make_server(app, args.host, args.port)
    threading.Thread(target=app.background, daemon=True).start()
    url = "http://%s:%d/" % (args.host, httpd.server_address[1])
    print("Caras Lab forms serving at %s" % url)
    print("  database : %s" % os.environ.get("PGDATABASE"))
    print("  CSV root : %s" % (app.csv_root or "(no CSV files)"))
    print("  sessions : idle %g min, at most %g h; cookie %s"
          % (args.idle_minutes, args.max_hours, "Secure" if app.secure_cookie else "NOT Secure"))
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print("  WARNING  : listening on %s without TLS -- passwords would cross the network "
              "in clear. Bind to 127.0.0.1 behind the HTTPS proxy." % args.host)
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
