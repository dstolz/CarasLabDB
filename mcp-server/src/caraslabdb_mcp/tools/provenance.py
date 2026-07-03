"""Read tools for walking the provenance DAG between events and artifacts."""

from typing import Optional

from .. import db


def register(app):
    @app.tool()
    def get_artifact_lineage(artifact_id: str, direction: str = "up") -> list[dict]:
        """Walk the provenance DAG from an artifact via lab.fn_artifact_lineage.

        direction="up" (default) returns ancestors -- the events/artifacts
        this one was derived from. direction="down" returns descendants --
        what was derived from it. Returns rows of (depth, event_id,
        artifact_id) ordered by depth (0 = the artifact itself).
        """
        if direction not in ("up", "down"):
            raise ValueError('direction must be "up" or "down"')
        sql = (
            "SELECT depth, event_id, artifact_id "
            "FROM lab.fn_artifact_lineage(%s::uuid, %s) ORDER BY depth"
        )
        return db.fetch_all(sql, [artifact_id, direction])

    @app.tool()
    def get_provenance_edges(
        from_id: Optional[str] = None,
        to_id: Optional[str] = None,
        edge_type: Optional[str] = None,
    ) -> list[dict]:
        """List uniform produces/consumes edges from lab.provenance_edge."""
        return db.select_from("lab.provenance_edge", {
            "from_id": from_id, "to_id": to_id, "edge_type": edge_type,
        })
