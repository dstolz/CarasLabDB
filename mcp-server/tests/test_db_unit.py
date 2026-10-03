"""Unit tests for db.py's guards and SQL construction. No database needed."""

import pytest

from caraslabdb_mcp import db


@pytest.fixture
def captured(monkeypatch):
    """Capture the SQL select_from would run instead of running it."""
    calls = []

    def fake_fetch_limited(sql, params=(), limit=db.DEFAULT_LIMIT):
        calls.append((sql, list(params), limit))
        return db._envelope([], db._effective_limit(limit))

    monkeypatch.setattr(db, "fetch_limited", fake_fetch_limited)
    return calls


@pytest.mark.parametrize("given, expected", [
    (None, db.DEFAULT_LIMIT), (0, db.DEFAULT_LIMIT), (5, 5),
    (db.MAX_LIMIT, db.MAX_LIMIT), (db.MAX_LIMIT + 1, db.MAX_LIMIT), (10**9, db.MAX_LIMIT),
])
def test_effective_limit_is_always_bounded(given, expected):
    assert db._effective_limit(given) == expected


def test_effective_limit_rejects_negative():
    with pytest.raises(ValueError):
        db._effective_limit(-1)


def test_envelope_reports_truncation():
    env = db._envelope([{"a": i} for i in range(4)], 3)
    assert env["rows"] == [{"a": 0}, {"a": 1}, {"a": 2}]
    assert env["row_count"] == 3 and env["limit"] == 3 and env["truncated"] is True
    env = db._envelope([{"a": 1}], 3)
    assert env["truncated"] is False and env["row_count"] == 1


def test_envelope_carries_schema_warning(monkeypatch):
    monkeypatch.setattr(db, "schema_warning", None)
    assert "schema_warning" not in db._envelope([], 1)
    monkeypatch.setattr(db, "schema_warning", "version mismatch")
    assert db._envelope([], 1)["schema_warning"] == "version mismatch"


def test_select_from_rejects_unlisted_table(captured):
    with pytest.raises(ValueError, match="Unknown table"):
        db.select_from("lab.event; DROP TABLE x", {})
    with pytest.raises(ValueError, match="Unknown table"):
        db.select_from("pg_catalog.pg_authid", {})
    assert captured == []


def test_select_from_rejects_unlisted_order_by(captured):
    with pytest.raises(ValueError, match="order_by"):
        db.select_from("lab.event", {}, order_by="occurred_at; DROP TABLE x")


@pytest.mark.parametrize("kwargs", [
    {"filters": {"subject_id = subject_id OR 1": 1}},
    {"filters": {}, "ci_filters": {"Email": "x"}},
    {"filters": {}, "time_ranges": {"occurred_at)--": ("2026-01-01", None)}},
])
def test_select_from_rejects_bad_column_names(captured, kwargs):
    with pytest.raises(ValueError, match="column name"):
        db.select_from("lab.event", **kwargs)
    assert captured == []


def test_select_from_binds_every_value(captured):
    db.select_from(
        "lab.event_active",
        {"subject_id": "G1", "session_id": None},
        limit=10,
        order_by=db.ORDER_BY_EVENT,
        time_ranges={"occurred_at": ("2026-09-01", "2026-10-01")},
    )
    sql, params, limit = captured[0]
    assert sql == (
        "SELECT * FROM lab.event_active WHERE subject_id = %s "
        "AND occurred_at >= %s::timestamptz AND occurred_at < %s::timestamptz "
        "ORDER BY occurred_at DESC, event_id"
    )
    assert params == ["G1", "2026-09-01", "2026-10-01"]
    assert limit == 10


def test_select_from_open_ended_range_and_ci_filter(captured):
    db.select_from("lab.person", {"person_id": None},
                   ci_filters={"email": "Dan@UMD.edu"})
    db.select_from("lab.artifact", {}, time_ranges={"created_at": (None, "2026-01-01")})
    db.select_from("lab.artifact", {}, time_ranges={"created_at": (None, None)})
    assert captured[0][0] == "SELECT * FROM lab.person WHERE lower(email) = lower(%s)"
    assert captured[0][1] == ["Dan@UMD.edu"]
    assert captured[1][0] == "SELECT * FROM lab.artifact WHERE created_at < %s::timestamptz"
    assert captured[2][0] == "SELECT * FROM lab.artifact"
