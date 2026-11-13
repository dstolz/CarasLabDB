"""Read tool for the database's own integrity report."""

from .. import db


def register(app):
    @app.tool()
    def get_integrity_report(limit: int = db.DEFAULT_LIMIT) -> dict:
        """Run lab.fn_check_integrity(), the database's health check.

        An empty result means healthy. Each row is (severity, check_name,
        subject, detail): severity is "error" or "warning", and subject is the
        id (or storage_root:path) of the offending row. The 11 checks:

        - event_missing_detail (error): a typed event with no detail row.
        - artifact_verification_failed (error): the latest checksum check of
          an active artifact's file was "missing" or "mismatch". By file,
          not by row: the check follows the file across corrections.
        - tag_cardinality_violation (error): an entity has more than one
          current tag in a single-valued namespace.
        - event_missing_subject (warning): a non-analysis event with no
          subject (rows predating that rule).
        - event_recorded_before_occurred (warning): occurred_at is more than a
          day after recorded_at, usually a client clock or time-zone bug.
        - artifact_never_verified (warning): the file of an active artifact
          has never been checked (again by file).
        - artifact_producer_superseded (warning): an active artifact still
          attached to an event that has been corrected.
        - artifact_event_mismatch (warning): an active artifact filed under
          a different subject or session than the event that produced it.
        - tag_not_carried_forward (warning): a correction whose predecessor
          has current tags that were never copied onto it.
        - input_not_carried_forward (warning): a correction that declares no
          inputs although the event it replaced consumed artifacts, so
          lineage through it stops.
        - duplicate_active_path (warning): two active artifacts at one path.

        Errors are listed first, then by check_name and subject. Returns
        {"row_count", "limit", "truncated", "rows"}; `truncated` true means
        more problems exist than were returned (raise `limit`, max 1000).
        """
        sql = (
            "SELECT severity, check_name, subject, detail "
            "FROM lab.fn_check_integrity() "
            "ORDER BY (severity = 'error') DESC, check_name, subject, detail"
        )
        return db.fetch_limited(sql, [], limit=limit)
