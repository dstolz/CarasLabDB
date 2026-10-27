"""Integration tests: the MCP tools against a real `lab` database.

Skipped unless CARASLABDB_TEST_DB names a scratch database that already has
design_docs/schema.sql applied. The connection otherwise comes from the usual
libpq variables (PGHOST, PGUSER, ...); that login must be able to INSERT, since
the fixture writes the rows the tools then read. Rows are keyed by a random
suffix, so the tests can run repeatedly against the same database.

    CARASLABDB_TEST_DB=lab_test python -m pytest mcp-server/tests
"""

import asyncio
import json
import os
import uuid

import pytest

TEST_DB = os.environ.get("CARASLABDB_TEST_DB")
pytestmark = pytest.mark.skipif(not TEST_DB, reason="CARASLABDB_TEST_DB not set")

if TEST_DB:
    os.environ["PGDATABASE"] = TEST_DB

from caraslabdb_mcp import db  # noqa: E402  (PGDATABASE must be set first)
from caraslabdb_mcp.server import app  # noqa: E402


def call(name, **arguments):
    """Call a tool through FastMCP's public API and return its result dict."""
    result = asyncio.run(app.call_tool(name, arguments))
    if isinstance(result, tuple):          # (content blocks, structured result)
        result = result[1]
    if isinstance(result, dict):
        return result.get("result", result) if set(result) == {"result"} else result
    return json.loads(result[0].text)


@pytest.fixture(scope="module")
def seed():
    import psycopg

    tag = uuid.uuid4().hex[:8]
    ids = {"tag": tag, "subject": f"MCP-{tag}", "email": f"Mcp.{tag}@Example.edu"}
    with psycopg.connect(dbname=TEST_DB, autocommit=True) as conn:
        q = conn.execute
        ids["person"] = q("INSERT INTO lab.person (full_name, email) VALUES (%s, %s) "
                          "RETURNING person_id", [f"MCP {tag}", ids["email"]]).fetchone()[0]
        proj = q("INSERT INTO lab.project (name) VALUES (%s) RETURNING project_id",
                 [f"mcp-{tag}"]).fetchone()[0]
        root = q("INSERT INTO lab.storage_root (name) VALUES (%s) RETURNING root_id",
                 [f"nas-{tag}"]).fetchone()[0]
        q("INSERT INTO lab.subject (subject_id, project_id) VALUES (%s, %s)",
          [ids["subject"], proj])
        sess = q("INSERT INTO lab.session (subject_id, label, storage_root_id, relative_path) "
                 "VALUES (%s, 's1', %s, %s) RETURNING session_id",
                 [ids["subject"], root, f"{ids['subject']}/s1"]).fetchone()[0]
        # Two recordings either side of local midnight on 1 September (UTC-4).
        for key, when, rate in (("aug", "2026-08-31 23:30-04", 20000),
                                ("sep", "2026-09-01 00:30-04", 30000)):
            with conn.transaction():
                ids[key] = q("INSERT INTO lab.event (event_type, session_id, occurred_at) "
                             "VALUES ('recording', %s, %s) RETURNING event_id",
                             [sess, when]).fetchone()[0]
                q("INSERT INTO lab.recording_event (event_id, sample_rate_hz) VALUES (%s, %s)",
                  [ids[key], rate])
        ids["artifact"] = q(
            "INSERT INTO lab.artifact (produced_by_event_id, session_id, storage_root_id, "
            "relative_path, checksum) VALUES (%s, %s, %s, %s, %s) RETURNING artifact_id",
            [ids["sep"], sess, root, f"{ids['subject']}/s1/raw.dat",
             uuid.uuid4().hex + uuid.uuid4().hex]).fetchone()[0]
        # The one tag write the fixtures make: a fresh topic value on the
        # September recording (topic is open, so fn_tag registers it).
        ids["topic"] = f"topic:t{tag}"
        q("SELECT lab.fn_tag('event', %s::text, %s)", [ids["sep"], ids["topic"]])
    return {k: str(v) for k, v in ids.items()}


def test_schema_version_matches(seed):
    call("get_species")
    assert db.schema_warning is None


def test_get_persons_email_is_case_insensitive(seed):
    res = call("get_persons", email=seed["email"].lower())
    assert [r["person_id"] for r in res["rows"]] == [seed["person"]]


def test_get_events_time_range(seed):
    res = call("get_events", subject_id=seed["subject"],
               occurred_from="2026-09-01T00:00:00-04:00",
               occurred_before="2026-10-01T00:00:00-04:00")
    assert [r["event_id"] for r in res["rows"]] == [seed["sep"]]
    res = call("get_events", subject_id=seed["subject"],
               occurred_before="2026-09-01T00:00:00-04:00")
    assert [r["event_id"] for r in res["rows"]] == [seed["aug"]]


def test_get_artifacts_time_range(seed):
    assert call("get_artifacts", subject_id=seed["subject"],
                created_from="2000-01-01")["row_count"] == 1
    assert call("get_artifacts", subject_id=seed["subject"],
                created_before="2000-01-01")["row_count"] == 0


def test_get_event_detail(seed):
    row = call("get_event_detail", event_id=seed["sep"])
    assert row["event_id"] == seed["sep"] and float(row["sample_rate_hz"]) == 30000


def test_get_integrity_report(seed):
    res = call("get_integrity_report", limit=1000)
    assert any(r["check_name"] == "artifact_never_verified" and r["subject"] == seed["artifact"]
               for r in res["rows"])
    severities = [r["severity"] for r in res["rows"]]
    assert severities == sorted(severities, key=lambda s: s != "error")


def test_connection_is_reused_and_replaced_when_it_dies(seed):
    import psycopg

    call("get_species")
    first = db._conn
    call("get_event_types")
    assert db._conn is first
    pid = first.info.backend_pid
    with psycopg.connect(dbname=TEST_DB, autocommit=True) as admin:
        admin.execute("SELECT pg_terminate_backend(%s)", [pid])
    assert call("get_species")["row_count"] >= 1
    assert db._conn is not first


def test_get_tag_namespaces_serialises_applies_to_as_a_list(seed):
    res = call("get_tag_namespaces")
    by_name = {r["namespace"]: r for r in res["rows"]}
    assert {"tag", "stage", "qc", "cohort", "condition", "topic"} <= set(by_name)
    assert isinstance(by_name["topic"]["applies_to"], list)
    assert sorted(by_name["topic"]["applies_to"]) == [
        "artifact", "event", "project", "session", "subject"]
    assert by_name["stage"]["applies_to"] == ["artifact"]
    # Round-trips through JSON (what the MCP client actually receives).
    json.dumps(res, default=str)


def test_get_tags(seed):
    topic = [r["tag"] for r in call("get_tags", namespace="topic", limit=1000)["rows"]]
    assert seed["topic"] in topic and all(t.startswith("topic:") for t in topic)
    stage = call("get_tags", namespace="stage")["rows"]
    assert [r["value"] for r in stage] == sorted(r["value"] for r in stage)
    assert "raw" in [r["value"] for r in stage]
    assert call("get_tags", namespace="no_such_ns")["row_count"] == 0


def test_find_by_tags(seed):
    assert call("find_by_tags", entity_kind="event",
                all_of=[seed["topic"]])["rows"] == [{"entity_id": seed["sep"]}]
    # Case and surrounding whitespace are normalised by the database.
    assert call("find_by_tags", entity_kind="event",
                all_of=[f"  {seed['topic'].upper()} "])["row_count"] == 1
    res = call("find_by_tags", entity_kind="event",
               any_of=["topic:*", "stage:raw"], limit=1000)
    assert seed["sep"] in [r["entity_id"] for r in res["rows"]]
    res = call("find_by_tags", entity_kind="event",
               none_of=[seed["topic"]], limit=1000)
    ids = [r["entity_id"] for r in res["rows"]]
    assert seed["aug"] in ids and seed["sep"] not in ids
    assert call("find_by_tags", entity_kind="event",
                all_of=[seed["topic"], "qc:fail"])["row_count"] == 0
    # Tags sit on the event row, not on the artifact it produced.
    assert call("find_by_tags", entity_kind="artifact",
                all_of=[seed["topic"]])["row_count"] == 0


def test_find_by_tags_rejects_unknown_kind(seed):
    with pytest.raises(Exception, match="entity kind"):
        call("find_by_tags", entity_kind="person", all_of=["a:b"])


def test_find_by_tags_is_bounded(seed):
    res = call("find_by_tags", entity_kind="event", none_of=["qc:fail"], limit=1)
    assert res["row_count"] == 1 and res["limit"] == 1
    assert res["truncated"] is True    # the fixtures alone hold two events


def test_get_events_tag_filters(seed):
    def ids(**tag_args):
        res = call("get_events", subject_id=seed["subject"], **tag_args)
        return sorted(r["event_id"] for r in res["rows"])

    assert ids(tags=[seed["topic"]]) == [seed["sep"]]
    assert ids(any_tags=["topic:*"]) == [seed["sep"]]
    assert ids(none_tags=[seed["topic"]]) == [seed["aug"]]
    assert ids(tags=[seed["topic"]], none_tags=["topic:*"]) == []
    assert ids(tags=[]) == sorted([seed["aug"], seed["sep"]])   # empty = no filter
    assert ids() == sorted([seed["aug"], seed["sep"]])


def test_tag_filters_on_the_other_entity_tools(seed):
    # Nothing but the September recording is tagged, so every other kind is empty.
    for name, key in (("get_artifacts", "subject_id"), ("get_sessions", "subject_id"),
                      ("get_subjects", "subject_id")):
        args = {key: seed["subject"]}
        assert call(name, tags=[seed["topic"]], **args)["row_count"] == 0
        assert call(name, none_tags=[seed["topic"]], **args)["row_count"] == 1
    assert call("get_projects", tags=[seed["topic"]])["row_count"] == 0


def test_get_entity_tags(seed):
    res = call("get_entity_tags", entity_kind="event", entity_id=seed["sep"])
    assert [r["tag"] for r in res["rows"]] == [seed["topic"]]
    assert res["rows"][0]["display_tag"] == seed["topic"]   # only `tag:` is stripped
    assert call("get_entity_tags", entity_kind="event",
                entity_id=seed["aug"])["row_count"] == 0
    hist = call("get_entity_tags", entity_kind="event", entity_id=seed["sep"],
                include_history=True)
    assert [(r["tag"], r["op"]) for r in hist["rows"]] == [(seed["topic"], "add")]
    # The subject kind keys on a text id, not a uuid.
    assert call("get_entity_tags", entity_kind="subject",
                entity_id=seed["subject"])["row_count"] == 0
    with pytest.raises(Exception, match="entity kind"):
        call("get_entity_tags", entity_kind="person", entity_id=seed["sep"])


def test_writes_are_refused(seed):
    with pytest.raises(Exception, match="read-only transaction"):
        db.fetch_all("INSERT INTO lab.species (code, common_name) VALUES ('x', 'x') RETURNING code")


def test_fn_tag_is_refused_through_the_read_only_path(seed):
    # fn_tag is the lab's tag write path; a tool (or a bug) that reached it
    # through the server's connection must hit the read-only transaction.
    with pytest.raises(Exception, match="read-only transaction"):
        db.fetch_all("SELECT lab.fn_tag('event', %s, %s)",
                     [seed["aug"], f"topic:refused{seed['tag']}"])
    with pytest.raises(Exception, match="read-only transaction"):
        db.fetch_all("SELECT lab.fn_register_tag(%s)", [f"topic:refused{seed['tag']}"])
    # ...and nothing leaked in.
    assert call("get_entity_tags", entity_kind="event",
                entity_id=seed["aug"])["row_count"] == 0
    leaked = [r["tag"] for r in call("get_tags", namespace="topic", limit=1000)["rows"]
              if f"refused{seed['tag']}" in r["tag"]]
    assert leaked == []
