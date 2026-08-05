"""Read tools for artifacts (files on the NAS) and their consumption/verification records."""

from typing import Optional

from .. import db


def register(app):
    @app.tool()
    def get_artifacts(
        artifact_id: Optional[str] = None,
        produced_by_event_id: Optional[str] = None,
        subject_id: Optional[str] = None,
        session_id: Optional[str] = None,
        role: Optional[str] = None,
        checksum: Optional[str] = None,
        active_only: bool = True,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List artifacts (checksummed files on the NAS produced by an event).

        Reads lab.artifact_active (non-superseded rows only) unless
        active_only=False. Ordered newest-first by created_at.

        A filter left as None is simply not applied -- it does not mean
        "where this column IS NULL".

        Returns {"rows": [...], "row_count": n, "limit": n, "truncated":
        bool}. `truncated` true means more rows matched than were returned:
        filter more narrowly or raise `limit` (max 1000).
        """
        table = "lab.artifact_active" if active_only else "lab.artifact"
        return db.select_from(table, {
            "artifact_id": artifact_id, "produced_by_event_id": produced_by_event_id,
            "subject_id": subject_id, "session_id": session_id,
            "role": role, "checksum": checksum,
        }, limit=limit, order_by=db.ORDER_BY_ARTIFACT)

    @app.tool()
    def get_event_inputs(
        event_id: Optional[str] = None,
        artifact_id: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List event<->artifact consumption edges (what artifacts an event read).

        A filter left as None is simply not applied -- it does not mean
        "where this column IS NULL". Calling with neither id set walks the
        whole consumption table, so results are capped; see `truncated` in
        the returned {"rows", "row_count", "limit", "truncated"} envelope.
        """
        return db.select_from("lab.event_input", {
            "event_id": event_id, "artifact_id": artifact_id,
        }, limit=limit)

    @app.tool()
    def get_artifact_verifications(
        artifact_id: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List checksum verification history for an artifact (ok/missing/mismatch).

        Ordered newest-first by verified_at. artifact_id left as None means
        "do not filter" -- i.e. the whole verification log across every
        artifact, which grows by one row per artifact per verification run;
        the result is capped and reports `truncated` in the returned
        {"rows", "row_count", "limit", "truncated"} envelope.
        """
        return db.select_from("lab.artifact_verification", {
            "artifact_id": artifact_id,
        }, limit=limit, order_by=db.ORDER_BY_VERIFICATION)
