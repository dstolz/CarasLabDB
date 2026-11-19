#!/usr/bin/env python3
"""End-to-end check of tools/import_nas_files.py (run and check) against PostgreSQL.

Run against a database that has schema.sql and grants.sql applied and that
this check may write to (it commits rows; use a throw-away database), as a
superuser (it creates throw-away roles and backdates rows):

    createdb lab_nas
    psql -X -q -d lab_nas -f design_docs/schema.sql -f design_docs/grants.sql
    PGDATABASE=lab_nas python tests/check_import_nas_files.py

Builds fixture trees in a temporary folder (with the builders of
tests/check_nas_import_parsing.py), lists them in lab.scan_directory under
storage roots, subjects and roles of its own (named with a random tag, so
reruns on one database do not collide), drives the tool through subprocess
as a user would, and asserts on the database afterwards. A sighting is made
"old" by inserting a backdated lab.scan_run row as the superuser, never by
a clock option of the tool. A few failures that cannot be produced from
outside (a folder that cannot be listed when running as root, a lost
connection, a file that changes while it is read, a window that closes) are
injected by starting the tool through a wrapper that replaces one function.

Every directory the check lists is turned off when it ends. Exits non-zero
with a message on the first failure; prints ``check_import_nas_files: OK``.
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "tools")
TOOL = os.path.join(TOOLS, "import_nas_files.py")
sys.path.insert(0, HERE)
sys.path.insert(0, TOOLS)

import check_nas_import_parsing as P  # noqa: E402  (the fixture builders)
import psycopg  # noqa: E402
from nas_import import rhd as rhd_module  # noqa: E402

ZONE = "America/New_York"
PREFIX = "nasimp-"
TAG = uuid.uuid4().hex[:8]
E, I = "epsych_files/Data", "intan_files/Data"  # noqa: E741
CHECKS = []
N_ASSERTS = 0

conn = psycopg.connect(autocommit=True)
TMP = tempfile.mkdtemp(prefix="check_import_nas_")


def fail(msg):
    sys.exit("check_import_nas_files: " + msg)


def check(cond, msg):
    global N_ASSERTS
    N_ASSERTS += 1
    if not cond:
        fail(msg)


def named(fn):
    CHECKS.append(fn)
    return fn


def q(sql, params=()):
    return conn.execute(sql, params).fetchall()


def q1(sql, params=()):
    row = conn.execute(sql, params).fetchone()
    return None if row is None else row[0]


# --------------------------------------------------------------------------- the tool
def tool(*args, env=None, patch=None):
    """Run the tool; (exit status, stdout + stderr). PATCH is Python run before main()."""
    full = dict(os.environ)
    full.update(env or {})
    if patch is None:
        cmd = [sys.executable, TOOL, *args]
    else:
        code = ("import sys; sys.path.insert(0, %r); import import_nas_files as tool; "
                "from nas_import import engine, database, mat5, walk, content\n%s\n"
                "sys.exit(tool.main(%r))" % (TOOLS, patch, [str(a) for a in args]))
        cmd = [sys.executable, "-c", code]
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", env=full)
    return proc.returncode, proc.stdout + proc.stderr


class World:
    """A storage root in a temporary folder, with its subjects and directories."""
    count = 0

    def __init__(self, name):
        World.count += 1
        self.name = "%s%s-%s-%d" % (PREFIX, TAG, name, World.count)
        self.path = os.path.join(TMP, "w%d_%s" % (World.count, name))
        os.makedirs(self.path)
        conn.execute("INSERT INTO lab.storage_root (name) VALUES (%s)", (self.name,))
        self.root_id = q1("SELECT root_id FROM lab.storage_root WHERE name = %s", (self.name,))
        self.project = q1("INSERT INTO lab.project (name) VALUES (%s) RETURNING project_id",
                          (self.name,))
        self.n = World.count
        self.dirs = []
        self.cache = os.path.join(TMP, "cache_%d.json" % World.count)
        self.reports = os.path.join(TMP, "reports_%d" % World.count)

    def subject(self, k=1, create=True):
        sid = "W%s-%d-%d" % (TAG, self.n, k)
        if create:
            conn.execute("INSERT INTO lab.subject (subject_id, project_id) VALUES (%s, %s) "
                         "ON CONFLICT DO NOTHING", (sid, self.project))
        return sid

    def directory(self, path, layout, pair_with=None, min_age=0, mode="register", rig="RIG9",
                  interval=60):
        os.makedirs(os.path.join(self.path, *path.split("/")), exist_ok=True)
        did = q1("INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, rig, "
                 "pair_with, time_zone, scan_interval_min, min_age_min, mode) "
                 "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING scan_directory_id",
                 (self.root_id, path, layout, rig, pair_with, ZONE, interval, min_age, mode))
        self.dirs.append(did)
        return did

    def pair(self, min_age=0, mode="register"):
        """The usual two directories: (ePsych id, Intan id)."""
        e = self.directory(E, "epsych", min_age=min_age, mode=mode)
        i = self.directory(I, "intan", pair_with=e, min_age=min_age, mode=mode)
        return e, i

    def abs(self, rel):
        return os.path.join(self.path, *rel.split("/"))

    def write(self, rel, data):
        P.write(self.abs(rel), data)
        return rel

    def root_arg(self):
        return "%s=%s" % (self.name, self.path)

    def run(self, *dirs, extra=(), env=None, patch=None, now=True):
        args = ["run", "--root", self.root_arg(), "--report-dir", self.reports]
        if now:
            args.append("--now")
        for d in dirs:
            args += ["--directory", str(d)]
        return tool(*args, *extra, env=env, patch=patch)

    def ok(self, *dirs, extra=(), env=None, patch=None, now=True, times=1):
        out = ""
        for _ in range(times):
            code, out = self.run(*dirs, extra=extra, env=env, patch=patch, now=now)
            check(code == 0, "run of %s exited %d: %s" % (self.name, code, out))
        return out

    # what the database says
    def memory(self):
        return {r[0]: {"status": r[1], "code": r[2], "artifact": r[3], "key": r[4], "size": r[5],
                       "mtime_ns": r[6], "reason": r[7]}
                for r in q("SELECT relative_path, status, reason_code, artifact_id::text, "
                           "group_key, size_bytes, mtime_ns, reason FROM lab.scan_file_latest "
                           "WHERE storage_root_id = %s", (self.root_id,))}

    def artifacts(self):
        return {r[0]: {"id": r[1], "event": r[2], "checksum": r[3], "size": r[4], "role": r[5],
                       "format": r[6], "subject": r[7], "session": r[8], "attributes": r[9]}
                for r in q("SELECT relative_path, artifact_id::text, produced_by_event_id::text, "
                           "checksum, size_bytes, role, format, subject_id, session_id::text, "
                           "attributes FROM lab.artifact WHERE storage_root_id = %s",
                           (self.root_id,))}

    def events(self):
        """Events that produced a file on this root: id -> row."""
        return {r[0]: {"type": r[1], "subject": r[2], "session": r[3], "attributes": r[4],
                       "occurred_at": r[5], "login": r[6], "by": r[7]}
                for r in q("SELECT e.event_id::text, e.event_type, e.subject_id, "
                           "e.session_id::text, e.attributes, e.occurred_at, e.recorded_login, "
                           "e.recorded_by FROM lab.event e WHERE e.event_id IN (SELECT "
                           "produced_by_event_id FROM lab.artifact WHERE storage_root_id = %s)",
                           (self.root_id,))}

    def last(self, directory):
        """The latest run of DIRECTORY that has a result, as a dict."""
        row = conn.execute(
            "SELECT r.scan_run_id, r.mode, r.due_at, x.* FROM lab.scan_run r "
            "JOIN lab.scan_run_result x ON x.scan_run_id = r.scan_run_id "
            "WHERE r.scan_directory_id = %s ORDER BY r.scan_run_id DESC LIMIT 1", (directory,))
        names = [c.name for c in row.description]
        values = row.fetchone()
        check(values is not None, "directory %d has no run with a result" % directory)
        return dict(zip(names, values))

    def off(self):
        conn.execute("UPDATE lab.scan_directory SET mode = 'off' WHERE storage_root_id = %s",
                     (self.root_id,))


def backdate(directory, minutes):
    """Make every sighting of DIRECTORY's files MINUTES old.

    Inserts a lab.scan_run that started MINUTES ago (with an 'ok' result) and
    appends the latest memory row of every file under the directory again as
    that run's: exactly what a complete listing made then would have left.
    """
    root_id, path, mode = q("SELECT storage_root_id, relative_path, mode FROM lab.scan_directory "
                            "WHERE scan_directory_id = %s", (directory,))[0]
    run_id = q1("INSERT INTO lab.scan_run (scan_directory_id, command, mode, started_at) "
                "VALUES (%s, 'run', %s, clock_timestamp() - make_interval(mins => %s)) "
                "RETURNING scan_run_id", (directory, "report" if mode == "off" else mode, minutes))
    conn.execute("INSERT INTO lab.scan_run_result (scan_run_id, outcome) VALUES (%s, 'ok')",
                 (run_id,))
    conn.execute(
        "INSERT INTO lab.scan_file (scan_run_id, storage_root_id, relative_path, size_bytes, "
        "mtime_ns, group_key, status, reason_code, reason, artifact_id) "
        "SELECT %s, storage_root_id, relative_path, size_bytes, mtime_ns, group_key, status, "
        "reason_code, reason, artifact_id FROM lab.scan_file_latest "
        "WHERE storage_root_id = %s AND starts_with(relative_path, %s) ORDER BY scan_file_id",
        (run_id, root_id, path + "/"))


def table_counts(skip=()):
    out = {}
    for (name,) in q("SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = "
                     "c.relnamespace WHERE n.nspname = 'lab' AND c.relkind = 'r' ORDER BY 1"):
        if name not in skip:
            out[name] = q1('SELECT count(*) FROM lab."%s"' % name)
    return out


def corrections():
    """Rows that an unattended run must never write."""
    return (q1("SELECT count(*) FROM lab.event WHERE supersedes IS NOT NULL"),
            q1("SELECT count(*) FROM lab.artifact WHERE supersedes IS NOT NULL"),
            q1("SELECT count(*) FROM lab.retraction"),
            q1("SELECT count(*) FROM lab.artifact_disposition"))


def steady(world, *dirs):
    """Running everything again changes nothing but the run log."""
    before = table_counts(skip=("scan_run", "scan_run_result"))
    rows = q1("SELECT max(scan_file_id) FROM lab.scan_file")
    for d in dirs:
        world.ok(d)
    after = table_counts(skip=("scan_run", "scan_run_result"))
    diff = {k: (before[k], after[k]) for k in before if before[k] != after[k]}
    check(not diff, "a run on an unchanged tree changed row counts: %s" % diff)
    check(q1("SELECT max(scan_file_id) FROM lab.scan_file") == rows, "memory rows were appended")


# --------------------------------------------------------------------------- files
def sha(data):
    return hashlib.sha256(data).hexdigest()


def mat(salt, fixture="epsych_n5_z.mat"):
    """An ePsych session file with bytes of its own (the header text carries SALT)."""
    data = bytearray(P.fixture(fixture))
    text = hashlib.sha256(("%s:%s" % (TAG, salt)).encode()).hexdigest()[:60].encode("ascii")
    data[40:40 + len(text)] = text
    return bytes(data)


FS, N_AMP = 1000.0, 1          # an RHX sample rate; 128 samples per data block
LONG, SHORT = 1000, 125        # blocks: 128 s (pairs with an ePsych session) and 16 s


def seconds(blocks):
    """The exact duration text of BLOCKS data blocks."""
    whole, rest = divmod(blocks * 128, int(FS))
    return str(whole) if rest == 0 else ("%d.%03d" % (whole, rest)).rstrip("0")


def rhd(salt, blocks=LONG):
    """An Intan file of BLOCKS data blocks with bytes of its own."""
    data = bytearray(P.rhd_file(blocks, fs=FS, n_amp=N_AMP))
    data[-32:] = hashlib.sha256(("%s:%s" % (TAG, salt)).encode()).digest()
    return bytes(data)


def recording(w, subject, stamp, files=("a.rhd", "settings.xml"), blocks=LONG, folder=None,
              subject_folder=None):
    """Write a recording folder <subject>_<yyMMdd>_<HHmmss>; returns {relative path: bytes}."""
    folder = folder or "%s_%s" % (subject, stamp)
    base = "%s/%s/%s" % (I, subject_folder or subject, folder)
    out = {}
    for name in files:
        data = (rhd(base + name, blocks) if name.endswith(".rhd")
                else ("<%s %s/>" % (name, base)).encode())
        out[w.write("%s/%s" % (base, name), data)] = data
    return out


def session(w, subject, stamp, suffixes=("",), video=False, fixture="epsych_n5_z.mat"):
    """Write an ePsych session <subject>_<yyMMdd>T<HHmmss>[_suffix].mat; {relative path: bytes}."""
    base = "%s/%s/%s_%s" % (E, subject, subject, stamp)
    out = {}
    for suffix in suffixes:
        rel = base + ("_" + suffix if suffix else "") + ".mat"
        data = mat(rel, fixture)
        out[w.write(rel, data)] = data
    if video:
        out[w.write(base + ".ts", P.TS_GOOD + rel.encode())] = P.TS_GOOD + rel.encode()
    return out


def statuses(w, paths):
    m = w.memory()
    return sorted({m[p]["status"] if p in m else "none" for p in paths})


def codes(w, paths):
    m = w.memory()
    return sorted({m[p]["code"] or "" if p in m else "none" for p in paths})


def not_root_posix():
    return os.name == "posix" and os.geteuid() != 0


# --------------------------------------------------------------------------- checks
@named
def usage_errors_exit_2():
    w = World("usage")
    w.pair()
    empty = os.path.join(TMP, "empty_root")
    os.makedirs(empty)
    for args, what in (
            (["run"], "at least one --root"),
            (["run", "--root", "nope-%s=%s" % (TAG, w.path)], "no such storage root"),
            (["run", "--root", "%s=%s" % (w.name, empty)], "is empty"),
            (["run", "--root", "%s=%s" % (w.name, os.path.join(TMP, "missing"))],
             "not a directory"),
            (["run", "--root", w.root_arg(), "--directory", "2147483000"], "no scan directory"),
            (["scan", "--directory", "1"], "not implemented"),
            (["apply", "plan.jsonl"], "not implemented")):
        code, out = tool(*args)
        check(code == 2 and what in out, "%s: exit %d, %s" % (args, code, out))
    # Two roots one inside the other.
    inner = World("inner")
    nested = os.path.join(w.path, "epsych_files")
    code, out = tool("run", "--root", w.root_arg(), "--root", "%s=%s" % (inner.name, nested))
    check(code == 2 and "contain each other" in out, "nested roots: %d %s" % (code, out))
    # A marker that names another root.
    P.write(os.path.join(w.path, ".caraslabdb-root.json"),
            json.dumps({"name": "another-root", "root_id": 1}).encode())
    code, out = w.run()
    check(code == 2 and "is storage root 'another-root'" in out, "marker: %d %s" % (code, out))
    P.write(os.path.join(w.path, ".caraslabdb-root.json"), json.dumps({"name": w.name}).encode())
    # A malformed overrides file, before anything is written.
    bad = os.path.join(TMP, "bad_overrides.csv")
    P.write(bad, b"root,path,subject\nx,y,z\n")
    runs = q1("SELECT count(*) FROM lab.scan_run")
    code, out = w.run(extra=["--overrides", bad])
    check(code == 2 and "--overrides" in out, "bad overrides: %d %s" % (code, out))
    check(q1("SELECT count(*) FROM lab.scan_run") == runs, "a refused run wrote a scan_run row")
    # The root's own marker is accepted.
    w.subject()
    recording(w, w.subject(), "260307_101800")
    session(w, w.subject(), "260307T101500")
    w.ok()
    w.off()
    inner.off()


@named
def first_sighting_registers_nothing_second_registers_third_reads_nothing():
    w = World("basic")
    e, i = w.pair()
    s = w.subject()
    rec = recording(w, s, "260307_101800", files=("a.rhd", "b.rhd", "settings.xml"))
    beh = session(w, s, "260307T101500", suffixes=("", "psych"), video=True)
    day = {w.write("%s/%s/%s_07-Mar-2026_A.mat" % (E, s, s), mat("day", "epsych_n3_u.mat")): None}
    lone = session(w, s, "260309T090000", fixture="epsych_n1_z.mat")

    # 1. The scheduled run: due since the row was added; the first sighting registers nothing.
    due = q1("SELECT due_at FROM lab.fn_scan_due() WHERE scan_directory_id = %s", (i,))
    check(due is not None, "a new directory is not due")
    out = w.ok(i, now=False)
    last = w.last(i)
    check(last["outcome"] == "ok" and last["due_at"] == due,
          "due_at recorded %s, the function gave %s" % (last["due_at"], due))
    check(statuses(w, rec) == ["pending"] and not w.artifacts(),
          "first sighting: %s %s" % (statuses(w, rec), out))
    check(last["files_pending"] == 3 and last["files_registered"] == 0
          and last["groups_waiting"] == 1 and last["bytes_read"] > 0, "counters %s" % last)
    check(statuses(w, beh) == ["none"], "the Intan run wrote rows for the paired directory")
    # Not due again at once: the schedule moved by the interval.
    code, out = w.run(i, now=False)
    check(code == 0 and "0 of 0 searched" in out, "second scheduled run: %s" % out)

    # 2. The second sighting (min_age_min = 0) registers the recording.
    w.ok(e, extra=["--cache-file", w.cache])           # ePsych: first sighting
    check(statuses(w, beh) == ["pending"] and statuses(w, lone) == ["pending"], "ePsych pending")
    out = w.ok(i, extra=["--cache-file", w.cache])
    last = w.last(i)
    check(last["due_at"] is None, "a run made with --now recorded a due_at")
    arts = w.artifacts()
    check(set(arts) == set(rec), "registered %s, expected %s: %s" % (sorted(arts), sorted(rec), out))
    check(last["files_registered"] == 3 and last["groups_registered"] == 1
          and last["details"]["files_read"] == 3, "counters %s" % last)
    events = w.events()
    check(len(events) == 1, "one recording event, got %d" % len(events))
    (rec_event, ev), = events.items()
    folder = "%s/%s/%s_260307_101800" % (I, s, s)
    check(ev["type"] == "recording" and ev["subject"] == s and ev["login"]
          and ev["attributes"]["import"]["path"] == folder
          and ev["attributes"]["captured_by_tool"] == "import_nas_files"
          and re.fullmatch("[0-9a-f]{64}", ev["attributes"]["client_digest"]),
          "recording event %s" % ev)
    check(q1("SELECT %s = ('2026-03-07 10:18:00'::timestamp AT TIME ZONE %s)",
             (ev["occurred_at"], ZONE)), "occurred_at %s" % ev["occurred_at"])
    detail = q("SELECT acquisition_system_code, modality, sample_rate_hz::text, n_channels, "
               "duration_s::text FROM lab.recording_event WHERE event_id = %s", (rec_event,))
    check(detail == [("intan_rhx", "ephys", "1000", N_AMP, seconds(2 * LONG))],
          "detail row %s" % detail)
    sess = q("SELECT subject_id, label, relative_path, rig, "
             "started_at = ('2026-03-07 10:18:00'::timestamp AT TIME ZONE %s), "
             "ended_at = started_at + make_interval(secs => %s), created_by "
             "FROM lab.session WHERE session_id = %s",
             (ZONE, float(seconds(2 * LONG)), ev["session"]))
    check(sess == [(s, "%s_260307_101800" % s, folder, "RIG9", True, True, None)],
          "session row %s" % sess)
    for rel, data in rec.items():
        a = arts[rel]
        check(a["checksum"] == sha(data) and a["size"] == len(data) and a["role"] == "raw"
              and a["format"] == rel.rsplit(".", 1)[1] and a["subject"] == s
              and a["session"] == ev["session"] and a["event"] == rec_event
              and a["attributes"]["kind"] == "raw" and a["attributes"]["reader"] == "intan"
              and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{9}Z",
                               a["attributes"]["source_mtime"]), "artifact %s: %s" % (rel, a))
    ver = q("SELECT a.relative_path, v.status, v.observed_checksum, v.verified_login "
            "FROM lab.artifact_verification v JOIN lab.artifact a USING (artifact_id) "
            "WHERE a.storage_root_id = %s", (w.root_id,))
    check(sorted(ver) == sorted((rel, "ok", sha(data), ev["login"]) for rel, data in rec.items()),
          "verification rows %s" % ver)
    mem = w.memory()
    check(all(mem[rel]["status"] == "registered" and mem[rel]["artifact"] == arts[rel]["id"]
              for rel in rec), "memory of the registered files")

    # 3. The ePsych directory: the paired session joins the recording's session, the
    #    others get sessions of their own; a date-only session is 12:00 that day.
    w.ok(e, extra=["--cache-file", w.cache])
    arts = w.artifacts()
    check(set(arts) == set(rec) | set(beh) | set(day) | set(lone),
          "after the ePsych run: %s" % sorted(arts))
    events = w.events()
    paired = events[arts[next(iter(beh))]["event"]]
    check(len({arts[p]["event"] for p in beh}) == 1 and paired["type"] == "behavior"
          and paired["session"] == ev["session"], "the paired session is not in the recording's "
          "session: %s" % paired)
    check(q1("SELECT trials_completed FROM lab.behavior_event WHERE event_id = %s",
             (arts[next(iter(beh))]["event"],)) == 5, "trials_completed")
    video = [p for p in beh if p.endswith(".ts")][0]
    check(arts[video]["role"] == "video" and arts[video]["format"] == "ts", "video artifact")
    d_ev = events[arts[next(iter(day))]["event"]]
    check(d_ev["attributes"].get("occurred_precision") == "day"
          and q1("SELECT %s = ('2026-03-07 12:00:00'::timestamp AT TIME ZONE %s)",
                 (d_ev["occurred_at"], ZONE))
          and q1("SELECT started_at IS NULL FROM lab.session WHERE session_id = %s",
                 (d_ev["session"],)), "date-only session %s" % d_ev)
    l_ev = events[arts[next(iter(lone))]["event"]]
    check(l_ev["session"] not in (ev["session"], d_ev["session"])
          and q1("SELECT started_at = ('2026-03-09 09:00:00'::timestamp AT TIME ZONE %s) "
                 "AND ended_at IS NULL FROM lab.session WHERE session_id = %s",
                 (ZONE, l_ev["session"])), "the unpaired session's own session")
    check(len(events) == 4, "four events, got %d" % len(events))

    # 4. A third run with the cache opens no file at all, also when none can be opened.
    w.ok(e, i, extra=["--cache-file", w.cache])        # fills the cache with what was just read
    every = list(rec) + list(beh) + list(day) + list(lone)
    if not_root_posix():
        for rel in every:
            os.chmod(w.abs(rel), 0)
    w.ok(e, i, extra=["--cache-file", w.cache])
    for d in (e, i):
        last = w.last(d)
        check(last["bytes_read"] == 0 and last["details"]["files_opened"] == 0
              and last["details"]["files_read"] == 0 and last["files_unchanged"] > 0
              and last["files_registered"] == 0,
              "third run of %d read something: %s" % (d, last))
    if not_root_posix():
        for rel in every:
            os.chmod(w.abs(rel), 0o644)
    # Without the cache only headers are read again: nothing to its end.
    w.ok(e, i)
    for d in (e, i):
        last = w.last(d)
        check(last["details"]["files_opened"] > 0 and last["details"]["files_read"] == 0
              and 0 < last["bytes_read"] < sum(len(b) for b in rec.values()),
              "run without cache of %d: %s" % (d, last))
    check(len(w.artifacts()) == len(every), "a later run registered something again")
    steady(w, e, i)
    w.off()


@named
def a_group_waits_min_age_and_any_change_restarts_the_wait():
    w = World("age")
    d = w.directory(I, "intan", min_age=60)
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    folder = next(iter(rec)).rsplit("/", 1)[0]
    w.ok(d)
    w.ok(d)                                   # a second sighting, minutes too early
    last = w.last(d)
    check(statuses(w, rec) == ["pending"] and not w.artifacts() and last["groups_waiting"] == 1
          and last["files_pending"] == 0 and last["details"]["files_read"] == 0,
          "min_age 60: registered or read too early: %s" % last)
    backdate(d, 59)
    w.ok(d)
    check(not w.artifacts(), "registered after 59 of 60 minutes")
    # A file added between the sightings: the folder grows, the wait starts again.
    backdate(d, 61)
    added = w.write(folder + "/b.rhd", rhd("added", SHORT))
    w.ok(d)
    check(not w.artifacts() and statuses(w, list(rec) + [added]) == ["pending"],
          "a folder that grew was registered")
    w.ok(d)
    check(not w.artifacts(), "the added file did not restart the wait")
    # A file touched between the sightings.
    backdate(d, 61)
    first = next(iter(rec))
    st = os.stat(w.abs(first))
    os.utime(w.abs(first), ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
    w.ok(d)
    check(not w.artifacts() and w.memory()[first]["mtime_ns"] == st.st_mtime_ns + 1_000_000_000,
          "a touched file did not restart the wait")
    # A file removed between the sightings: cleared, and the wait starts again.
    backdate(d, 61)
    os.remove(w.abs(added))
    w.ok(d)
    check(not w.artifacts() and w.memory()[added]["status"] == "cleared"
          and w.last(d)["files_cleared"] == 1, "a removed file did not restart the wait")
    w.ok(d)
    check(not w.artifacts(), "registered right after a file was cleared")
    # Seen unchanged for 61 minutes: registered.
    backdate(d, 61)
    w.ok(d)
    check(set(w.artifacts()) == set(rec) and statuses(w, rec) == ["registered"],
          "a backdated sighting was not registered: %s" % w.memory())
    steady(w, d)
    w.off()


@named
def an_incomplete_listing_fails_the_run_and_writes_no_memory():
    w = World("unlistable")
    d = w.directory(I, "intan")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    other = recording(w, s, "260308_101800", blocks=SHORT)
    blocked = w.abs(next(iter(other)).rsplit("/", 1)[0])
    rows = q1("SELECT count(*) FROM lab.scan_file")
    if not_root_posix():
        os.chmod(blocked, 0)
        code, out = w.run(d)
        os.chmod(blocked, 0o755)
    else:                 # root reads everything: make the folder unlistable in the walker
        code, out = w.run(d, patch=(
            "real = walk._sorted_entries\n"
            "def unlistable(path):\n"
            "    if path == %r:\n"
            "        raise PermissionError(13, 'Permission denied', path)\n"
            "    return real(path)\n"
            "walk._sorted_entries = unlistable" % blocked))
    last = w.last(d)
    check(code == 1 and last["outcome"] == "failed" and "could not be listed" in last["message"],
          "an unlistable folder: exit %d, %s, %s" % (code, last, out))
    check(q1("SELECT count(*) FROM lab.scan_file") == rows and not w.artifacts()
          and last["files_pending"] == 0, "a failed run wrote memory rows")
    reports = [n for n in os.listdir(w.reports) if n.endswith("run%d.txt" % last["scan_run_id"])]
    check(len(reports) == 1, "no report of the failed run")
    # The same failure again is not reported again; the run is still recorded.
    w.ok(d, times=2)
    check(set(w.artifacts()) == set(rec) | set(other), "not registered once it could be listed")
    w.off()


@named
def a_missing_or_empty_directory_is_unreachable():
    w = World("unreachable")
    d = w.directory(I, "intan")
    rows = q1("SELECT count(*) FROM lab.scan_file")
    code, out = w.run(d)
    last = w.last(d)
    check(code == 1 and last["outcome"] == "unreachable" and "empty" in last["message"],
          "an empty directory: %d %s" % (code, out))
    shutil.rmtree(w.abs(I))
    code, out = w.run(d)
    last = w.last(d)
    check(code == 1 and last["outcome"] == "unreachable", "a missing directory: %d %s" % (code, out))
    check(q1("SELECT count(*) FROM lab.scan_file") == rows, "an unreachable run wrote memory")
    # Spelled differently on disk: refused, not searched.
    os.makedirs(w.abs("intan_files/data"))
    P.write(w.abs("intan_files/data/x.txt"), b"x")
    code, out = w.run(d)
    last = w.last(d)
    if os.path.isdir(w.abs(I)):          # a file system that ignores case
        check(last["outcome"] == "failed" and "spelled" in last["message"], "spelling: %s" % last)
    else:
        check(code == 1 and last["outcome"] in ("failed", "unreachable"), "spelling: %s" % last)
    w.off()


@named
def a_touched_file_is_read_once_becomes_known_and_gets_no_artifact():
    w = World("touched")
    d = w.directory(I, "intan")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    w.ok(d, times=2)
    arts = w.artifacts()
    check(set(arts) == set(rec), "not registered")
    rel = [p for p in rec if p.endswith(".rhd")][0]
    st = os.stat(w.abs(rel))
    os.utime(w.abs(rel), ns=(st.st_atime_ns, st.st_mtime_ns + 5_000_000_000))
    before = corrections()
    w.ok(d)                                   # seen changed: waits to be seen unchanged
    check(w.memory()[rel]["status"] == "pending" and w.last(d)["details"]["files_read"] == 0,
          "a touched file was read at its first sighting")
    w.ok(d)
    last, mem = w.last(d), w.memory()
    check(mem[rel]["status"] == "known" and mem[rel]["artifact"] == arts[rel]["id"]
          and mem[rel]["mtime_ns"] == st.st_mtime_ns + 5_000_000_000
          and last["files_known"] == 1 and last["details"]["files_read"] == 1
          and last["files_registered"] == 0, "touched file: %s %s" % (mem[rel], last))
    check(w.artifacts() == arts and corrections() == before, "a touched file changed the artifacts")
    check(q1("SELECT count(*) FROM lab.artifact_verification WHERE artifact_id = %s::uuid "
             "AND status = 'ok'", (arts[rel]["id"],)) == 2, "the file just read was not verified")
    w.ok(d)
    check(w.last(d)["details"]["files_read"] == 0, "the known file was read again")
    steady(w, d)
    w.off()


@named
def an_unattended_run_only_adds_every_hold_of_the_table():
    w = World("addonly")
    e, i = w.pair()
    s, s2 = w.subject(1), w.subject(2)
    rec = recording(w, s, "260307_101800", files=("a.rhd", "b.rhd", "settings.xml", "notes.txt"),
                    blocks=SHORT)
    folder = next(iter(rec)).rsplit("/", 1)[0]
    alone = session(w, s, "260310T090000")           # no recording in sight: registered alone
    w.ok(e, i, times=2)
    arts = w.artifacts()
    check(set(arts) == set(rec) | set(alone), "the starting state: %s" % sorted(arts))
    events = set(w.events())
    before = corrections()
    counts = table_counts()

    # A new file in a registered folder: a new artifact on the existing event.
    extra = w.write(folder + "/_manifest.json", b'{"made": "later"}')
    w.ok(i)
    check(w.memory()[extra]["status"] == "pending" and extra not in w.artifacts(),
          "a new file was registered at its first sighting")
    w.ok(i)
    now = w.artifacts()
    check(now[extra]["event"] == arts[next(iter(rec))]["event"] and set(w.events()) == events
          and w.last(i)["files_registered"] == 1, "a new file in a registered folder: %s"
          % now.get(extra))

    # Other bytes at a registered path: held, read once, nothing replaced.
    changed = folder + "/notes.txt"
    w.write(changed, b"these are other bytes")
    w.ok(i, times=2)
    mem = w.memory()[changed]
    check(mem["status"] == "held" and mem["code"] == "content_changed"
          and sha(b"these are other bytes") in mem["reason"]
          and w.last(i)["details"]["files_read"] == 1, "content_changed: %s" % mem)
    w.ok(i)
    check(w.last(i)["details"]["files_read"] == 0 and w.last(i)["files_held"] == 0,
          "a held file was read to its end again")

    # A path that differs only in case from a registered one.
    os.rename(w.abs(folder + "/settings.xml"), w.abs(folder + "/Settings.xml"))
    w.ok(i)
    mem = w.memory()
    check(mem[folder + "/Settings.xml"]["code"] == "path_case_conflict"
          and mem[folder + "/settings.xml"]["status"] == "registered",
          "case variant: %s" % mem.get(folder + "/Settings.xml"))
    check(w.last(i)["details"]["missing"]["count"] == 1, "the registered file now missing from "
          "the listing was not reported: %s" % w.last(i)["details"])

    # A file whose artifact was retracted, and one recorded as deleted: never registered again.
    retracted, deleted = folder + "/a.rhd", folder + "/b.rhd"
    conn.execute("SELECT lab.fn_retract('artifact', %s::uuid, 'entered in error (test)')",
                 (arts[retracted]["id"],))
    conn.execute("INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at) "
                 "VALUES (%s::uuid, 'deleted', now())", (arts[deleted]["id"],))
    before = (before[0], before[1], before[2] + 1, before[3] + 1)
    w.ok(i, times=3)
    mem = w.memory()
    check(mem[retracted]["code"] == "registered_but_withdrawn"
          and mem[deleted]["code"] == "registered_but_withdrawn"
          and q1("SELECT count(*) FROM lab.artifact WHERE storage_root_id = %s AND relative_path "
                 "IN (%s, %s)", (w.root_id, retracted, deleted)) == 2,
          "withdrawn files: %s %s" % (mem[retracted], mem[deleted]))
    check(w.last(i)["details"]["files_read"] == 0, "a withdrawn file was read")

    # A recording that arrives for a behavior session registered on its own.
    late = recording(w, s, "260310_090200", blocks=LONG)
    w.ok(i, times=3)
    check(statuses(w, late) == ["held"] and codes(w, late) == ["late_recording"]
          and not set(late) & set(w.artifacts()), "late recording: %s" % codes(w, late))
    w.ok(e, times=2)
    last = w.last(e)
    check(last["details"]["would_correct"]["count"] == 1 and last["groups_held"] >= 1
          and statuses(w, alone) == ["registered"],
          "the behavior session a recording arrived for: %s" % last)

    # A group whose event is there with another digest (here: an override names another
    # subject), and a new file in it.
    over = os.path.join(TMP, "over_%d.csv" % w.n)
    P.write(over, ("root,relative_path,subject_id,reason\n%s,%s,%s,a test of would_correct\n"
                   % (w.name, folder, s2)).encode())
    newer = w.write(folder + "/later.txt", b"added while the group would be corrected")
    w.ok(i, extra=["--overrides", over], times=2)
    last = w.last(i)
    check(w.memory()[newer]["code"] == "would_correct" and newer not in w.artifacts()
          and last["details"]["would_correct"]["count"] == 1,
          "would_correct: %s %s" % (w.memory()[newer], last["details"]))
    text = open(os.path.join(w.reports, sorted(n for n in os.listdir(w.reports)
                                              if n.endswith(".txt"))[-1]), encoding="utf-8").read()
    check("would be a correction" in text or "would_correct" in text, "the report: %s" % text)
    # Without the override the group is itself again and the file is added.
    w.ok(i, times=2)
    check(w.artifacts()[newer]["event"] == arts[retracted]["event"], "the hold did not end")

    # Nothing was superseded, retracted or disposed of by any of these runs, and no
    # event or session was added.
    check(corrections() == before, "an unattended run corrected something: %s, expected %s"
          % (corrections(), before))
    after = table_counts()
    for name in ("event", "recording_event", "behavior_event", "session", "retraction",
                 "artifact_disposition", "event_input", "tag_assignment", "variable_value"):
        want = counts[name] + (1 if name in ("retraction", "artifact_disposition") else 0)
        check(after[name] == want, "lab.%s has %d rows, expected %d" % (name, after[name], want))
    check(after["artifact"] == counts["artifact"] + 2, "exactly two files were added: %d"
          % (after["artifact"] - counts["artifact"]))
    steady(w, e, i)
    w.off()


def shape(w, subject):
    """The registered state of a world, without its names: for comparing two worlds."""
    def plain(text):
        return text.replace(subject, "S").replace(w.name, "R")
    sessions = dict(q("SELECT session_id::text, label FROM lab.session WHERE storage_root_id = %s",
                      (w.root_id,)))
    events = w.events()
    arts = sorted((plain(rel), a["role"], a["format"], events[a["event"]]["type"],
                   plain(sessions[a["session"]]),
                   plain(events[a["event"]]["attributes"]["import"]["path"]))
                  for rel, a in w.artifacts().items())
    memory = sorted((plain(rel), m["status"], m["code"] or "") for rel, m in w.memory().items())
    return arts, memory, len(events), len(sessions)


def pair_tree(w):
    s = w.subject()
    return s, {
        "rec": recording(w, s, "260307_101800"),
        "paired": session(w, s, "260307T101500", video=True),
        "alone": session(w, s, "260309T090000"),
        "bad_rec": {w.write("%s/%s/%s_260312_101800/a.rhd" % (I, s, s), b"not an rhd file"): None},
        "its_session": session(w, s, "260312T101500"),
    }


@named
def a_paired_session_waits_for_its_recording_in_either_search_order():
    # The ePsych directory is searched first ...
    a = World("pairs")
    ea, ia = a.pair()
    sa, fa = pair_tree(a)
    a.ok(ea, times=3)
    check(statuses(a, fa["paired"]) == ["pending"] and not set(fa["paired"]) & set(a.artifacts()),
          "a paired session was registered before its recording: %s" % a.memory())
    check(set(fa["alone"]) <= set(a.artifacts()), "a session with no recording in sight was "
          "not registered on its own")
    check(statuses(a, fa["its_session"]) == ["held"]
          and codes(a, fa["its_session"]) == ["paired_recording_held"],
          "the session of a held recording: %s" % codes(a, fa["its_session"]))
    check(a.last(ea)["groups_waiting"] == 1 and a.last(ea)["groups_held"] == 1, "group counts")
    a.ok(ia, times=2)
    check(set(fa["rec"]) <= set(a.artifacts()), "the recording was not registered")
    a.ok(ea)                 # seen unchanged long since: registered by the next run
    arts = a.artifacts()
    check(set(fa["paired"]) <= set(arts)
          and {arts[p]["session"] for p in fa["paired"]} == {arts[p]["session"] for p in fa["rec"]},
          "the paired session did not join its recording's session")
    a.ok(ea, ia)
    # ... and the Intan directory first.
    b = World("pairs")
    eb, ib = b.pair()
    sb, fb = pair_tree(b)
    b.ok(ib, times=2)
    check(set(b.artifacts()) == set(fb["rec"]), "Intan first: %s" % sorted(b.artifacts()))
    b.ok(eb)
    check(not set(fb["paired"]) & set(b.artifacts()), "registered at its first sighting")
    b.ok(eb)
    b.ok(eb, ib)
    check(shape(a, sa) == shape(b, sb), "the two search orders end differently:\n%s\n%s"
          % (shape(a, sa), shape(b, sb)))
    check(shape(a, sa)[2:] == (3, 2), "three events in two sessions: %s" % (shape(a, sa)[2:],))
    steady(a, ea, ia)
    steady(b, eb, ib)
    a.off()
    b.off()


def other_client(w, root_id, subject, files, label, role="raw"):
    """Register FILES' bytes as another client would, from a copy on another root."""
    session_id = q1("INSERT INTO lab.session (subject_id, label, storage_root_id, relative_path) "
                    "VALUES (%s, %s, %s, %s) RETURNING session_id::text",
                    (subject, label, root_id, "copies/" + label))
    event_id = q1("INSERT INTO lab.event (event_type, subject_id, session_id, occurred_at) "
                  "VALUES ('recording', %s, %s::uuid, now()) RETURNING event_id::text",
                  (subject, session_id))
    conn.execute("INSERT INTO lab.recording_event (event_id) VALUES (%s::uuid)", (event_id,))
    ids = {}
    for rel, data in files.items():
        ids[rel] = q1("INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, "
                      "relative_path, checksum, size_bytes, role) VALUES (%s::uuid, %s, %s, %s, "
                      "%s, %s) RETURNING artifact_id::text",
                      (event_id, root_id, "copies/%s/%s" % (label, rel.rsplit("/", 1)[1]),
                       sha(data), len(data), role))
    return event_id, session_id, ids


@named
def a_recording_registered_from_a_copy_gets_its_nas_files_and_no_second_event():
    w = World("copy")
    d = w.directory(I, "intan")
    local = World("local")                       # the other client's root; not mounted here
    s, s2 = w.subject(1), w.subject(2)
    one = recording(w, s, "260307_101800", blocks=SHORT)
    two = recording(w, s, "260308_101800", blocks=SHORT)
    wrong = recording(w, s, "260309_101800", blocks=SHORT)
    fresh = recording(w, s, "260310_101800", blocks=SHORT)
    ev1, sess1, theirs = other_client(w, local.root_id, s, one, "copy-one-" + TAG)
    twice = [other_client(w, local.root_id, s, two, "copy-two-%d-%s" % (k, TAG))[0]
             for k in (1, 2)]
    ev3 = other_client(w, local.root_id, s2, wrong, "copy-other-" + TAG)[0]
    counts = table_counts()
    before = corrections()
    w.ok(d, times=2)
    arts = w.artifacts()
    # One event: the NAS files are its artifacts; no event, no session of their own.
    check(set(one) <= set(arts) and {arts[p]["event"] for p in one} == {ev1}
          and {arts[p]["session"] for p in one} == {sess1}, "copy of one event: %s"
          % {p: arts.get(p, {}).get("event") for p in one})
    for rel in one:
        at = arts[rel]["attributes"]
        check(at["copy_of_event"] == ev1 and at["copied_from"] == theirs[rel]
              and re.fullmatch("[0-9a-f-]{36}", at["copy_recorded_as"])
              and at["copy_recorded_as"] != ev1 and at["kind"] == "raw"
              and at["import"]["path"] == rel.rsplit("/", 1)[0]
              and at["captured_by_tool"] == "import_nas_files", "copy attributes %s" % at)
        check(q1("SELECT count(*) FROM lab.event WHERE event_id = %s::uuid",
                 (at["copy_recorded_as"],)) == 0, "the group's own event was written as well")
    check(statuses(w, one) == ["registered"], "memory of the copy")
    # Several events: held, nothing registered, not read again.
    check(not set(two) & set(arts) and codes(w, two) == ["copy_ambiguous"]
          and all(e in w.memory()[next(iter(two))]["reason"] for e in twice),
          "several events: %s" % w.memory()[next(iter(two))])
    # The one event is another subject's: held.
    check(not set(wrong) & set(arts) and codes(w, wrong) == ["copy_event_mismatch"]
          and ev3 in w.memory()[next(iter(wrong))]["reason"], "another subject's event")
    # A recording nobody registered is registered as usual.
    check(set(fresh) <= set(arts) and arts[next(iter(fresh))]["event"] not in (ev1, ev3),
          "the ordinary recording")
    after = table_counts()
    check(after["event"] == counts["event"] + 1 and after["session"] == counts["session"] + 1
          and after["artifact"] == counts["artifact"] + len(one) + len(fresh),
          "rows added: events %d, sessions %d, artifacts %d"
          % (after["event"] - counts["event"], after["session"] - counts["session"],
             after["artifact"] - counts["artifact"]))
    w.ok(d)
    check(w.last(d)["details"]["files_read"] == 0, "held copies were read again")
    # A file added later to the copied folder goes to the same event.
    added = w.write(next(iter(one)).rsplit("/", 1)[0] + "/_manifest.json", b'{"later": 1}')
    w.ok(d, times=2)
    a = w.artifacts()[added]
    check(a["event"] == ev1 and a["attributes"]["copy_of_event"] == ev1
          and "copied_from" not in a["attributes"], "a file added to a copied folder: %s" % a)
    check(corrections() == before, "a copy corrected something")
    steady(w, d)
    w.off()
    local.off()


@named
def the_session_of_a_copied_recording_joins_the_session_of_that_recording():
    w = World("copypair")
    e, i = w.pair()
    local = World("local")
    s = w.subject()
    rec = recording(w, s, "260307_101800")
    beh = session(w, s, "260307T101500")
    ev, sess, _ids = other_client(w, local.root_id, s, rec, "copy-pair-" + TAG)
    w.ok(e, times=2)
    check(statuses(w, beh) == ["pending"], "the session did not wait for the recording's files")
    w.ok(i, times=2)
    check({a["event"] for p, a in w.artifacts().items() if p in rec} == {ev}, "the copy")
    w.ok(e)
    arts = w.artifacts()
    events = w.events()
    mine = events[arts[next(iter(beh))]["event"]]
    check(mine["type"] == "behavior" and mine["session"] == sess
          and q1("SELECT count(*) FROM lab.session WHERE storage_root_id = %s", (w.root_id,)) == 0,
          "the behavior event is not in the session of the recording's event: %s" % mine)
    w.ok(e, i)
    check(w.last(e)["details"]["would_correct"]["count"] == 0 and w.last(e)["groups_held"] == 0,
          "a later run would correct the behavior event: %s" % w.last(e))
    steady(w, e, i)
    w.off()
    local.off()


@named
def a_wall_clock_time_that_daylight_saving_skips_or_repeats_is_held():
    w = World("dst")
    e, i = w.pair()
    s, s2 = w.subject(1), w.subject(2)
    skipped = recording(w, s, "260308_023000")           # 02:30 does not exist on 2026-03-08
    its_session = session(w, s, "260308T022800")
    repeated = recording(w, s, "261101_013000", blocks=SHORT)    # 01:30 occurs twice
    fine = recording(w, s, "261101_030000", blocks=SHORT)
    lone = session(w, s2, "260308T023000")               # an unpaired session at a skipped time
    w.ok(i, e, times=3)
    arts = w.artifacts()
    check(set(arts) == set(fine), "registered %s" % sorted(arts))
    check(codes(w, skipped) == ["local_time_nonexistent"]
          and codes(w, repeated) == ["local_time_ambiguous"]
          and codes(w, lone) == ["local_time_nonexistent"],
          "held as %s, %s, %s" % (codes(w, skipped), codes(w, repeated), codes(w, lone)))
    check(codes(w, its_session) == ["paired_recording_held"],
          "the session of a recording held in the database: %s" % codes(w, its_session))
    check(w.last(i)["details"]["files_read"] == 0 and w.last(i)["groups_held"] == 2,
          "held groups were read: %s" % w.last(i))
    steady(w, e, i)
    w.off()


@named
def report_mode_remembers_and_registers_nothing_then_register_mode_registers_at_once():
    w = World("report")
    d = w.directory(I, "intan", mode="report")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    w.ok(d, times=2)
    last = w.last(d)
    check(last["mode"] == "report" and statuses(w, rec) == ["pending"] and not w.artifacts()
          and last["details"]["files_read"] == 0 and last["files_registered"] == 0
          and last["details"]["would_register"]["count"] == 1, "report mode: %s" % last)
    report = [n for n in os.listdir(w.reports) if n.endswith("run%d.txt" % last["scan_run_id"])]
    check(len(report) == 1, "no report of the run in which the group became stable")
    text = open(os.path.join(w.reports, report[0]), encoding="utf-8").read()
    check("Would be registered now (1 group(s))" in text, "the report: %s" % text)
    rows = open(os.path.join(w.reports, report[0][:-4] + ".csv"), encoding="utf-8").read()
    check(rows.startswith("what,action,root,path,group_key,reason_code,detail,size_bytes,"
                          "mtime_ns,artifact_id,event_id,until\n")
          and "group,would_register,%s," % w.name in rows, "the CSV: %s" % rows)
    n = len(os.listdir(w.reports))
    w.ok(d)
    check(len(os.listdir(w.reports)) == n, "a run in which nothing happened wrote a report")
    conn.execute("UPDATE lab.scan_directory SET mode = 'register' WHERE scan_directory_id = %s",
                 (d,))
    w.ok(d)
    check(set(w.artifacts()) == set(rec) and w.last(d)["mode"] == "register",
          "switched to register: the stable group was not registered by the next run")
    w.off()


@named
def two_processes_on_one_directory_one_skips():
    w = World("lock")
    d = w.directory(I, "intan")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    w.ok(d)
    slow = ("import time\nreal = engine.read_group\n"
            "def slowly(s, gp):\n    time.sleep(4)\n    return real(s, gp)\n"
            "engine.read_group = slowly")
    code = ("import sys; sys.path.insert(0, %r); import import_nas_files as tool; "
            "from nas_import import engine\n%s\nsys.exit(tool.main(%r))"
            % (TOOLS, slow, ["run", "--root", w.root_arg(), "--now", "--directory", str(d)]))
    first = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.time() + 20
        while time.time() < deadline and not q1(
                "SELECT count(*) FROM lab.scan_run r WHERE r.scan_directory_id = %s AND NOT EXISTS "
                "(SELECT 1 FROM lab.scan_run_result x WHERE x.scan_run_id = r.scan_run_id)", (d,)):
            time.sleep(0.1)
        runs = q1("SELECT count(*) FROM lab.scan_run WHERE scan_directory_id = %s", (d,))
        code2, out2 = w.run(d)
        check(code2 == 0 and "another process is searching it" in out2 and "1 locked" in out2,
              "the second process: %d %s" % (code2, out2))
        check(q1("SELECT count(*) FROM lab.scan_run WHERE scan_directory_id = %s", (d,)) == runs,
              "the process that skipped wrote a scan_run row")
    finally:
        out1 = first.communicate(timeout=60)[0]
    check(first.returncode == 0 and set(w.artifacts()) == set(rec),
          "the first process: %d %s" % (first.returncode, out1))
    check(q1("SELECT count(*) FROM lab.artifact WHERE storage_root_id = %s", (w.root_id,))
          == len(rec), "registered twice")
    w.off()


@named
def the_scanner_role_suffices_and_a_plain_member_is_refused():
    check(q1("SELECT count(*) FROM pg_roles WHERE rolname = 'lab_rw'") == 1,
          "apply design_docs/grants.sql to the database first (no role lab_rw)")
    scanner, member = "nasimp_%s_scanner" % TAG, "nasimp_%s_member" % TAG
    conn.execute('CREATE ROLE "%s" NOLOGIN IN ROLE lab_rw' % scanner)
    conn.execute('CREATE ROLE "%s" NOLOGIN IN ROLE lab_rw' % member)
    conn.execute('GRANT INSERT ON lab.scan_run, lab.scan_run_result, lab.scan_file TO "%s"'
                 % scanner)
    try:
        w = World("roles")
        d = w.directory(I, "intan")
        s = w.subject()
        rec = recording(w, s, "260307_101800", blocks=SHORT)
        # A member of lab_rw without the grants: refused before anything is searched.
        # Exit 2, not 1: no directory was searched and none failed -- the login is
        # misconfigured, which is of a kind with a connection that cannot be used.
        runs = q1("SELECT count(*) FROM lab.scan_run")
        code, out = w.run(d, env={"PGOPTIONS": "-c role=%s" % member})
        check(code == 2 and "may not INSERT into lab.scan_run" in out and member in out,
              "a plain member: exit %d, %s" % (code, out))
        check(q1("SELECT count(*) FROM lab.scan_run") == runs and not w.memory(),
              "a refused member wrote something")
        # The database refuses the member's INSERT whatever the tool does.
        conn.execute('SET ROLE "%s"' % member)
        for table, columns, values in (
                ("scan_file", "scan_run_id, storage_root_id, relative_path, status",
                 "1, %d, 'x/y', 'cleared'" % w.root_id),
                ("scan_run", "scan_directory_id, command, mode", "%d, 'run', 'report'" % d)):
            try:
                conn.execute("INSERT INTO lab.%s (%s) VALUES (%s)" % (table, columns, values))
                refused = False
            except psycopg.errors.InsufficientPrivilege:
                refused = True
            check(refused, "a member's INSERT into lab.%s was not refused" % table)
        conn.execute("RESET ROLE")
        # The scanner's privileges are enough for everything a run writes.
        for _ in range(2):
            code, out = w.run(d, env={"PGOPTIONS": "-c role=%s" % scanner})
            check(code == 0, "as the scanner: exit %d, %s" % (code, out))
        check(set(w.artifacts()) == set(rec), "the scanner registered %s" % sorted(w.artifacts()))
        login = q1("SELECT session_user::text")
        check(q("SELECT DISTINCT run_login FROM lab.scan_run WHERE scan_directory_id = %s", (d,))
              == [(login,)] and {ev["login"] for ev in w.events().values()} == {login},
              "the login was not stamped")
        w.off()
    finally:
        conn.execute("RESET ROLE")
        for role in (scanner, member):
            conn.execute('DROP OWNED BY "%s"' % role)
            conn.execute('DROP ROLE "%s"' % role)


@named
def check_exits_1_when_overdue_overlapping_or_a_due_root_is_not_given():
    w = World("check")
    other = World("elsewhere")
    P.write(other.abs("x/y.txt"), b"x")
    d = w.directory(I, "intan")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    log = os.path.join(TMP, "check.log")
    # Due, and its root is not among the roots given.
    code, out = tool("check", "--root", other.root_arg(), "--log-file", log)
    check(code == 1 and "is due, and its storage root %s was not given" % w.name in out,
          "a due directory without its root: %d %s" % (code, out))
    code, out = tool("check")
    check(code == 0 and "no --root given" in out, "check without roots: %d %s" % (code, out))
    code, out = tool("check", "--root", w.root_arg(), "--root", other.root_arg())
    check(code == 0, "check with the root: %d %s" % (code, out))
    # After a scheduled run: not due, nothing to say; the pending files are counted.
    runs = q1("SELECT count(*) FROM lab.scan_run")
    w.ok(d, now=False)
    code, out = tool("check", "--root", other.root_arg(), "--log-file", log)
    check(code == 0 and "import_nas_files: OK" in out
          and "%d pending, 0 held file(s)" % len(rec) in out, "check after a run: %d %s"
          % (code, out))
    check(q1("SELECT count(*) FROM lab.scan_run") == runs + 1, "check wrote a run")
    # Overdue: the row was added, and its mode last changed, ten days ago.
    conn.execute("SET session_replication_role = replica")
    conn.execute("UPDATE lab.scan_directory SET created_at = now() - interval '10 days', "
                 "mode_changed_at = now() - interval '10 days' WHERE scan_directory_id = %s", (d,))
    conn.execute("UPDATE lab.scan_run SET due_at = due_at - interval '10 days', started_at = "
                 "started_at - interval '10 days' WHERE scan_directory_id = %s", (d,))
    conn.execute("SET session_replication_role = origin")
    code, out = tool("check", "--root", w.root_arg(), "--log-file", log)
    check(code == 1 and "PROBLEM directory %d %s:%s is overdue" % (d, w.name, I) in out,
          "an overdue directory: %d %s" % (code, out))
    conn.execute("UPDATE lab.scan_directory SET mode = 'off' WHERE scan_directory_id = %s", (d,))
    code, out = tool("check", "--root", w.root_arg())
    check(code == 0, "a directory that is off is not overdue: %d %s" % (code, out))
    # Two listed directories that overlap (rows that got past the trigger).
    a = w.directory("nested", "intan")
    conn.execute("SET session_replication_role = replica")
    b = q1("INSERT INTO lab.scan_directory (storage_root_id, relative_path, layout, time_zone, "
           "scan_interval_min) VALUES (%s, 'nested/Deeper', 'intan', %s, 60) "
           "RETURNING scan_directory_id", (w.root_id, ZONE))
    conn.execute("SET session_replication_role = origin")
    code, out = tool("check", "--root", w.root_arg())
    check(code == 1 and "overlap" in out, "overlapping directories: %d %s" % (code, out))
    conn.execute("UPDATE lab.scan_directory SET mode = 'off' WHERE scan_directory_id IN (%s, %s)",
                 (a, b))
    lines = open(log, encoding="utf-8").read().splitlines()
    check(len(lines) == 3 and " ERROR check: 1 problem(s)" in lines[0] and " OK check:" in lines[1]
          and " ERROR check:" in lines[2], "the log file: %s" % lines)
    w.off()
    other.off()


@named
def every_file_on_disk_is_accounted_for():
    """registered + known + pending + held + ignored + reported = files on disk."""
    w = World("account")
    mark = "x%s%d-" % (TAG, w.n)

    def tagged(name):
        return re.sub("(?i)subj-id-", lambda m: m.group(0) + mark, name)
    P.build_tree(w.path)                      # every anomaly of the RIG3 profile
    for top, dirs, files in os.walk(w.path, topdown=False):
        for name in files:
            # The fixture repeats a few files; give each bytes of its own, as real
            # sessions have (equal raw bytes mean "a copy of that event").
            path = os.path.join(top, name)
            if os.path.islink(path):
                continue
            with open(path, "rb") as fh:
                data = bytearray(fh.read())
            salt = hashlib.sha256(("%s:%s" % (mark, path)).encode()).digest()
            if name.endswith(".mat") and len(data) >= 128 and data.startswith(b"MATLAB 5.0"):
                data[40:100] = salt.hex()[:60].encode()
            elif name.endswith(".rhd"):
                try:
                    header = rhd_module.read_header(io.BytesIO(bytes(data)), len(data))
                except Exception:
                    continue
                if len(data) - header.header_bytes < 32:
                    continue
                data[-32:] = salt
            else:
                continue
            with open(path, "wb") as fh:
                fh.write(data)
        for name in files + dirs:
            if tagged(name) != name:
                os.rename(os.path.join(top, name), os.path.join(top, tagged(name)))
    for subject in sorted(P.KNOWN):
        conn.execute("INSERT INTO lab.subject (subject_id, project_id) VALUES (%s, %s)",
                     (tagged(subject), w.project))
    e, i = w.pair()
    before = corrections()
    for _ in range(4):
        w.ok(e, i, extra=["--cache-file", w.cache])
    steady(w, e, i)
    check(corrections() == before, "the anomaly tree made a run correct something")
    for d, rel in ((e, E), (i, I)):
        on_disk = sum(len(files) for _top, _dirs, files in os.walk(w.abs(rel)))
        last = w.last(d)
        t = last["details"]["totals"]
        total = sum(t[k] for k in ("registered", "known", "pending", "held", "ignored", "reported"))
        check(last["outcome"] == "ok" and total == on_disk,
              "%s: %s adds up to %d, %d files on disk" % (rel, t, total, on_disk))
        # The same from the scan memory itself.
        remembered = dict(q("SELECT status, count(*) FROM lab.scan_file_latest WHERE "
                            "storage_root_id = %s AND starts_with(relative_path, %s) "
                            "AND status <> 'cleared' GROUP BY 1", (w.root_id, rel + "/")))
        for status in ("registered", "known", "pending", "held"):
            check(remembered.get(status, 0) == t[status], "%s: %d files %s in the memory, the "
                  "result says %d" % (rel, remembered.get(status, 0), status, t[status]))
        check(t["registered"] > 0 and t["held"] > 0 and t["ignored"] > 0, "%s: %s" % (rel, t))
        check(t["registered"] + t["known"] == q1(
            "SELECT count(*) FROM lab.artifact_present WHERE storage_root_id = %s "
            "AND starts_with(relative_path, %s)", (w.root_id, rel + "/")),
            "%s: registered files and present artifacts differ" % rel)
    for rel, a in w.artifacts().items():
        check(a["size"] == os.path.getsize(w.abs(rel)), "size of %s" % rel)
    check(not q("SELECT 1 FROM lab.fn_check_integrity() c JOIN lab.artifact a ON "
                "a.artifact_id::text = c.subject WHERE a.storage_root_id = %s "
                "AND c.check_name IN ('artifact_never_verified', 'artifact_event_mismatch', "
                "'artifact_verification_failed')", (w.root_id,)), "the integrity report names "
          "files this run registered")
    w.off()


@named
def files_of_a_subject_not_yet_in_the_database_register_once_it_is():
    w = World("unknown")
    d = w.directory(I, "intan")
    s = w.subject(create=False)
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    w.ok(d, times=3)
    check(not w.artifacts() and statuses(w, rec) in (["held"], ["none"]),
          "files of an unknown subject: %s" % statuses(w, rec))
    w.subject()
    w.ok(d, times=3)
    check(set(w.artifacts()) == set(rec) and statuses(w, rec) == ["registered"],
          "not registered once the subject exists: %s" % w.memory())
    w.off()


@named
def an_override_names_the_subject_of_a_mislabelled_folder():
    w = World("override")
    d = w.directory(I, "intan")
    s, s2 = w.subject(1), w.subject(2)
    rec = recording(w, s, "260709_095155", blocks=SHORT, subject_folder=s2)
    folder = next(iter(rec)).rsplit("/", 1)[0]
    w.ok(d, times=2)
    check(not w.artifacts() and codes(w, rec) == ["subject_mismatch"], "mislabelled: %s"
          % codes(w, rec))
    over = os.path.join(TMP, "over_%d.csv" % w.n)
    P.write(over, ("root,relative_path,subject_id,reason\n%s,%s,%s,the folder is right\n"
                   % (w.name, folder, s2)).encode())
    w.ok(d, extra=["--overrides", over], times=2)
    arts, events = w.artifacts(), w.events()
    check(set(arts) == set(rec) and {a["subject"] for a in arts.values()} == {s2},
          "with the override: %s" % sorted(arts))
    (ev,) = events.values()
    check(ev["subject"] == s2 and ev["attributes"]["import"]["override"]
          == {"subject_id": s2, "reason": "the folder is right"}, "the override on the event")
    w.off()


@named
def a_dry_run_writes_nothing():
    w = World("dry")
    d = w.directory(I, "intan")
    s = w.subject()
    recording(w, s, "260307_101800", blocks=SHORT)
    w.ok(d)
    counts = table_counts()
    cache = os.path.join(TMP, "dry_cache.json")
    reports = len(os.listdir(w.reports))
    code, out = w.run(d, extra=["--dry-run", "--cache-file", cache])
    check(code == 0 and "Would be registered now (1 group(s))" in out and "dry run" in out,
          "dry run: %d %s" % (code, out))
    check(table_counts() == counts, "a dry run wrote to the database")
    check(not os.path.exists(cache) and len(os.listdir(w.reports)) == reports,
          "a dry run wrote a cache or a report")
    w.off()


@named
def a_lost_connection_leaves_no_group_half_written():
    w = World("lost")
    d = w.directory(I, "intan")
    s = w.subject()
    one = recording(w, s, "260307_101800", blocks=SHORT)
    two = recording(w, s, "260308_101800", blocks=SHORT)
    w.ok(d)
    cut = ("real = engine.read_group\n"
           "def cut(s, gp):\n"
           "    out = real(s, gp)\n"
           "    if not getattr(cut, 'done', False):\n"
           "        cut.done = True\n"
           "        import psycopg\n"
           "        with psycopg.connect(autocommit=True) as c:\n"
           "            c.execute(\"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE \"\n"
           "                      \"application_name = 'import_nas_files' AND datname = \"\n"
           "                      \"current_database() AND pid <> pg_backend_pid()\")\n"
           "    return out\n"
           "engine.read_group = cut")
    code, out = w.run(d, patch=cut)
    last = w.last(d)
    arts = w.artifacts()
    check(code == 1 and last["outcome"] == "failed" and "could not be registered" in last["message"],
          "a lost connection: exit %d, %s, %s" % (code, last, out))
    check(set(arts) == set(two) and len(w.events()) == 1
          and q1("SELECT count(*) FROM lab.session WHERE storage_root_id = %s", (w.root_id,)) == 1,
          "after the connection was lost: %s" % sorted(arts))
    check(statuses(w, one) == ["pending"], "the interrupted group's memory: %s" % statuses(w, one))
    w.ok(d)
    check(set(w.artifacts()) == set(one) | set(two), "the interrupted group was not registered "
          "by the next run")
    w.off()


@named
def the_window_closing_ends_the_run_partial_and_the_next_run_goes_on():
    w = World("window")
    d = w.directory(I, "intan")
    s = w.subject()
    one = recording(w, s, "260307_101800", blocks=SHORT)
    two = recording(w, s, "260308_101800", blocks=SHORT)
    w.ok(d)                                   # by hand: the schedule does not move
    closes = ("calls = []\n"
              "def window_open(self, directory_id):\n"
              "    calls.append(directory_id)\n"
              "    return len(calls) == 1\n"
              "database.Database.window_open = window_open")
    code, out = w.run(d, now=False, patch=closes)
    last = w.last(d)
    check(code == 0 and last["outcome"] == "partial" and last["groups_registered"] == 1
          and set(w.artifacts()) == set(one), "the window closed: %d %s %s" % (code, last, out))
    check(q1("SELECT is_due FROM lab.scan_directory_status WHERE scan_directory_id = %s", (d,)),
          "after a partial run the directory is not due at once")
    w.ok(d, now=False)
    check(set(w.artifacts()) == set(one) | set(two) and w.last(d)["outcome"] == "ok",
          "the rest was not done at the next run")
    w.off()


@named
def a_damaged_mat_file_holds_its_group_before_any_row_is_written():
    w = World("damaged")
    d = w.directory(E, "epsych")
    s = w.subject()
    bad = session(w, s, "260307T101500", suffixes=("", "psych"))
    good = session(w, s, "260308T101500")
    w.ok(d)
    damaged = next(p for p in sorted(bad) if p.endswith("_psych.mat"))
    code, out = w.run(d, patch=(
        "real = mat5.verify_file\n"
        "def verify_file(fh, size):\n"
        "    if fh.name.endswith('_psych.mat'):\n"
        "        raise mat5.MatProblem('mat_corrupt', 'a damaged variable (made by the test)')\n"
        "    return real(fh, size)\n"
        "mat5.verify_file = verify_file"))
    check(code == 0, "a damaged file: %d %s" % (code, out))
    mem = w.memory()
    check(set(w.artifacts()) == set(good) and codes(w, bad) == ["mat_corrupt"]
          and all("[read: sha256=" in mem[p]["reason"] for p in bad)
          and damaged.rsplit("/", 1)[1] in mem[damaged]["reason"],
          "the damaged session: %s" % {p: mem[p] for p in bad})
    check(q1("SELECT count(*) FROM lab.event e JOIN lab.artifact a ON a.produced_by_event_id = "
             "e.event_id WHERE a.storage_root_id = %s", (w.root_id,)) == 1, "an event was written")
    w.ok(d)                                   # read once: the hold stands, nothing is read again
    check(w.last(d)["details"]["files_read"] == 0 and codes(w, bad) == ["mat_corrupt"],
          "a file held after it was read was read again")
    w.off()


@named
def a_file_that_changes_while_it_is_read_is_not_registered_and_waits_again():
    w = World("changing")
    d = w.directory(I, "intan")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    w.ok(d)
    touch = ("import os\nreal = engine.read_file\n"
             "def read_file(root_path, f, verify, stats):\n"
             "    if f.path.endswith('.rhd'):\n"
             "        p = content.absolute_path(root_path, f.path)\n"
             "        st = os.stat(p)\n"
             "        os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns + 7_000_000_000))\n"
             "    return real(root_path, f, verify, stats)\n"
             "engine.read_file = read_file")
    rel = next(p for p in rec if p.endswith(".rhd"))
    listed = w.memory()[rel]["mtime_ns"]
    code, out = w.run(d, patch=touch)
    mem = w.memory()[rel]
    check(code == 0 and not w.artifacts() and mem["status"] == "pending"
          and mem["mtime_ns"] == listed + 7_000_000_000 and w.last(d)["files_pending"] == 1,
          "a file changed while read: %d %s %s" % (code, mem, out))
    w.ok(d)
    check(set(w.artifacts()) == set(rec), "not registered once it was seen unchanged")
    w.off()


@named
def a_session_another_session_stands_in_the_way_of_is_held():
    w = World("session")
    d = w.directory(I, "intan")
    s = w.subject()
    label = recording(w, s, "260307_101800", blocks=SHORT)
    path = recording(w, s, "260308_101800", blocks=SHORT)
    case = recording(w, s, "260309_101800", blocks=SHORT)
    conn.execute("INSERT INTO lab.session (subject_id, label, storage_root_id, relative_path) "
                 "VALUES (%s, %s, %s, %s)", (s, "%s_260307_101800" % s, w.root_id, "elsewhere/a"))
    conn.execute("INSERT INTO lab.session (subject_id, label, storage_root_id, relative_path) "
                 "VALUES (%s, %s, %s, %s)",
                 (s, "another label", w.root_id, next(iter(path)).rsplit("/", 1)[0]))
    conn.execute("INSERT INTO lab.session (subject_id, label, storage_root_id, relative_path) "
                 "VALUES (%s, %s, %s, %s)",
                 (s, "a third label", w.root_id, next(iter(case)).rsplit("/", 1)[0].upper()))
    sessions = q1("SELECT count(*) FROM lab.session")
    w.ok(d, times=3)
    check(not w.artifacts() and codes(w, label) == ["session_conflict"]
          and codes(w, path) == ["session_conflict"] and codes(w, case) == ["path_case_conflict"],
          "sessions in the way: %s %s %s" % (codes(w, label), codes(w, path), codes(w, case)))
    check(q1("SELECT count(*) FROM lab.session") == sessions
          and w.last(d)["details"]["files_read"] == 0, "a session was written or a file read")
    w.off()


@named
def two_listed_paths_that_differ_only_in_case_are_held():
    w = World("case")
    d = w.directory(I, "intan")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    folder = next(iter(rec)).rsplit("/", 1)[0]
    w.write(folder + "/notes.txt", b"lower")
    w.write(folder + "/Notes.txt", b"upper")
    if sorted(n for n in os.listdir(w.abs(folder)) if n.lower() == "notes.txt") != ["Notes.txt",
                                                                                   "notes.txt"]:
        print("    (skipped: this file system does not tell notes.txt from Notes.txt)")
        w.off()
        return
    w.ok(d, times=3)
    mem = w.memory()
    check({mem[folder + "/notes.txt"]["code"], mem[folder + "/Notes.txt"]["code"]}
          <= {"path_case_conflict", "name_case_conflict"}, "case twins: %s, %s"
          % (mem[folder + "/notes.txt"], mem[folder + "/Notes.txt"]))
    check(not {folder + "/notes.txt", folder + "/Notes.txt"} & set(w.artifacts()),
          "a case twin was registered")
    w.off()


@named
def a_corrected_artifact_row_is_followed_and_a_group_held_later_keeps_its_registered_files():
    w = World("followed")
    d = w.directory(I, "intan")
    s = w.subject()
    rec = recording(w, s, "260307_101800", blocks=SHORT)
    folder = next(iter(rec)).rsplit("/", 1)[0]
    w.ok(d, times=2)
    arts = w.artifacts()
    rel = folder + "/settings.xml"
    # A person corrects the row's metadata: a new row for the same file.
    newer = q1("INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, "
               "checksum, size_bytes, role, format, subject_id, session_id, supersedes) "
               "SELECT produced_by_event_id, storage_root_id, relative_path, checksum, "
               "size_bytes, 'other', format, subject_id, session_id, artifact_id "
               "FROM lab.artifact WHERE artifact_id = %s::uuid RETURNING artifact_id::text",
               (arts[rel]["id"],))
    n = q1("SELECT count(*) FROM lab.artifact")
    w.ok(d)
    mem = w.memory()[rel]
    check(mem["status"] == "registered" and mem["artifact"] == newer
          and w.last(d)["details"]["files_read"] == 0 and q1("SELECT count(*) FROM lab.artifact")
          == n, "a corrected artifact row: %s" % mem)
    steady(w, d)
    # The folder gets a file that makes the whole recording unreadable as one: the group
    # is held, and what is registered stays registered.
    bad = w.write(folder + "/b.rhd", P.rhd_file(SHORT, fs=FS, n_amp=N_AMP + 1))
    w.ok(d, times=3)
    mem = w.memory()
    check(mem[bad]["status"] == "held" and mem[bad]["code"] == "rhd_header_mismatch"
          and statuses(w, rec) == ["registered"] and w.last(d)["groups_held"] == 1
          and q1("SELECT count(*) FROM lab.artifact") == n, "a group held later: %s" % mem[bad])
    steady(w, d)
    w.off()


@named
def a_partner_that_is_off_is_not_judged_and_two_partners_are_refused():
    w = World("partners")
    e, i = w.pair()
    s = w.subject()
    recording(w, s, "260307_101800")
    beh = session(w, s, "260307T101500")
    # Two directories naming the same one: the run fails and says so.
    second = w.directory("intan_two/Data", "intan", pair_with=e)
    P.write(w.abs("intan_two/Data/x.txt"), b"x")
    code, out = w.run(e)
    last = w.last(e)
    check(code == 1 and last["outcome"] == "failed" and "all pair with" in last["message"]
          and not w.memory(), "two partners: %d %s" % (code, out))
    conn.execute("UPDATE lab.scan_directory SET mode = 'off' WHERE scan_directory_id = %s",
                 (second,))
    w.ok(e, times=2)
    check(statuses(w, beh) == ["pending"], "the session did not wait for its recording")
    # The administrator turns the recordings' directory off: it is no longer in sight.
    conn.execute("UPDATE lab.scan_directory SET mode = 'off' WHERE scan_directory_id = %s", (i,))
    w.ok(e, times=2)
    check(set(w.artifacts()) == set(beh), "with its partner off: %s" % sorted(w.artifacts()))
    w.off()


def main():
    leftovers = q1("WITH u AS (UPDATE lab.scan_directory d SET mode = 'off' FROM lab.storage_root r "
                   "WHERE r.root_id = d.storage_root_id AND r.name LIKE %s AND d.mode <> 'off' "
                   "RETURNING 1) SELECT count(*) FROM u", (PREFIX + "%",))
    if leftovers:
        print("turned off %d directory row(s) left by an earlier run" % leftovers)
    only = sys.argv[1:]
    ran = 0
    try:
        for fn in CHECKS:
            if only and not any(o in fn.__name__ for o in only):
                continue
            started = time.time()
            fn()
            ran += 1
            print("ok  %-70s %5.1f s" % (fn.__name__, time.time() - started))
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    conn.close()
    print("%d checks, %d assertions" % (ran, N_ASSERTS))
    print("check_import_nas_files: OK")


if __name__ == "__main__":
    main()
