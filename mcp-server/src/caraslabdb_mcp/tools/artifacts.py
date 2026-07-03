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
        limit: int = 0,
    ) -> list[dict]:
        """List artifacts (checksummed files on the NAS produced by an event).

        Reads lab.artifact_active (non-superseded rows only) unless
        active_only=False. `limit=0` means no limit.
        """
        table = "lab.artifact_active" if active_only else "lab.artifact"
        return db.select_from(table, {
            "artifact_id": artifact_id, "produced_by_event_id": produced_by_event_id,
            "subject_id": subject_id, "session_id": session_id,
            "role": role, "checksum": checksum,
        }, limit=limit)

    @app.tool()
    def get_event_inputs(
        event_id: Optional[str] = None,
        artifact_id: Optional[str] = None,
    ) -> list[dict]:
        """List event<->artifact consumption edges (what artifacts an event read)."""
        return db.select_from("lab.event_input", {
            "event_id": event_id, "artifact_id": artifact_id,
        })

    @app.tool()
    def get_artifact_verifications(artifact_id: Optional[str] = None) -> list[dict]:
        """List checksum verification history for an artifact (ok/missing/mismatch)."""
        return db.select_from("lab.artifact_verification", {"artifact_id": artifact_id})
