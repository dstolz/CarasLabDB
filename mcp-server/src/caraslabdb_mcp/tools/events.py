"""Read tools for the append-only event log and its per-type detail tables."""

from typing import Optional

from .. import db, schema_map


def register(app):
    @app.tool()
    def get_events(
        event_id: Optional[str] = None,
        event_type: Optional[str] = None,
        subject_id: Optional[str] = None,
        session_id: Optional[str] = None,
        active_only: bool = True,
        limit: int = 0,
    ) -> list[dict]:
        """List base event rows (event_type, subject/session, occurred_at, ...).

        Reads lab.event_active (non-superseded rows only) unless
        active_only=False, in which case the full correction history is
        included. `limit=0` means no limit.
        """
        table = "lab.event_active" if active_only else "lab.event"
        return db.select_from(table, {
            "event_id": event_id, "event_type": event_type,
            "subject_id": subject_id, "session_id": session_id,
        }, limit=limit)

    @app.tool()
    def get_event_detail(event_id: str) -> dict:
        """Fetch one event joined to its type-specific detail columns.

        E.g. a 'recording' event's row includes sample_rate_hz, n_channels,
        probe_id, etc. from lab.recording_event. The detail table is looked
        up from a fixed internal map of the 8 known event types -- never
        built from the event_type string directly.
        """
        rows = db.select_from("lab.event", {"event_id": event_id})
        if not rows:
            raise ValueError(f"No event with id {event_id}.")
        event_type = rows[0]["event_type"]
        if event_type not in schema_map.EVENT_DETAIL_TABLE:
            raise ValueError(f"Unknown event_type {event_type!r}.")
        detail_table = schema_map.EVENT_DETAIL_TABLE[event_type]
        detail_cols = schema_map.EVENT_DETAIL_COLUMNS[event_type]
        col_list = ", ".join(f"d.{c}" for c in detail_cols) or "NULL"
        sql = (
            f"SELECT e.*, {col_list} FROM lab.event e "
            f"JOIN {detail_table} d ON d.event_id = e.event_id "
            f"WHERE e.event_id = %s"
        )
        result = db.fetch_all(sql, [event_id])
        if not result:
            raise ValueError(f"Event {event_id} has no matching {detail_table} row.")
        return result[0]
