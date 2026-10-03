"""Read tool for the database's own integrity report."""

from .. import db


def register(app):
    @app.tool()
    def get_integrity_report(limit: int = db.DEFAULT_LIMIT) -> dict:
        """Run lab.fn_check_integrity(), the database's health check.

        An empty result means healthy. Each row is (severity, check_name,
        subject, detail): severity is "error" or "warning", and subject is the
        id (or storage_root:path) of the offending row. Checks:

        - event_missing_detail (error): a typed event with no detail row.
        - event_missing_subject (warning): a non-analysis event with no
          subject (rows predating that rule).
        - artifact_verification_failed (error): the latest checksum check of
          an active artifact was "missing" or "mismatch".
        - event_recorded_before_occurred (warning): occurred_at is more than a
          day after recorded_at, usually a client clock or time-zone bug.
        - artifact_never_verified (warning): an active artifact never checked.
        - artifact_producer_superseded (warning): an active artifact still
          attached to an event that has been corrected.
        - duplicate_active_path (warning): two active artifacts at one path.

        Errors are listed first. Returns {"rows", "row_count", "limit",
        "truncated"}; `truncated` true means more problems exist than were
        returned (raise `limit`, max 1000).
        """
        sql = (
            "SELECT severity, check_name, subject, detail "
            "FROM lab.fn_check_integrity() "
            "ORDER BY (severity = 'error') DESC, check_name, subject"
        )
        return db.fetch_limited(sql, [], limit=limit)
