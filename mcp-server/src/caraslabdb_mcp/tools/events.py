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
        cursor: OptText = None,
    ) -> dict:
        """List base event rows (event_type, subject/session, occurred_at, ...).

        By default reads lab.event_active: current rows only, i.e. events
        that no correction has replaced and that have not been retracted
        (withdrawn as entered in error; see get_retractions). With
        active_only=False it reads lab.event_version, the full history, and
        every row then carries `is_current` (false for a row that was
        corrected away or retracted), `superseded_by` (the event_id of the
        correction that replaced it, else null) and `is_retracted` -- never
        treat a row with is_current=false as the current facts. Each row's
        own `supersedes` is the event_id it replaced. Ordered newest-first by
        occurred_at, then event_id.

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

        Returns {"row_count", "limit", "truncated", "next_cursor", "rows"}.
        `truncated` true means more rows matched than were returned: to get
        the next page call again with the same arguments and
        cursor=<next_cursor> (null when nothing is left); `limit` (max 1000)
        caps each page. To count events rather than list them use
        get_counts(question="events_by_type").
        """
        table = "lab.event_active" if active_only else "lab.event_version"
        return db.select_from(table, {
            "event_id": event_id, "event_type": event_type,
            "subject_id": subject_id, "session_id": session_id,
            "supersedes": supersedes,
        }, limit=limit, order_by=db.ORDER_BY_EVENT,
            time_ranges={"occurred_at": (occurred_from, occurred_before)},
            tag_filters=("event", tags, any_tags, none_tags), paged=True, cursor=cursor)

    @app.tool()
    def get_event_detail(event_id: str, active_only: bool = True) -> dict:
        """Fetch one event joined to its type-specific detail columns.

        E.g. a 'recording' event's row includes sample_rate_hz, n_channels,
        probe_id, etc. from lab.recording_event. The detail table is looked
        up from a fixed internal map of the 9 known event types -- never
        built from the event_type string directly.

        The row always carries `is_current`, `superseded_by`,
        `is_retracted`, and the retraction's `retraction_reason`,
        `retracted_at` and `retracted_by` (null unless it was retracted). By
        default only a current event is returned: for one that a correction
        has replaced the call fails with an error naming the event that
        superseded it, and for one that was retracted (withdrawn as entered
        in error) with an error saying so and giving the recorded reason --
        so stale or withdrawn values are never returned as if current. Pass
        active_only=False to read such a row as it was recorded; it comes
        back with is_current=false and superseded_by / is_retracted saying
        why.

        Single-row by construction, so this returns the row itself as a flat
        dict -- not the {"row_count", ..., "rows"} envelope the list tools
        return. If the database is at another schema version than this
        server was written for, the dict starts with a `schema_warning`.
        """
        # All lookups share one read-only transaction, so they see the same
        # snapshot even if a correction is committed in between.
        with db.read_only_cursor() as cur:
            cur.execute(
                "SELECT e.event_type, e.is_current, e.superseded_by, e.is_retracted, "
                "r.reason, r.retracted_at "
                "FROM lab.event_version e LEFT JOIN lab.retraction r ON r.event_id = e.event_id "
                "WHERE e.event_id = %s", [event_id])
            found = db.rows(cur)
            if not found:
                raise ValueError(f"No event with id {event_id}.")
            head = found[0]
            if active_only and not head["is_current"]:
                # Under the default an id that has been corrected away used to
                # look identical to one that never existed; say which, and
                # where the current values are.
                retracted = (f" It had been retracted at {head['retracted_at']}: "
                             f"{head['reason']!r}." if head["is_retracted"] else "")
                if head["superseded_by"] is not None:
                    raise ValueError(
                        f"Event {event_id} has been superseded by event "
                        f"{head['superseded_by']}: read that one for the current "
                        f"values, or pass active_only=False to read this "
                        f"superseded row as it was recorded.{retracted}")
                raise ValueError(
                    f"Event {event_id} was retracted (withdrawn as entered in error) "
                    f"at {head['retracted_at']}, reason: {head['reason']!r}. It is "
                    f"not part of the current record; pass active_only=False to "
                    f"read it as it was recorded.")
            event_type = head["event_type"]
            if event_type not in schema_map.EVENT_DETAIL_TABLE:
                raise ValueError(f"Unknown event_type {event_type!r}.")
            detail_table = schema_map.EVENT_DETAIL_TABLE[event_type]
            detail_cols = schema_map.EVENT_DETAIL_COLUMNS[event_type]
            col_list = ", ".join(f"d.{c}" for c in detail_cols) or "NULL"
            cur.execute(
                f"SELECT e.*, r.reason AS retraction_reason, r.retracted_at, "
                f"r.retracted_by, {col_list} FROM lab.event_version e "
                f"JOIN {detail_table} d ON d.event_id = e.event_id "
                f"LEFT JOIN lab.retraction r ON r.event_id = e.event_id "
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

    @app.tool()
    def get_retractions(
        entity_kind: OptText = None,
        event_id: OptText = None,
        artifact_id: OptText = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List retractions: events and artifacts withdrawn as entered in error.

        A retraction (lab.retraction) withdraws a row that should never have
        been written -- an event entered twice, a file registered by mistake
        -- with the reason. It is permanent and is not a correction: nothing
        replaces the row. Retracted rows are left out of every default
        (active_only=True) read: get_events, get_artifacts, find_by_tags,
        get_variables / find_by_variable across entities and get_counts. With
        active_only=False they come back with is_retracted=true and
        is_current=false. Retracting an event does not retract the files it
        produced (get_integrity_report flags those as
        artifact_producer_retracted). A retracted row can later be
        superseded, which brings a corrected version back as a current row.

        entity_kind is "event" or "artifact" (anything else is an error);
        event_id / artifact_id select the retraction of one row. Rows carry
        retraction_id, entity_kind, event_id, artifact_id, reason,
        retracted_at, retracted_by (person_id) and retracted_login (the
        database login that recorded it). A filter left out (or null) is not
        applied. Ordered newest first by retracted_at, then retraction_id.

        Returns {"row_count", "limit", "truncated", "rows"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        if entity_kind is not None and entity_kind not in ("event", "artifact"):
            raise ValueError(
                f"entity_kind must be 'event' or 'artifact', got {entity_kind!r}: "
                f"only events and artifacts can be retracted.")
        return db.select_from("lab.retraction", {
            "entity_kind": entity_kind, "event_id": event_id, "artifact_id": artifact_id,
        }, limit=limit)
