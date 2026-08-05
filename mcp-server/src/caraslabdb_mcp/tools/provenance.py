"""Read tools for walking the provenance DAG between events and artifacts."""

from typing import Optional

from .. import db


def register(app):
    @app.tool()
    def get_artifact_lineage(
        artifact_id: str,
        direction: str = "up",
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """Walk the provenance DAG from an artifact via lab.fn_artifact_lineage.

        direction="up" (default) returns ancestors -- the events/artifacts
        this one was derived from. direction="down" returns descendants --
        what was derived from it. Rows are (depth, event_id, artifact_id)
        ordered by depth, but event_id means a *different* thing per
        direction, so read them separately:

        - "up": depth 0 is (0, produced_by_event_id, artifact_id) -- the
          starting artifact paired with the event that produced it. At every
          depth, event_id is the event that PRODUCED that row's artifact.
        - "down": depth 0 is (0, NULL, artifact_id) -- the starting artifact
          with no event yet, since nothing has consumed it at depth 0. That
          NULL is expected, not missing data. At depth > 0, event_id is the
          event that CONSUMED the parent row's artifact and produced this
          row's artifact.

        Walks the raw lab.artifact / lab.event_input tables, so the lineage
        includes superseded rows -- there is no active_only toggle, because
        dropping a superseded link would break the chain it sits in.

        Returns {"rows": [...], "row_count": n, "limit": n, "truncated":
        bool}. `truncated` true means the walk was cut off mid-DAG (rows are
        depth-ordered, so the deepest ancestors/descendants are what's
        missing); raise `limit` (max 1000) to see the rest.
        """
        if direction not in ("up", "down"):
            raise ValueError('direction must be "up" or "down"')
        sql = (
            "SELECT depth, event_id, artifact_id "
            "FROM lab.fn_artifact_lineage(%s::uuid, %s) ORDER BY depth"
        )
        return db.fetch_limited(sql, [artifact_id, direction], limit=limit)

    @app.tool()
    def get_provenance_edges(
        from_id: Optional[str] = None,
        to_id: Optional[str] = None,
        edge_type: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List uniform produces/consumes edges from lab.provenance_edge.

        The view is defined over the raw lab.artifact / lab.event_input
        tables, so edges to and from superseded artifacts are included --
        this is full history, not the active-only slice that get_artifacts
        returns by default.

        A filter left as None is simply not applied -- it does not mean
        "where this column IS NULL". Calling with no filters at all returns
        the whole edge list, so results are capped; check `truncated` in the
        returned {"rows", "row_count", "limit", "truncated"} envelope.
        """
        return db.select_from("lab.provenance_edge", {
            "from_id": from_id, "to_id": to_id, "edge_type": edge_type,
        }, limit=limit)
