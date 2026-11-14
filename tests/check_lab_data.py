#!/usr/bin/env python3
"""Check that web/live/lab_data.sql emits the JSON the dashboard reads.

Two passes, both exiting non-zero on the first problem:

1. Through the live server's own data path (server.fetch_payload: lab_data.sql
   plus the integrity summary of lab_integrity.sql, spliced in as
   ``integrity``), against whatever rows the database holds: every
   collection is present, and every row of every collection has exactly the
   keys the page uses, with timestamps in the form it parses.
2. Through ``psql``, against a known fixture inserted and rolled back in the
   same transaction as the export, so the result does not depend on what the
   database happens to contain (an empty table makes pass 1 vacuous). The
   fixture has a corrected event, a corrected artifact with a verification,
   a provenance edge, a tag, variables set, updated and unset (numbers whose
   exact text matters among them) and a retraction, and the values that come
   back are compared with the ones that went in; the integrity summary is
   compared with lab.fn_check_integrity() run in the same transaction.
   Nothing is left behind. It needs ``psql`` on PATH and a role that may
   insert; ``--no-fixture`` skips it.

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
    "variables": {"name", "label", "description", "units", "value_type", "applies_to",
                  "retired_at", "created_at", "created_by"},
    "variableValues": {"value_id", "entity_kind", "entity_id", "variable", "op", "value",
                       "value_type", "note", "set_at", "set_by", "set_login"},
    "retractions": {"retraction_id", "entity_kind", "entity_id", "reason", "retracted_at",
                    "retracted_by", "retracted_login"},
    "dispositions": {"disposition_id", "artifact_id", "disposition", "successor_artifact_id",
                     "occurred_at", "recorded_at", "recorded_by", "recorded_login", "note"},
}
ARRAYS = tuple(ROW_KEYS) + ("roleMeta",)
VERIFICATION_KEYS = {"status", "verified_at", "verified_artifact_id"}
INTEGRITY_KEYS = {"computed_at", "example_limit", "checks"}
CHECK_KEYS = {"severity", "check_name", "count", "examples"}
ENTITY_KINDS = ("event", "artifact", "subject", "session", "project")

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
    "variables": {"retired_at": True, "created_at": False},
    "variableValues": {"set_at": False},
    "retractions": {"retracted_at": False},
    "dispositions": {"occurred_at": False, "recorded_at": False},
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

    expected = set(ARRAYS) | {"NOW", "integrity"}
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

    for v in data["variables"]:
        if v["value_type"] not in ("number", "text"):
            bad("variable %r value_type is %r" % (v["name"], v["value_type"]))
        if not isinstance(v["applies_to"], list):
            bad("variable %r applies_to is not an array" % v["name"])
    names = {v["name"] for v in data["variables"]}
    last_id = 0
    for r in data["variableValues"]:
        vid = r["value_id"]
        if isinstance(vid, bool) or not isinstance(vid, int) or vid <= last_id:
            bad("variable value %r: value_id is not an integer in ascending order" % vid)
        last_id = vid
        if r["entity_kind"] not in ENTITY_KINDS or not isinstance(r["entity_id"], str):
            bad("variable value %s has a bad entity" % vid)
        if r["variable"] not in names:
            bad("variable value %s names an unknown variable %r" % (vid, r["variable"]))
        if r["op"] == "set":
            # the value travels as the text the database stored, never a JSON number
            if not isinstance(r["value"], str) or r["value"] == "":
                bad("variable value %s: a 'set' row's value is %r, not text" % (vid, r["value"]))
        elif r["op"] == "unset":
            if r["value"] is not None:
                bad("variable value %s: an 'unset' row carries %r" % (vid, r["value"]))
        else:
            bad("variable value %s op is %r" % (vid, r["op"]))
        if r["value_type"] not in ("number", "text"):
            bad("variable value %s value_type is %r" % (vid, r["value_type"]))
    for r in data["retractions"]:
        if r["entity_kind"] not in ("event", "artifact") or not isinstance(r["entity_id"], str):
            bad("retraction %r has a bad entity" % r["retraction_id"])
        if not isinstance(r["reason"], str) or not r["reason"].strip():
            bad("retraction %r has no reason" % r["retraction_id"])
    artifact_ids = {a["artifact_id"] for a in data["artifacts"]}
    for r in data["dispositions"]:
        did = r["disposition_id"]
        if r["disposition"] not in ("replaced", "moved", "deleted", "restored"):
            bad("disposition %r is %r" % (did, r["disposition"]))
        if r["artifact_id"] not in artifact_ids:
            bad("disposition %r names an artifact not in the export" % did)
        succ = r["successor_artifact_id"]
        if succ is not None and succ not in artifact_ids:
            bad("disposition %r names a successor not in the export" % did)
        if (r["disposition"] == "moved") != (succ is not None) and r["disposition"] != "replaced":
            bad("disposition %r: a move names its successor, a deletion or restore none" % did)

    integ = data["integrity"]
    if not isinstance(integ, dict):
        bad("integrity is %r, not an object" % (integ,))
    if "error" in integ:
        bad("integrity summary unavailable: %s" % integ["error"])
    if set(integ) != INTEGRITY_KEYS:
        bad("integrity keys differ: %s" % sorted(integ))
    if not TS.match(str(integ["computed_at"])):
        bad("integrity.computed_at is %r" % integ["computed_at"])
    limit = integ["example_limit"]
    checks = integ["checks"]
    if not isinstance(checks, list):
        bad("integrity.checks is not an array")
    order = [(0 if c.get("severity") == "error" else 1, c.get("check_name")) for c in checks]
    if order != sorted(order):
        bad("integrity checks are not errors first, then by name")
    for c in checks:
        if set(c) != CHECK_KEYS:
            bad("integrity check keys differ: %s" % sorted(c))
        if c["severity"] not in ("error", "warning"):
            bad("check %s severity is %r" % (c["check_name"], c["severity"]))
        if isinstance(c["count"], bool) or not isinstance(c["count"], int) or c["count"] < 1:
            bad("check %s count is %r" % (c["check_name"], c["count"]))
        ex = c["examples"]
        if not isinstance(ex, list) or len(ex) != min(c["count"], limit):
            bad("check %s: %d examples for %d rows (limit %r)"
                % (c["check_name"], len(ex) if isinstance(ex, list) else -1, c["count"], limit))
        if any(not isinstance(x, dict) or set(x) != {"subject", "detail"} for x in ex):
            bad("check %s examples are not {subject, detail} objects" % c["check_name"])


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
    e1 uuid; e2 uuid; a1 uuid; a2 uuid; a3 uuid; an uuid;
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
    -- the analysis's output, later removed by a clean-up
    INSERT INTO lab.artifact (produced_by_event_id, storage_root_id, relative_path, checksum)
        VALUES (an, root, 'check_lab_data/s1/spikes.npy', repeat('cd', 32))
        RETURNING artifact_id INTO a3;
    INSERT INTO lab.artifact_disposition (artifact_id, disposition, occurred_at, note)
        VALUES (a3, 'deleted', '2020-01-04T00:00:00Z', 'check_lab_data deletion');
    -- variables: a number whose text matters, updated; a text value, unset;
    -- a number too long for a double
    PERFORM lab.fn_set_variable('session', sess::text, 'check_lab_data depth', 1200,
                                p_units => 'um', p_label => 'CLD depth');
    PERFORM lab.fn_set_variable('session', sess::text, 'check_lab_data depth', 1350.50,
                                p_note => 'remeasured');
    PERFORM lab.fn_set_variable('subject', '%(subject)s', 'check_lab_data housing', p_text => 'pair');
    PERFORM lab.fn_unset_variable('subject', '%(subject)s', 'check_lab_data housing');
    PERFORM lab.fn_set_variable('artifact', a2::text, 'check_lab_data gain',
                                12345678901234567890.123456789);
    -- the analysis withdrawn
    PERFORM lab.fn_retract('event', an, 'check_lab_data retraction');
END
$fx$;
""" % {"subject": FX_SUBJECT, "path": FX_PATH, "occurred": FX_OCCURRED, "size": FX_SIZE}


def export_with_fixture():
    env = dict(os.environ)
    env.setdefault("PGDATABASE", "lab")
    env["PGTZ"] = server.SESSION_TIME_ZONE
    env["PGCLIENTENCODING"] = "UTF8"
    # The export, the integrity summary and fn_check_integrity's own counts,
    # all in the fixture's transaction: three lines of output.
    script = ("BEGIN;\n" + FIXTURE + server.SQL.rstrip() + "\n"
              + server.INTEGRITY_SQL.rstrip() + "\n"
              + "SELECT coalesce(json_object_agg(severity || '/' || check_name, n), '{}'::json)"
              " FROM (SELECT severity, check_name, count(*) AS n"
              " FROM lab.fn_check_integrity() GROUP BY 1, 2) c;\n"
              + "ROLLBACK;\n")
    proc = subprocess.run(["psql", "-tAXq", "-v", "ON_ERROR_STOP=1"], input=script,
                          capture_output=True, text=True, encoding="utf-8", env=env)
    if proc.returncode != 0:
        fail("[fixture] psql failed: " + (proc.stderr.strip() or "no message"))
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if len(lines) < 3:
        fail("[fixture] psql returned %d rows, expected 3" % len(lines))
    data = json.loads(server.merge_payload(lines[-3], lines[-2]))
    return data, json.loads(lines[-1])


def check_fixture(data, integrity_counts):
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

    # variables: the log in order, each value as the exact text stored
    defs = {v["name"]: v for v in data["variables"]}
    depth = defs.get("check_lab_data depth")
    if not depth or (depth["label"], depth["units"], depth["value_type"]) != ("CLD depth", "um", "number"):
        bad("the fixture's variable definition came back as %r" % depth)
    if not isinstance(depth["applies_to"], list) or "session" not in depth["applies_to"]:
        bad("variable applies_to came back as %r" % depth["applies_to"])
    mine = [(r["entity_kind"], r["entity_id"], r["variable"], r["op"], r["value"], r["note"])
            for r in data["variableValues"] if r["variable"].startswith("check_lab_data ")]
    want = [("session", sessions[0]["session_id"], "check_lab_data depth", "set", "1200", None),
            ("session", sessions[0]["session_id"], "check_lab_data depth", "set", "1350.50", "remeasured"),
            ("subject", FX_SUBJECT, "check_lab_data housing", "set", "pair", None),
            ("subject", FX_SUBJECT, "check_lab_data housing", "unset", None, None),
            ("artifact", a_new[0]["artifact_id"], "check_lab_data gain", "set",
             "12345678901234567890.123456789", None)]
    if mine != want:
        bad("the fixture's variable log came back as %r" % mine)

    # the retraction
    rets = [r for r in data["retractions"] if r["entity_id"] == consumer[0]["event_id"]]
    if [(r["entity_kind"], r["reason"]) for r in rets] != [("event", "check_lab_data retraction")]:
        bad("the fixture's retraction came back as %r" % rets)

    # the disposition, on the analysis's output
    out = [a for a in data["artifacts"] if a["relative_path"] == "check_lab_data/s1/spikes.npy"]
    if len(out) != 1 or out[0]["produced_by_event_id"] != consumer[0]["event_id"]:
        bad("the analysis's output is not exported: %r" % out)
    disp = [(d["disposition"], d["successor_artifact_id"], d["occurred_at"], d["note"])
            for d in data["dispositions"] if d["artifact_id"] == out[0]["artifact_id"]]
    if disp != [("deleted", None, "2020-01-04T00:00:00Z", "check_lab_data deletion")]:
        bad("the fixture's disposition came back as %r" % disp)

    # the integrity summary agrees with lab.fn_check_integrity() itself
    got = {"%s/%s" % (c["severity"], c["check_name"]): c["count"]
           for c in data["integrity"]["checks"]}
    if got != integrity_counts:
        bad("integrity summary %r differs from lab.fn_check_integrity() %r"
            % (got, integrity_counts))


def main():
    data = json.loads(server.fetch_payload())
    check_shape(data, "database")
    summary = "%d events, %d artifacts, %d tag assignments, %d variable values, %d checks" % (
        len(data["events"]), len(data["artifacts"]), len(data["tagAssignments"]),
        len(data["variableValues"]), len(data["integrity"]["checks"]))
    if "--no-fixture" in sys.argv[1:]:
        print("check_lab_data: OK (%s; fixture pass skipped)" % summary)
        return
    if shutil.which("psql") is None:
        fail("psql is not on PATH, so the fixture pass cannot run "
             "(--no-fixture checks only the rows already in the database)")
    fixture, integrity_counts = export_with_fixture()
    check_shape(fixture, "fixture")
    check_fixture(fixture, integrity_counts)
    print("check_lab_data: OK (%s; fixture round trip verified)" % summary)


if __name__ == "__main__":
    main()
