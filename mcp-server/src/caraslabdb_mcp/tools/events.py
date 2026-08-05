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
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List base event rows (event_type, subject/session, occurred_at, ...).

        Reads lab.event_active (non-superseded rows only) unless
        active_only=False, in which case the full correction history is
        included. Ordered newest-first by occurred_at.

        A filter left as None is simply not applied -- it does not mean
        "where this column IS NULL".

        Returns {"rows": [...], "row_count": n, "limit": n, "truncated":
        bool}. `truncated` true means more rows matched than were returned:
        filter more narrowly or raise `limit` (max 1000).
        """
        table = "lab.event_active" if active_only else "lab.event"
        return db.select_from(table, {
            "event_id": event_id, "event_type": event_type,
            "subject_id": subject_id, "session_id": session_id,
        }, limit=limit, order_by=db.ORDER_BY_EVENT)

    @app.tool()
    def get_event_detail(event_id: str, active_only: bool = True) -> dict:
        """Fetch one event joined to its type-specific detail columns.

        E.g. a 'recording' event's row includes sample_rate_hz, n_channels,
        probe_id, etc. from lab.recording_event. The detail table is looked
        up from a fixed internal map of the 8 known event types -- never
        built from the event_type string directly.

        Reads lab.event_active by default, so a superseded (corrected-away)
        event reports as not found rather than being returned as if current.
        Pass active_only=False to look up a row by id regardless of whether
        a later correction replaced it.

        Single-row by construction, so this returns the row itself as a flat
        dict -- not the {"rows", ...} envelope the list tools return.
        """
        table = "lab.event_active" if active_only else "lab.event"
        result = db.select_from(table, {"event_id": event_id}, limit=1)
        rows = result["rows"]
        if not rows:
            # Under the default view an id that exists but has been corrected
            # away looks identical to one that never existed; say which.
            hint = ""
            if active_only:
                hint = " (it may exist but be superseded; retry with active_only=False)"
            raise ValueError(f"No event with id {event_id}{hint}.")
        event_type = rows[0]["event_type"]
        if event_type not in schema_map.EVENT_DETAIL_TABLE:
            raise ValueError(f"Unknown event_type {event_type!r}.")
        detail_table = schema_map.EVENT_DETAIL_TABLE[event_type]
        detail_cols = schema_map.EVENT_DETAIL_COLUMNS[event_type]
        col_list = ", ".join(f"d.{c}" for c in detail_cols) or "NULL"
        sql = (
            f"SELECT e.*, {col_list} FROM {table} e "
            f"JOIN {detail_table} d ON d.event_id = e.event_id "
            f"WHERE e.event_id = %s"
        )
        detail = db.fetch_all(sql, [event_id])
        if not detail:
            raise ValueError(f"Event {event_id} has no matching {detail_table} row.")
        return detail[0]
