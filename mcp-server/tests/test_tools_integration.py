"""Integration tests: the MCP tools against a real `lab` database.

Skipped unless CARASLABDB_TEST_DB names a scratch database that already has
design_docs/schema.sql applied. The connection otherwise comes from the usual
libpq variables (PGHOST, PGUSER, ...); that login must be able to INSERT, since
the fixture writes the rows the tools then read. Rows are keyed by a random
suffix, so the tests can run repeatedly against the same database.

    CARASLABDB_TEST_DB=lab_test python -m pytest mcp-server/tests

The read-only-role test additionally needs design_docs/grants.sql applied (it
creates the lab_ro role), a login that may create roles, and password
authentication for the temporary login it creates; it skips itself otherwise.
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

from caraslabdb_mcp import db, schema_map  # noqa: E402  (PGDATABASE must be set first)
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
    ids = {"tag": tag, "subject": f"MCP-{tag}", "subject2": f"MCPC-{tag}",
           "email": f"Mcp.{tag}@Example.edu",
           "checksum": uuid.uuid4().hex + uuid.uuid4().hex,
           "checksum2": uuid.uuid4().hex + uuid.uuid4().hex}
    with psycopg.connect(dbname=TEST_DB, autocommit=True) as conn:
        q = conn.execute
        ids["person"] = q("INSERT INTO lab.person (full_name, email) VALUES (%s, %s) "
                          "RETURNING person_id", [f"MCP {tag}", ids["email"]]).fetchone()[0]
        proj = ids["project"] = q("INSERT INTO lab.project (name) VALUES (%s) RETURNING project_id",
                                  [f"mcp-{tag}"]).fetchone()[0]
        root = q("INSERT INTO lab.storage_root (name) VALUES (%s) RETURNING root_id",
                 [f"nas-{tag}"]).fetchone()[0]

        def session(subject):
            q("INSERT INTO lab.subject (subject_id, project_id) VALUES (%s, %s)", [subject, proj])
            return q("INSERT INTO lab.session (subject_id, label, storage_root_id, relative_path) "
                     "VALUES (%s, 's1', %s, %s) RETURNING session_id",
                     [subject, root, f"{subject}/s1"]).fetchone()[0]

        def recording(sess, when, rate, supersedes=None):
            with conn.transaction():
                event = q("INSERT INTO lab.event (event_type, session_id, occurred_at, supersedes) "
                          "VALUES ('recording', %s, %s, %s) RETURNING event_id",
                          [sess, when, supersedes]).fetchone()[0]
                q("INSERT INTO lab.recording_event (event_id, sample_rate_hz) VALUES (%s, %s)",
                  [event, rate])
            return event

        def artifact(event, path, checksum, sess=None, subject=None, supersedes=None):
            return q(
                "INSERT INTO lab.artifact (produced_by_event_id, session_id, subject_id, "
                "storage_root_id, relative_path, checksum, supersedes) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING artifact_id",
                [event, sess, subject, root, path, checksum, supersedes]).fetchone()[0]

        sess = session(ids["subject"])
        # Two recordings either side of local midnight on 1 September (UTC-4).
        ids["aug"] = recording(sess, "2026-08-31 23:30-04", 20000)
        ids["sep"] = recording(sess, "2026-09-01 00:30-04", 30000)
        ids["artifact"] = artifact(ids["sep"], f"{ids['subject']}/s1/raw.dat", ids["checksum"], sess)
        # The one tag write the fixtures make: a fresh topic value on the
        # September recording (topic is open, so fn_tag registers it).
        ids["topic"] = f"topic:t{tag}"
        q("SELECT lab.fn_tag('event', %s::text, %s)", [ids["sep"], ids["topic"]])

        # A second animal carries the corrections: a raw file that an analysis
        # consumed and that was *then* corrected (same file, new row), and a
        # recording entered with the wrong sample rate and corrected.
        sub2 = ids["subject2"]
        sess2 = session(sub2)
        ids["rec2"] = recording(sess2, "2026-09-04 10:00-04", 30000)
        ids["raw_old"] = artifact(ids["rec2"], f"{sub2}/s1/raw.dat", ids["checksum2"], sess2)
        with conn.transaction():
            ids["an2"] = q("INSERT INTO lab.event (event_type, subject_id, occurred_at) "
                           "VALUES ('analysis', %s, '2026-09-06 10:00-04') RETURNING event_id",
                           [sub2]).fetchone()[0]
            q("INSERT INTO lab.analysis_event (event_id, pipeline_name) VALUES (%s, 'sorter')",
              [ids["an2"]])
        q("INSERT INTO lab.event_input (event_id, artifact_id) VALUES (%s, %s)",
          [ids["an2"], ids["raw_old"]])
        ids["derived"] = artifact(ids["an2"], f"{sub2}/s1/spikes.npy",
                                  uuid.uuid4().hex + uuid.uuid4().hex, subject=sub2)
        q("INSERT INTO lab.artifact_verification (artifact_id, status) VALUES (%s, 'ok')",
          [ids["raw_old"]])
        ids["raw_new"] = artifact(ids["rec2"], f"{sub2}/s1/raw.dat", ids["checksum2"], sess2,
                                  supersedes=ids["raw_old"])
        ids["ev_old"] = recording(sess2, "2026-09-05 10:00-04", 20000)
        ids["ev_new"] = recording(sess2, "2026-09-05 10:00-04", 30000, supersedes=ids["ev_old"])
    return {k: str(v) for k, v in ids.items()}


def test_schema_version_matches(seed):
    call("get_species")
    assert db.schema_warning is None


def test_schema_map_matches_the_catalog(seed):
    import psycopg

    with psycopg.connect(dbname=TEST_DB) as conn:
        for event_type, table in schema_map.EVENT_DETAIL_TABLE.items():
            columns = [r[0] for r in conn.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = 'lab' AND table_name = %s ORDER BY ordinal_position",
                [table.split(".")[1]])]
            assert tuple(c for c in columns if c not in ("event_id", "event_type")) == \
                schema_map.EVENT_DETAIL_COLUMNS[event_type], table
        relations = {r[0] for r in conn.execute(
            "SELECT 'lab.' || table_name FROM information_schema.tables WHERE table_schema = 'lab'")}
        types = {r[0] for r in conn.execute("SELECT code FROM lab.event_type")}
    assert db.ALLOWED_TABLES <= relations
    assert types == set(schema_map.EVENT_TYPES)


def test_tool_surface_is_read_only_and_takes_no_identifiers(seed):
    tools = asyncio.run(app.list_tools())
    assert len(tools) == 26
    for tool in tools:
        assert tool.name.startswith("get_") or tool.name == "find_by_tags", tool.name
        assert not {"sql", "query", "table", "column", "columns", "where", "order_by"} \
            & set(tool.inputSchema["properties"]), tool.name


def test_every_list_tool_is_bounded_and_puts_the_flags_first(seed):
    required = {
        "find_by_tags": {"entity_kind": "event"},
        "get_entity_tags": {"entity_kind": "event", "entity_id": seed["sep"]},
        "get_artifact_lineage": {"artifact_id": seed["derived"]},
    }
    tools = [t.name for t in asyncio.run(app.list_tools()) if t.name != "get_event_detail"]
    assert len(tools) == 25
    for name in tools:
        args = required.get(name, {})
        res = call(name, limit=10**9, **args)
        assert list(res)[:3] == ["row_count", "limit", "truncated"] and list(res)[-1] == "rows", name
        assert res["limit"] == db.MAX_LIMIT and res["row_count"] == len(res["rows"]) <= db.MAX_LIMIT
        assert call(name, limit=0, **args)["limit"] == db.DEFAULT_LIMIT
        with pytest.raises(Exception, match="limit"):
            call(name, limit=-1, **args)


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


def test_get_artifacts_checksum_ignores_case_and_whitespace(seed):
    # The database stores checksums lower-case; hashing tools do not all print them so.
    for given in (seed["checksum"], seed["checksum"].upper(), f"  {seed['checksum'].upper()}\n"):
        res = call("get_artifacts", checksum=given)
        assert [r["artifact_id"] for r in res["rows"]] == [seed["artifact"]], given
    # Ids are not folded: a subject id is matched exactly.
    assert call("get_subjects", subject_id=seed["subject"].lower())["row_count"] == 0


def test_get_event_detail(seed):
    row = call("get_event_detail", event_id=seed["sep"])
    assert row["event_id"] == seed["sep"] and float(row["sample_rate_hz"]) == 30000
    assert row["is_current"] is True and row["superseded_by"] is None
    assert "schema_warning" not in row


def test_get_event_detail_carries_the_schema_warning(seed, monkeypatch):
    call("get_species")                      # connect first: connecting resets the warning
    monkeypatch.setattr(db, "schema_warning", "version mismatch")
    row = call("get_event_detail", event_id=seed["sep"])
    assert list(row)[0] == "schema_warning" and row["schema_warning"] == "version mismatch"
    assert call("get_species")["schema_warning"] == "version mismatch"


def test_superseded_event_is_never_returned_as_current(seed):
    old, new = seed["ev_old"], seed["ev_new"]
    # Default: current rows only, and they carry no version columns.
    assert call("get_events", event_id=old)["row_count"] == 0
    assert "is_current" not in call("get_events", event_id=new)["rows"][0]
    # Full history: every row says whether it is current and what replaced it.
    row = call("get_events", event_id=old, active_only=False)["rows"][0]
    assert row["is_current"] is False and row["superseded_by"] == new
    row = call("get_events", event_id=new, active_only=False)["rows"][0]
    assert row["is_current"] is True and row["superseded_by"] is None and row["supersedes"] == old
    history = call("get_events", subject_id=seed["subject2"], event_type="recording",
                   occurred_from="2026-09-05T00:00:00-04:00",
                   occurred_before="2026-09-06T00:00:00-04:00", active_only=False)
    assert {r["event_id"]: r["is_current"] for r in history["rows"]} == {old: False, new: True}
    # The correction of an event can be looked up directly.
    for active_only in (True, False):
        res = call("get_events", supersedes=old, active_only=active_only)
        assert [r["event_id"] for r in res["rows"]] == [new]
    # The detail tool refuses the stale row by default and names its successor...
    with pytest.raises(Exception, match=f"superseded by event {new}"):
        call("get_event_detail", event_id=old)
    # ...and marks it when asked for it explicitly.
    row = call("get_event_detail", event_id=old, active_only=False)
    assert row["is_current"] is False and row["superseded_by"] == new
    assert float(row["sample_rate_hz"]) == 20000
    with pytest.raises(Exception, match="No event with id"):
        call("get_event_detail", event_id=str(uuid.uuid4()))


def test_superseded_artifact_is_never_returned_as_current(seed):
    old, new = seed["raw_old"], seed["raw_new"]
    assert call("get_artifacts", artifact_id=old)["row_count"] == 0
    assert [r["artifact_id"] for r in call("get_artifacts", checksum=seed["checksum2"])["rows"]] == [new]
    row = call("get_artifacts", artifact_id=old, active_only=False)["rows"][0]
    assert row["is_current"] is False and row["superseded_by"] == new
    both = call("get_artifacts", checksum=seed["checksum2"], active_only=False)["rows"]
    assert {r["artifact_id"]: r["is_current"] for r in both} == {old: False, new: True}
    assert [r["artifact_id"] for r in call("get_artifacts", supersedes=old)["rows"]] == [new]


def test_lineage_follows_corrections_by_default(seed):
    def lineage(artifact, direction, **kwargs):
        return call("get_artifact_lineage", artifact_id=seed[artifact], direction=direction,
                    **kwargs)["rows"]

    start = {"depth": 0, "event_id": None, "artifact_id": seed["raw_new"]}
    derived = {"depth": 1, "event_id": seed["an2"], "artifact_id": seed["derived"]}
    # Down from the *current* row of the corrected raw file reaches what was
    # derived from it, although the consumption edge names the superseded row.
    assert lineage("raw_new", "down") == [start, derived]
    # Whichever version is named, the answer is the current one.
    assert lineage("raw_old", "down") == [start, derived]
    up = lineage("derived", "up")
    assert [(r["depth"], r["event_id"], r["artifact_id"]) for r in up] == [
        (0, seed["an2"], seed["derived"]), (1, seed["rec2"], seed["raw_new"])]
    # Every id a default walk returns is a current row.
    for row in up + lineage("raw_old", "down"):
        assert call("get_artifacts", artifact_id=row["artifact_id"])["row_count"] == 1

    # follow_corrections=False: the rows exactly as recorded.
    assert lineage("raw_new", "down", follow_corrections=False) == [start]
    recorded = lineage("raw_old", "down", follow_corrections=False)
    assert [r["artifact_id"] for r in recorded] == [seed["raw_old"], seed["derived"]]
    recorded = lineage("derived", "up", follow_corrections=False)
    assert [r["artifact_id"] for r in recorded] == [seed["derived"], seed["raw_old"]]

    with pytest.raises(Exception, match="direction"):
        call("get_artifact_lineage", artifact_id=seed["derived"], direction="sideways")
    assert call("get_artifact_lineage", artifact_id=str(uuid.uuid4()))["row_count"] == 0


def test_recorded_edges_include_superseded_rows(seed):
    # get_event_inputs / get_provenance_edges read the rows as written: the
    # consumption edge still names the superseded raw artifact.
    assert call("get_event_inputs", artifact_id=seed["raw_new"])["row_count"] == 0
    rows = call("get_event_inputs", artifact_id=seed["raw_old"])["rows"]
    assert [r["event_id"] for r in rows] == [seed["an2"]]
    edges = call("get_provenance_edges", to_id=seed["an2"])["rows"]
    assert [(e["edge_type"], e["from_id"]) for e in edges] == [("consumes", seed["raw_old"])]


def test_latest_verification_follows_the_file(seed):
    # The check was recorded against the row that has since been corrected.
    assert call("get_artifact_verifications", artifact_id=seed["raw_new"])["row_count"] == 0
    assert call("get_artifact_verifications", artifact_id=seed["raw_old"])["row_count"] == 1
    for artifact in ("raw_new", "raw_old"):
        rows = call("get_artifact_verifications", artifact_id=seed[artifact],
                    latest_per_file=True)["rows"]
        assert [(r["artifact_id"], r["verified_artifact_id"], r["status"]) for r in rows] == [
            (seed[artifact], seed["raw_old"], "ok")]
    assert call("get_artifact_verifications", artifact_id=seed["derived"],
                latest_per_file=True)["row_count"] == 0


def test_get_integrity_report(seed):
    res = call("get_integrity_report", limit=1000)
    assert any(r["check_name"] == "artifact_never_verified" and r["subject"] == seed["artifact"]
               for r in res["rows"])
    # Verified by file: the corrected raw artifact is not "never verified".
    assert not any(r["subject"] == seed["raw_new"] for r in res["rows"])
    severities = [r["severity"] for r in res["rows"]]
    assert severities == sorted(severities, key=lambda s: s != "error")


def test_list_tools_return_a_stable_ordered_page(seed):
    import psycopg

    # Two subjects in the project, one row per page: without an ORDER BY the
    # UPDATE below moves the first row to the end of the heap and the page changes.
    first = call("get_subjects", project_id=seed["project"], limit=1)
    assert first["truncated"] is True
    top = first["rows"][0]["subject_id"]
    with psycopg.connect(dbname=TEST_DB, autocommit=True) as conn:
        conn.execute("UPDATE lab.subject SET notes = 'touched' WHERE subject_id = %s", [top])
    assert call("get_subjects", project_id=seed["project"], limit=1)["rows"][0]["subject_id"] == top

    def keys(name, *columns, **arguments):
        return [tuple(r[c] if r[c] is not None else "" for c in columns)
                for r in call(name, limit=1000, **arguments)["rows"]]

    for name, columns, arguments in (
        ("get_provenance_edges", ("edge_type", "from_id", "to_id"), {}),
        ("get_event_inputs", ("event_id", "artifact_id"), {}),
        ("get_project_members", ("project_id", "person_id"), {}),
        ("get_artifact_lineage", ("depth", "event_id", "artifact_id"),
         {"artifact_id": seed["raw_old"], "direction": "down"}),
        ("get_artifact_verifications", ("artifact_id",), {"latest_per_file": True}),
    ):
        got = keys(name, *columns, **arguments)
        assert got == sorted(got), name
    newest_first = [r["occurred_at"] for r in call("get_events", subject_id=seed["subject"])["rows"]]
    assert newest_first == sorted(newest_first, reverse=True) and len(newest_first) == 2


def test_text_filters_take_json_looking_strings_literally(seed):
    # FastMCP JSON-decodes a string argument unless the parameter is typed
    # `str`; "null" then became None and the filter was silently dropped.
    one = {"subject_id": seed["subject"]}
    assert call("get_sessions", **one)["row_count"] == 1
    for text in ("null", "true", "123", "[1]", '{"a": 1}'):
        assert call("get_sessions", label=text, **one)["row_count"] == 0, text
    assert call("get_events", event_type="null", **one)["row_count"] == 0
    assert call("get_tags", namespace="null")["row_count"] == 0
    assert all(r["subject_id"] == "null" for r in call("get_subjects", subject_id="null")["rows"])
    # A real JSON null, like leaving the argument out, still means "no filter"...
    assert call("get_sessions", label=None, **one)["row_count"] == 1
    assert call("get_events", event_type=None, **one)["row_count"] == 2
    # ...a list sent as a JSON string is still decoded...
    assert call("get_events", tags=json.dumps([seed["topic"]]), **one)["row_count"] == 1
    # ...and clients still see "string or null", not a required string.
    tools = {t.name: t.inputSchema for t in asyncio.run(app.list_tools())}
    for name, parameter in (("get_sessions", "label"), ("get_subjects", "subject_id"),
                            ("get_events", "supersedes"), ("get_artifacts", "checksum"),
                            ("get_tags", "namespace"), ("get_provenance_edges", "edge_type")):
        spec = tools[name]["properties"][parameter]
        assert spec["anyOf"] == [{"type": "string"}, {"type": "null"}] and spec["default"] is None
        assert parameter not in tools[name].get("required", [])


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
               any_of=["topic:*", "qc:pass"], limit=1000)
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
    # Superseded rows are skipped unless asked for.
    ids = [r["entity_id"] for r in call("find_by_tags", entity_kind="event", limit=1000)["rows"]]
    assert seed["ev_new"] in ids and seed["ev_old"] not in ids


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


def test_tag_filter_that_cannot_match_is_an_error_not_a_result(seed):
    one = {"subject_id": seed["subject"]}
    # A typo in a closed namespace used to exclude nothing (none_tags) or
    # everything (tags); either way the answer looked like a real one.
    for arguments in ({"none_tags": ["qc:fial"]}, {"tags": ["qc:fial"]}, {"any_tags": ["qc:fial"]}):
        with pytest.raises(Exception, match="'qc:fial': tag qc:fial is not registered"):
            call("get_artifacts", **arguments, **one)
    # A namespace that does not exist, as a tag and as a wildcard.
    with pytest.raises(Exception, match="tag namespace qcc does not exist"):
        call("get_events", none_tags=["qcc:*"], **one)
    with pytest.raises(Exception, match="tag namespace nosuchns does not exist"):
        call("find_by_tags", entity_kind="event", none_of=["nosuchns:x"])
    # A namespace that cannot be on this kind of entity.
    with pytest.raises(Exception, match="stage apply to artifact only, not to event"):
        call("get_events", tags=["stage:raw"], **one)
    with pytest.raises(Exception, match="cohort apply to .* not to artifact"):
        call("find_by_tags", entity_kind="artifact", all_of=["cohort:a"])
    # An unregistered value of an open namespace: nothing can carry it.
    with pytest.raises(Exception, match="is not registered"):
        call("get_subjects", none_tags=[f"topic:never{seed['tag']}"], **one)
    # Every faulty token is named, whichever list it came from.
    with pytest.raises(Exception) as err:
        call("get_sessions", tags=["qc:fial"], any_tags=["qc:pass"], none_tags=["nosuchns:x"], **one)
    assert "'qc:fial'" in str(err.value) and "'nosuchns:x'" in str(err.value)
    assert "'qc:pass'" not in str(err.value)
    # A blank token is not "no filter".
    for name in ("get_events", "get_artifacts"):
        with pytest.raises(Exception, match="empty"):
            call(name, tags=[" "], **one)
    with pytest.raises(Exception, match="empty"):
        call("find_by_tags", entity_kind="event", any_of=[""])
    # Sound filters still work: registered tags, wildcards, bare tags, mixed case.
    assert call("get_events", any_tags=["qc:*"], none_tags=["QC:Fail"], **one)["row_count"] == 0
    assert call("get_artifacts", none_tags=["qc:fail", "stage:*"], **one)["row_count"] == 1


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


def test_session_default_is_read_only(seed):
    with db.read_only_cursor() as cur:
        cur.execute("SHOW transaction_read_only")
        assert cur.fetchone()[0] == "on"
        cur.execute("SHOW default_transaction_read_only")
        assert cur.fetchone()[0] == "on"
    # So a statement that ended the wrapper's transaction and began its own
    # would still be in a read-only one.
    with pytest.raises(Exception, match="read-only transaction"):
        with db.read_only_cursor() as cur:
            cur.execute("COMMIT; BEGIN; INSERT INTO lab.species (code, common_name) "
                        "VALUES ('zz_escape', 'x'); COMMIT")
    assert not [r for r in call("get_species", limit=1000)["rows"] if r["code"] == "zz_escape"]


def test_a_login_that_can_write_is_warned_about(seed):
    # The test login seeds the fixtures, so it can write -- which is exactly
    # what the server should not be run as, and it says so.
    call("get_species")
    assert db.role_warning and "lab_ro" in db.role_warning


@pytest.fixture
def ro_login(seed, monkeypatch):
    """Point the db layer at a temporary login that inherits lab_ro; skip if impossible."""
    import psycopg
    from psycopg import sql

    role, password = f"mcp_ro_{seed['tag']}", uuid.uuid4().hex
    drop = sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(role))
    with psycopg.connect(dbname=TEST_DB, autocommit=True) as admin:
        able = admin.execute(
            "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lab_ro') "
            "AND (SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user)"
        ).fetchone()[0]
        if not able:
            pytest.skip("needs the lab_ro role (design_docs/grants.sql) and a login that may create roles")
        try:
            admin.execute(sql.SQL("CREATE ROLE {} LOGIN PASSWORD {} IN ROLE lab_ro").format(
                sql.Identifier(role), sql.Literal(password)))
        except psycopg.Error as exc:
            pytest.skip(f"cannot create a login that inherits lab_ro: {exc}")
        # Password logins need a TCP host where local connections use peer auth.
        hosts = [os.environ["PGHOST"]] if os.environ.get("PGHOST") else [None, "127.0.0.1"]
        for host in hosts:
            try:
                psycopg.connect(dbname=TEST_DB, user=role, password=password, connect_timeout=5,
                                **({"host": host} if host else {})).close()
                break
            except psycopg.OperationalError:
                continue
        else:
            admin.execute(drop)
            pytest.skip("the temporary login cannot authenticate here (no password authentication)")
    db._discard_conn()
    monkeypatch.setenv("PGUSER", role)
    monkeypatch.setenv("PGPASSWORD", password)
    if host:
        monkeypatch.setenv("PGHOST", host)
    try:
        yield role
    finally:
        db._discard_conn()
        monkeypatch.undo()               # the next call reconnects as the test login
        with psycopg.connect(dbname=TEST_DB, autocommit=True) as admin:
            admin.execute(drop)


def test_read_only_role_refuses_writes_without_the_transaction_layer(seed, ro_login):
    # The tools work as a login that holds SELECT and nothing else...
    assert call("get_species")["row_count"] >= 1
    assert call("get_events", subject_id=seed["subject"], tags=[seed["topic"]])["row_count"] == 1
    assert call("get_integrity_report", limit=1)["limit"] == 1
    assert db.role_warning is None
    with db.read_only_cursor() as cur:
        cur.execute("SELECT current_user")
        assert cur.fetchone()[0] == ro_login
    insert = "INSERT INTO lab.species (code, common_name) VALUES ('zz_ro', 'x') RETURNING code"
    # ...a write through the db layer is refused by the transaction...
    with pytest.raises(Exception, match="read-only transaction"):
        db.fetch_all(insert)
    # ...and, with the transaction switched back to read-write, by the role.
    for statement, params in ((insert, None),
                              ("SELECT lab.fn_tag('event', %s, %s)", [seed["aug"], seed["topic"]])):
        with pytest.raises(Exception, match="permission denied"):
            with db.read_only_cursor() as cur:
                cur.execute("SET TRANSACTION READ WRITE")
                cur.execute(statement, params)
    assert not [r for r in call("get_species", limit=1000)["rows"] if r["code"] == "zz_ro"]
    assert call("get_entity_tags", entity_kind="event", entity_id=seed["aug"])["row_count"] == 0


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
