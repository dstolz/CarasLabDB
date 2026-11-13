#!/usr/bin/env python3
"""Check that web/live/lab_data.sql emits the JSON the dashboard reads.

Two passes, both exiting non-zero on the first problem:

1. Through the live server's own data path (server.fetch_lab_data), against
   whatever rows the database holds: every collection is present, and every
   row of every collection has exactly the keys the page uses, with
   timestamps in the form it parses.
2. Through ``psql``, against a known fixture inserted and rolled back in the
   same transaction as the export, so the result does not depend on what the
   database happens to contain (an empty table makes pass 1 vacuous). The
   fixture has a corrected event, a corrected artifact with a verification,
   a provenance edge and a tag, and the values that come back are compared
   with the ones that went in. Nothing is left behind. It needs ``psql`` on
   PATH and a role that may insert; ``--no-fixture`` skips it.

    PGDATABASE=lab_test python tests/check_lab_data.py
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "web", "live"))
import server  # noqa: E402

# The keys of one row of each collection. This is the contract between
# lab_data.sql and web/lab-dashboard.html: a key renamed or dropped in the SQL
# does not make the page fail, it makes it show something else (no
# `supersedes` and every corrected row counts as current; no `size_bytes` and
# every total is zero), so the comparison is exact in both directions.
ROW_KEYS = {
    "people": {"person_id", "full_name", "email", "role", "is_active"},
    "probes": {"probe_id", "manufacturer", "model", "n_channels", "description"},
    "pipelines": {"pipeline_id", "name", "description", "repo_url"},
    "storageRoots": {"root_id", "name", "description"},
    "species": {"code", "common_name"},
    "projects": {"project_id", "name", "description", "started_on", "is_active",
                 "created_by"},
    "projectMembers": {"project_id", "person_id", "role"},
    "projectArtifacts": {"project_artifact_id", "project_id", "title", "kind",
                         "content_type", "uri", "storage_root_id", "relative_path",
                         "description", "created_at", "created_by"},
    "subjects": {"subject_id", "project_id", "species_code", "sex", "strain",
                 "genotype", "source", "date_of_birth", "notes", "created_at",
                 "created_by"},
    "sessions": {"session_id", "subject_id", "label", "storage_root_id",
                 "relative_path", "started_at", "ended_at", "rig", "notes",
                 "created_by"},
    "events": {"event_id", "event_type", "subject_id", "session_id", "occurred_at",
               "recorded_at", "recorded_by", "recorded_login", "supersedes", "notes",
               "detail"},
    "artifacts": {"artifact_id", "produced_by_event_id", "storage_root_id",
                  "relative_path", "checksum", "checksum_algo", "size_bytes", "role",
                  "format", "subject_id", "session_id", "supersedes", "created_at",
                  "created_by", "created_login", "verification"},
    "eventInputs": {"event_id", "artifact_id", "role"},
    "eventTypeMeta": {"code", "label"},
    "tagNamespaces": {"namespace", "description", "mutability", "cardinality",
                      "open_vocabulary", "applies_to", "created_at", "created_by"},
    "tags": {"tag", "namespace", "value", "description", "retired_at", "created_at",
             "created_by"},
    "tagAssignments": {"assignment_id", "entity_kind", "entity_id", "tag", "op", "note",
                       "applied_at", "applied_by"},
}
ARRAYS = tuple(ROW_KEYS) + ("roleMeta",)
VERIFICATION_KEYS = {"status", "verified_at", "verified_artifact_id"}

# collection -> {timestamp key: may it be null}
TIMESTAMPS = {
    "projectArtifacts": {"created_at": False},
    "subjects": {"created_at": False},
    "sessions": {"started_at": True, "ended_at": True},
    "events": {"occurred_at": False, "recorded_at": False},
    "artifacts": {"created_at": False},
    "tagNamespaces": {"created_at": False},
    "tags": {"retired_at": True, "created_at": False},
    "tagAssignments": {"applied_at": False},
}
# UTC ISO-8601 with a literal Z, the one form the page compares as text.
TS = re.compile(r"^\d{4,}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?Z$")
# These two order rows in the page, so they must keep their microseconds.
TS_MICRO = re.compile(r"^\d{4,}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$")
MICROSECOND_KEYS = {("events", "occurred_at"), ("tagAssignments", "applied_at")}


def fail(msg):
    sys.exit("check_lab_data: " + msg)


def check_shape(data, source):
    """The checks that hold for any database contents."""
    def bad(msg):
        fail("[%s] %s" % (source, msg))

    expected = set(ARRAYS) | {"NOW"}
    if set(data) != expected:
        bad("keys differ: missing %s, extra %s"
            % (sorted(expected - set(data)), sorted(set(data) - expected)))
    for key in ARRAYS:
        if not isinstance(data[key], list):
            bad("%s is not an array" % key)
    if isinstance(data["NOW"], bool) or not isinstance(data["NOW"], (int, float)):
        bad("NOW is not a number")
    if not all(isinstance(r, str) for r in data["roleMeta"]):
        bad("roleMeta is not an array of strings")

    for name, keys in ROW_KEYS.items():
        for i, row in enumerate(data[name]):
            if not isinstance(row, dict):
                bad("%s[%d] is not an object" % (name, i))
            if set(row) != keys:
                bad("%s[%d] keys differ: missing %s, extra %s"
                    % (name, i, sorted(keys - set(row)), sorted(set(row) - keys)))
            for ts_key, nullable in TIMESTAMPS.get(name, {}).items():
                value = row[ts_key]
                if value is None and nullable:
                    continue
                pattern = TS_MICRO if (name, ts_key) in MICROSECOND_KEYS else TS
                if not isinstance(value, str) or not pattern.match(value):
                    bad("%s[%d].%s is %r, not a UTC ISO-8601 '...Z' timestamp%s"
                        % (name, i, ts_key, value,
                           " with microseconds" if pattern is TS_MICRO else ""))

    for e in data["events"]:
        if not isinstance(e["detail"], dict):
            bad("event %s has no detail object" % e["event_id"])
        if e["supersedes"] is not None and not isinstance(e["supersedes"], str):
            bad("event %s supersedes is not an id" % e["event_id"])
    for a in data["artifacts"]:
        size = a["size_bytes"]
        if size is not None and (isinstance(size, bool) or not isinstance(size, int)):
            bad("artifact %s size_bytes is %r, not an integer" % (a["artifact_id"], size))
        if a["supersedes"] is not None and not isinstance(a["supersedes"], str):
            bad("artifact %s supersedes is not an id" % a["artifact_id"])
        v = a["verification"]
        if not isinstance(v, dict) or set(v) != VERIFICATION_KEYS:
            bad("artifact %s verification is %r" % (a["artifact_id"], v))
        if v["status"] not in ("ok", "missing", "mismatch", "unverified"):
            bad("artifact %s verification status is %r" % (a["artifact_id"], v["status"]))
        if (v["status"] == "unverified") != (v["verified_at"] is None):
            bad("artifact %s: status %r with verified_at %r"
                % (a["artifact_id"], v["status"], v["verified_at"]))
        if v["verified_at"] is not None and not TS.match(str(v["verified_at"])):
            bad("artifact %s verified_at is not UTC ISO-8601" % a["artifact_id"])
    for n in data["tagNamespaces"]:
        if not isinstance(n["applies_to"], list):
            bad("tag namespace %s applies_to is not an array" % n["namespace"])
    for r in data["tagAssignments"]:
        if isinstance(r["assignment_id"], bool) or not isinstance(r["assignment_id"], int):
            bad("tag assignment %r has no integer assignment_id" % r["assignment_id"])
        if not isinstance(r["entity_id"], str) or r["op"] not in ("add", "remove"):
            bad("tag assignment %s has no entity_id or a bad op" % r["assignment_id"])
        if not isinstance(r["tag"], str) or ":" not in r["tag"]:
            bad("tag assignment %s tag is %r" % (r["assignment_id"], r["tag"]))


# --------------------------------------------------------------------------
# Pass 2: a known fixture, inserted and rolled back around the export.
# --------------------------------------------------------------------------
FX_SUBJECT = "CHECK-LAB-DATA-FIXTURE"
FX_PATH = "check_lab_data/s1/raw.dat"
FX_OCCURRED = "2020-01-02T03:04:05.123456Z"
FX_SIZE = 12345
FIXTURE = r"""
DO $fx$
DECLARE
    proj uuid; root smallint; sess uuid;
    e1 uuid; e2 uuid; a1 uuid; a2 uuid; an uuid;
BEGIN
    INSERT INTO lab.project (name) VALUES ('check_lab_data ' || gen_random_uuid())
        RETURNING project_id INTO proj;
    INSERT INTO lab.storage_root (name) VALUES ('check_lab_data-' || gen_random_uuid())
        RETURNING root_id INTO root;
    INSERT INTO lab.subject (subject_id, project_id) VALUES ('%(subject)s', proj);
    INSERT INTO lab.session (subject_id, label, storage_root_id, relative_path)
        VALUES ('%(subject)s', 's1', root, 'check_lab_data/s1') RETURNING session_id INTO sess;
    -- a recording, its file, and one integrity check of that file
    INSERT INTO lab.event (event_type, session_id, occurred_at)
        VALUES ('recording', sess, '%(occurred)s') RETURNING event_id INTO e1;
    INSERT INTO lab.recording_event (event_id, sample_rate_hz) VALUES (e1, 30000);
    INSERT INTO lab.artifact (produced_by_event_id, session_id, storage_root_id,
                              relative_path, checksum, size_bytes, role)
        VALUES (e1, sess, root, '%(path)s', repeat('ab', 32), %(size)d, 'raw')
        RETURNING artifact_id INTO a1;
    INSERT INTO lab.artifact_verification (artifact_id, status) VALUES (a1, 'ok');
    -- the event corrected, and its file re-pointed at the correction
    INSERT INTO lab.event (event_type, session_id, occurred_at, supersedes)
        VALUES ('recording', sess, '%(occurred)s', e1) RETURNING event_id INTO e2;
    INSERT INTO lab.recording_event (event_id, sample_rate_hz) VALUES (e2, 24414.0625);
    INSERT INTO lab.artifact (produced_by_event_id, session_id, storage_root_id,
                              relative_path, checksum, size_bytes, role, supersedes)
        VALUES (e2, sess, root, '%(path)s', repeat('ab', 32), %(size)d, 'raw', a1)
        RETURNING artifact_id INTO a2;
    -- an analysis that consumed the file, and a tag on it
    INSERT INTO lab.event (event_type, occurred_at)
        VALUES ('analysis', '2020-01-03T00:00:00Z') RETURNING event_id INTO an;
    INSERT INTO lab.analysis_event (event_id, status) VALUES (an, 'succeeded');
    INSERT INTO lab.event_input (event_id, artifact_id, role) VALUES (an, a2, 'raw');
    PERFORM lab.fn_tag('artifact', a2::text, 'stage:raw');
END
$fx$;
""" % {"subject": FX_SUBJECT, "path": FX_PATH, "occurred": FX_OCCURRED, "size": FX_SIZE}


def export_with_fixture():
    env = dict(os.environ)
    env.setdefault("PGDATABASE", "lab")
    env["PGTZ"] = server.SESSION_TIME_ZONE
    env["PGCLIENTENCODING"] = "UTF8"
    script = "BEGIN;\n" + FIXTURE + server.SQL.rstrip() + "\nROLLBACK;\n"
    proc = subprocess.run(["psql", "-tAXq", "-v", "ON_ERROR_STOP=1"], input=script,
                          capture_output=True, text=True, encoding="utf-8", env=env)
    if proc.returncode != 0:
        fail("[fixture] psql failed: " + (proc.stderr.strip() or "no message"))
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if not lines:
        fail("[fixture] psql returned no rows")
    return json.loads(lines[-1])


def check_fixture(data):
    def bad(msg):
        fail("[fixture] " + msg)

    if not any(s["subject_id"] == FX_SUBJECT for s in data["subjects"]):
        bad("the fixture subject is not in subjects")
    sessions = [s for s in data["sessions"] if s["subject_id"] == FX_SUBJECT]
    if len(sessions) != 1:
        bad("expected 1 fixture session, found %d" % len(sessions))

    recs = [e for e in data["events"] if e["subject_id"] == FX_SUBJECT]
    if len(recs) != 2 or any(e["event_type"] != "recording" for e in recs):
        bad("expected the 2 fixture recording events, found %d" % len(recs))
    new = [e for e in recs if e["supersedes"] is not None]
    old = [e for e in recs if e["supersedes"] is None]
    if len(new) != 1 or len(old) != 1 or new[0]["supersedes"] != old[0]["event_id"]:
        bad("the correction's supersedes link is not exported: %r"
            % [e["supersedes"] for e in recs])
    for e in recs:
        if e["occurred_at"] != FX_OCCURRED:
            bad("occurred_at came back as %r, sent %r" % (e["occurred_at"], FX_OCCURRED))
        if e["session_id"] != sessions[0]["session_id"]:
            bad("event %s lost its session" % e["event_id"])
    rates = sorted(float(e["detail"].get("sample_rate_hz") or 0) for e in recs)
    if rates != [24414.0625, 30000.0]:
        bad("detail.sample_rate_hz came back as %r" % rates)

    arts = [a for a in data["artifacts"] if a["relative_path"] == FX_PATH]
    if len(arts) != 2:
        bad("expected the 2 fixture artifact rows, found %d" % len(arts))
    a_new = [a for a in arts if a["supersedes"] is not None]
    a_old = [a for a in arts if a["supersedes"] is None]
    if len(a_new) != 1 or len(a_old) != 1 or a_new[0]["supersedes"] != a_old[0]["artifact_id"]:
        bad("the artifact correction's supersedes link is not exported")
    if a_new[0]["produced_by_event_id"] != new[0]["event_id"]:
        bad("the corrected artifact does not point at the corrected event")
    for a in arts:
        if a["size_bytes"] != FX_SIZE:
            bad("size_bytes came back as %r, sent %d" % (a["size_bytes"], FX_SIZE))
        if a["checksum"] != "ab" * 32 or a["checksum_algo"] != "sha256":
            bad("checksum came back as %s:%s" % (a["checksum_algo"], a["checksum"]))
        # the check was recorded against the first row; the correction
        # describes the same file and must report the same check
        v = a["verification"]
        if v["status"] != "ok" or v["verified_artifact_id"] != a_old[0]["artifact_id"]:
            bad("artifact %s verification is %r; expected the file's 'ok' check, "
                "recorded against %s" % (a["artifact_id"], v, a_old[0]["artifact_id"]))

    edges = [i for i in data["eventInputs"] if i["artifact_id"] == a_new[0]["artifact_id"]]
    if len(edges) != 1 or edges[0]["role"] != "raw":
        bad("the fixture's provenance edge is not exported: %r" % edges)
    consumer = [e for e in data["events"] if e["event_id"] == edges[0]["event_id"]]
    if len(consumer) != 1 or consumer[0]["event_type"] != "analysis" \
            or consumer[0]["detail"].get("status") != "succeeded":
        bad("the consuming analysis event is not exported with its detail row")

    tags = [r for r in data["tagAssignments"]
            if r["entity_kind"] == "artifact" and r["entity_id"] == a_new[0]["artifact_id"]]
    if [(r["tag"], r["op"]) for r in tags] != [("stage:raw", "add")]:
        bad("the fixture's tag assignment came back as %r" % tags)


def main():
    data = json.loads(server.fetch_lab_data(server.SQL))
    check_shape(data, "database")
    summary = "%d events, %d artifacts, %d tag assignments" % (
        len(data["events"]), len(data["artifacts"]), len(data["tagAssignments"]))
    if "--no-fixture" in sys.argv[1:]:
        print("check_lab_data: OK (%s; fixture pass skipped)" % summary)
        return
    if shutil.which("psql") is None:
        fail("psql is not on PATH, so the fixture pass cannot run "
             "(--no-fixture checks only the rows already in the database)")
    fixture = export_with_fixture()
    check_shape(fixture, "fixture")
    check_fixture(fixture)
    print("check_lab_data: OK (%s; fixture round trip verified)" % summary)


if __name__ == "__main__":
    main()
