#!/usr/bin/env python3
"""End-to-end check of tools/verify_artifacts.py against a scratch database.

Run against a database that has schema.sql applied and that this check may
write to (it commits rows; use a throw-away database):

    createdb lab_verify && psql -X -q -d lab_verify -f design_docs/schema.sql
    PGDATABASE=lab_verify python tests/check_verify_artifacts.py

Registers six files -- one intact, one with a wrong checksum, one that does
not exist, one on a storage root that is not mounted, one whose artifact
row has been corrected, and one recorded as deleted (lab.artifact_disposition)
-- runs the verifier, and checks what it recorded and
what lab.fn_check_integrity() then reports. Exits non-zero on the first
problem.
"""
import hashlib
import os
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFIER = os.path.join(HERE, "..", "tools", "verify_artifacts.py")


def fail(msg):
    sys.exit("check_verify_artifacts: " + msg)


def connect():
    try:
        import psycopg
        return psycopg.connect(autocommit=True)
    except ImportError:
        import psycopg2
        conn = psycopg2.connect("")
        conn.autocommit = True
        return conn


def run(*args):
    proc = subprocess.run([sys.executable, VERIFIER, *args],
                          capture_output=True, text=True, encoding="utf-8")
    return proc.returncode, proc.stdout + proc.stderr


def digest(algo, data):
    return hashlib.new(algo, data).hexdigest()


conn = connect()
cur = conn.cursor()
tag = uuid.uuid4().hex[:8]          # keeps reruns on one database apart
mounted, unmounted = "verify-" + tag, "offline-" + tag

cur.execute("INSERT INTO lab.project (name) VALUES (%s) RETURNING project_id", ("verify-" + tag,))
project_id = cur.fetchone()[0]
cur.execute("INSERT INTO lab.storage_root (name) VALUES (%s), (%s)", (mounted, unmounted))
cur.execute("SELECT name, root_id FROM lab.storage_root WHERE name IN (%s, %s)",
            (mounted, unmounted))
root_id = dict(cur.fetchall())
subject = "V-" + tag
cur.execute("INSERT INTO lab.subject (subject_id, project_id) VALUES (%s, %s)",
            (subject, project_id))
cur.execute("INSERT INTO lab.event (event_type, subject_id, occurred_at) "
            "VALUES ('husbandry', %s, now()) RETURNING event_id", (subject,))
event_id = cur.fetchone()[0]
cur.execute("INSERT INTO lab.husbandry_event (event_id, measure) VALUES (%s, 'weight')",
            (event_id,))

contents = {"good.dat": b"intact file\n", "bad.dat": b"this content changed\n",
            "fixed.dat": b"corrected metadata, same bytes\n", "offline.dat": b"elsewhere\n"}


def register(name, root, algo, checksum, supersedes=None, role=None):
    cur.execute(
        "INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, "
        "checksum, checksum_algo, role, supersedes) VALUES (%s, %s, %s, %s, %s, %s, %s) "
        "RETURNING artifact_id::text",
        (event_id, root_id[root], subject + "/" + name, checksum, algo, role, supersedes))
    return cur.fetchone()[0]


good = register("good.dat", mounted, "sha256", digest("sha256", contents["good.dat"]))
# Registered with the checksum of other bytes: the file on disk will not match.
bad = register("bad.dat", mounted, "md5", digest("md5", b"what was registered\n"))
gone = register("gone.dat", mounted, "sha256", digest("sha256", b"never written\n"))
offline = register("offline.dat", unmounted, "sha256", digest("sha256", contents["offline.dat"]))
fixed_old = register("fixed.dat", mounted, "sha256", digest("sha256", contents["fixed.dat"]),
                     role="raw")
fixed = register("fixed.dat", mounted, "sha256", digest("sha256", contents["fixed.dat"]),
                 supersedes=fixed_old, role="derived")
# Recorded as deleted: not on disk, and not to be checked or reported.
deleted = register("deleted.dat", mounted, "sha256", digest("sha256", b"cleaned up\n"))
cur.execute("INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at) "
            "VALUES (%s, 'deleted', now())", (deleted,))

with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as empty:
    os.makedirs(os.path.join(tmp, subject))
    for name in ("good.dat", "bad.dat", "fixed.dat"):
        with open(os.path.join(tmp, subject, name), "wb") as fh:
            fh.write(contents[name])
    root_arg = "%s=%s" % (mounted, tmp)

    # An empty directory is what an unmounted share looks like: refused.
    code, out = run("--root", "%s=%s" % (mounted, empty))
    if code != 2 or "is empty" not in out:
        fail("an empty root was not refused (exit %d): %s" % (code, out))
    code, out = run("--root", "no-such-root-%s=%s" % (tag, tmp))
    if code != 2 or "no such storage root" not in out:
        fail("an unknown storage root was not refused (exit %d): %s" % (code, out))

    # A dry run reports and records nothing.
    code, out = run("--root", root_arg, "--dry-run")
    if code != 1 or "1 mismatch, 1 missing" not in out:
        fail("dry run: exit %d, output: %s" % (code, out))
    cur.execute("SELECT count(*) FROM lab.artifact_verification v JOIN lab.artifact a "
                "USING (artifact_id) WHERE a.produced_by_event_id = %s", (event_id,))
    if cur.fetchone()[0] != 0:
        fail("the dry run wrote verification rows")

    code, out = run("--root", root_arg)
    if code != 1:
        fail("expected exit status 1 (a mismatch and a missing file), got %d: %s" % (code, out))
    if "checked 4 file(s): 2 ok, 1 mismatch, 1 missing" not in out:
        fail("unexpected summary: %s" % out)

    cur.execute("SELECT v.artifact_id::text, v.status, v.observed_checksum, v.verified_login "
                "FROM lab.artifact_verification v JOIN lab.artifact a USING (artifact_id) "
                "WHERE a.produced_by_event_id = %s", (event_id,))
    rows = {r[0]: r[1:] for r in cur.fetchall()}
    expected = {
        good: ("ok", digest("sha256", contents["good.dat"])),
        bad: ("mismatch", digest("md5", contents["bad.dat"])),
        gone: ("missing", None),
        fixed: ("ok", digest("sha256", contents["fixed.dat"])),
    }
    if set(rows) != set(expected):
        fail("verified %s, expected %s" % (sorted(rows), sorted(expected)))
    for artifact_id, (status, observed) in expected.items():
        if rows[artifact_id][:2] != (status, observed):
            fail("%s recorded %r, expected %r" % (artifact_id, rows[artifact_id][:2],
                                                  (status, observed)))
        if not rows[artifact_id][2]:
            fail("verified_login was not stamped on %s" % artifact_id)

    cur.execute("SELECT check_name, subject FROM lab.fn_check_integrity() "
                "WHERE check_name IN ('artifact_verification_failed', 'artifact_never_verified') "
                "AND subject = ANY (%s)", ([good, bad, gone, offline, fixed, fixed_old, deleted],))
    report = sorted(cur.fetchall())
    want = sorted([("artifact_verification_failed", bad), ("artifact_verification_failed", gone),
                   ("artifact_never_verified", offline)])
    if report != want:
        fail("integrity report is %s, expected %s" % (report, want))

    # Everything on the mounted root was just checked: nothing is due.
    code, out = run("--root", root_arg, "--older-than-days", "1")
    if code != 0 or "checked 0 file(s)" not in out:
        fail("--older-than-days re-checked fresh files (exit %d): %s" % (code, out))

    # Repair the bad file's content to what was registered: the next run clears it.
    with open(os.path.join(tmp, subject, "bad.dat"), "wb") as fh:
        fh.write(b"what was registered\n")
    code, out = run("--root", root_arg, "--limit", "100")
    cur.execute("SELECT status FROM lab.artifact_verification_latest WHERE artifact_id = %s",
                (bad,))
    if cur.fetchone()[0] != "ok":
        fail("a later ok check did not become the file's latest verification: %s" % out)

conn.close()
print("check_verify_artifacts: OK")
