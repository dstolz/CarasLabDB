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


def test_writes_are_refused(seed):
    with pytest.raises(Exception, match="read-only transaction"):
        db.fetch_all("INSERT INTO lab.species (code, common_name) VALUES ('x', 'x') RETURNING code")
