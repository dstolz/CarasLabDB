"""Read tools for the append-only event log and its per-type detail tables."""

from typing import Optional

from .. import db, schema_map
from . import OptText


def register(app):
    @app.tool()
    def get_events(
        event_id: OptText = None,
        event_type: OptText = None,
        subject_id: OptText = None,
        session_id: OptText = None,
        supersedes: OptText = None,
        occurred_from: OptText = None,
        occurred_before: OptText = None,
        tags: Optional[list[str]] = None,
        any_tags: Optional[list[str]] = None,
        none_tags: Optional[list[str]] = None,
        active_only: bool = True,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List base event rows (event_type, subject/session, occurred_at, ...).

        By default reads lab.event_active: current rows only, i.e. events
        that no correction has replaced. With active_only=False it reads
        lab.event_version, the full correction history, and every row then
        carries `is_current` (false for a row that was corrected away) and
        `superseded_by` (the event_id of the correction that replaced it,
        else null) -- never treat a row with is_current=false as the current
        facts. Each row's own `supersedes` is the event_id it replaced.
        Ordered newest-first by occurred_at.

        To find the correction of event X: supersedes=X with
        active_only=False (follow superseded_by / supersedes along the chain
        until is_current is true).

        occurred_from (inclusive) and occurred_before (exclusive) bound
        occurred_at. Each is an ISO-8601 date or timestamp, e.g.
        occurred_from="2026-09-01", occurred_before="2026-10-01" for
        September. A value without a UTC offset is read in the database
        session's time zone; add one (e.g. "2026-09-01T00:00:00-04:00") to be
        exact. Use ISO-8601 only: a form such as "01/09/2026" is read
        month-first.

        subject_id and event_type are matched exactly, case included. A
        filter left out (or null) is simply not applied -- it does not mean
        "where this column IS NULL".

        Tag filters (current tags only; see get_tag_namespaces / get_tags):
        `tags` = the event must have ALL of these, `any_tags` = at least
        ONE of these, `none_tags` = NONE of these. A tag is `namespace:value`,
        lowercase (e.g. ["condition:x", "qc:pass"]); a bare tag with no colon
        means `tag:<x>`; "namespace:*" matches any tag in that namespace
        (none_tags=["qc:*"] = not yet QC'd). Unset or empty lists are not
        applied. A tag that is not registered, or whose namespace does not
        exist or does not apply to events, is an error naming the tag --
        never an empty or unfiltered result.

        Returns {"row_count": n, "limit": n, "truncated": bool, "rows":
        [...]}. `truncated` true means more rows matched than were returned:
        filter more narrowly or raise `limit` (max 1000).
        """
        table = "lab.event_active" if active_only else "lab.event_version"
        return db.select_from(table, {
            "event_id": event_id, "event_type": event_type,
            "subject_id": subject_id, "session_id": session_id,
            "supersedes": supersedes,
        }, limit=limit, order_by=db.ORDER_BY_EVENT,
            time_ranges={"occurred_at": (occurred_from, occurred_before)},
            tag_filters=("event", tags, any_tags, none_tags))

    @app.tool()
    def get_event_detail(event_id: str, active_only: bool = True) -> dict:
        """Fetch one event joined to its type-specific detail columns.

        E.g. a 'recording' event's row includes sample_rate_hz, n_channels,
        probe_id, etc. from lab.recording_event. The detail table is looked
        up from a fixed internal map of the 8 known event types -- never
        built from the event_type string directly.

        The row always carries `is_current` and `superseded_by`. By default
        only a current event is returned: for one that a correction has
        replaced the call fails with an error naming the event that
        superseded it, so stale values are never returned as if current.
        Pass active_only=False to read a superseded row as it was recorded;
        it comes back with is_current=false and superseded_by set to the
        event_id of its correction.

        Single-row by construction, so this returns the row itself as a flat
        dict -- not the {"row_count", ..., "rows"} envelope the list tools
        return. If the database is at another schema version than this
        server was written for, the dict starts with a `schema_warning`.
        """
        # All lookups share one read-only transaction, so they see the same
        # snapshot even if a correction is committed in between.
        with db.read_only_cursor() as cur:
            cur.execute(
                "SELECT event_type, is_current, superseded_by "
                "FROM lab.event_version WHERE event_id = %s", [event_id])
            found = db.rows(cur)
            if not found:
                raise ValueError(f"No event with id {event_id}.")
            head = found[0]
            if active_only and not head["is_current"]:
                # Under the default an id that has been corrected away used to
                # look identical to one that never existed; say which, and
                # where the current values are.
                raise ValueError(
                    f"Event {event_id} has been superseded by event "
                    f"{head['superseded_by']}: read that one for the current "
                    f"values, or pass active_only=False to read this "
                    f"superseded row as it was recorded.")
            event_type = head["event_type"]
            if event_type not in schema_map.EVENT_DETAIL_TABLE:
                raise ValueError(f"Unknown event_type {event_type!r}.")
            detail_table = schema_map.EVENT_DETAIL_TABLE[event_type]
            detail_cols = schema_map.EVENT_DETAIL_COLUMNS[event_type]
            col_list = ", ".join(f"d.{c}" for c in detail_cols) or "NULL"
            cur.execute(
                f"SELECT e.*, {col_list} FROM lab.event_version e "
                f"JOIN {detail_table} d ON d.event_id = e.event_id "
                f"WHERE e.event_id = %s",
                [event_id],
            )
            detail = db.rows(cur)
        if not detail:
            raise ValueError(f"Event {event_id} has no matching {detail_table} row.")
        row = detail[0]
        if db.schema_warning:
            row = {"schema_warning": db.schema_warning, **row}
        return row
