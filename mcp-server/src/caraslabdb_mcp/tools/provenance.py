"""Read tools for walking the provenance DAG between events and artifacts."""

from .. import db
from . import OptText


def register(app):
    @app.tool()
    def get_artifact_lineage(
        artifact_id: str,
        direction: str = "up",
        follow_corrections: bool = True,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """Walk the provenance DAG from an artifact via lab.fn_artifact_lineage.

        direction="up" (default) returns ancestors -- the events/artifacts
        this one was derived from. direction="down" returns descendants --
        what was derived from it. Rows are (depth, event_id, artifact_id)
        ordered by depth, then event_id, artifact_id; event_id means a
        *different* thing per direction, so read them separately:

        - "up": depth 0 is (0, producing event, the artifact). At every
          depth, event_id is the event that PRODUCED that row's artifact.
        - "down": depth 0 is (0, NULL, the artifact) -- no event yet, since
          nothing has consumed it at depth 0. That NULL is expected, not
          missing data. At depth > 0, event_id is the event that CONSUMED
          the parent row's artifact and produced this row's artifact.

        follow_corrections=True (default): the walk is over CURRENT rows,
        whichever version artifact_id names, and every event_id and
        artifact_id returned is a current (non-superseded) one. Provenance
        edges are never rewritten, so after a correction they still name the
        superseded rows; with this default each node stands for its whole
        correction chain: depth 0 is the current version of the artifact you
        passed (its id differs from yours if you passed a superseded one),
        an artifact's producer is the current version of its producing
        event, an event's inputs are those its current version declares, and
        an artifact's consumers are the current events that consumed ANY
        version of it. The ids can be passed straight to get_artifacts /
        get_event_detail.

        follow_corrections=False: the walk is over the rows exactly as
        recorded, superseded ones included, starting from exactly the row
        named -- the audit view. It can stop short: the current row of a
        corrected artifact has no recorded consumers (they consumed the row
        it replaced), and ids it returns may be superseded (check with
        get_artifacts(active_only=False) -> is_current).

        Retracted rows (see get_retractions): with follow_corrections=True a
        "down" walk skips retracted consumers and products, but an "up" walk
        still returns a retracted ancestor -- it is what the artifact was in
        fact made from; get_artifacts(artifact_id=..., active_only=False)
        shows is_retracted, and get_integrity_report flags such inputs
        (input_retracted).

        An unknown artifact_id returns no rows (an existing one always has
        its depth-0 row). The walk stops at depth 64.

        Returns {"row_count": n, "limit": n, "truncated": bool, "rows":
        [...]}. `truncated` true means the walk was cut off mid-DAG (rows are
        depth-ordered, so the deepest ancestors/descendants are what's
        missing); raise `limit` (max 1000) to see the rest.
        """
        if direction not in ("up", "down"):
            raise ValueError('direction must be "up" or "down"')
        sql = (
            "SELECT depth, event_id, artifact_id "
            "FROM lab.fn_artifact_lineage(%s::uuid, %s, %s) "
            "ORDER BY depth, event_id, artifact_id"
        )
        return db.fetch_limited(
            sql, [artifact_id, direction, bool(follow_corrections)], limit=limit)

    @app.tool()
    def get_provenance_edges(
        from_id: OptText = None,
        to_id: OptText = None,
        edge_type: OptText = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List uniform produces/consumes edges from lab.provenance_edge.

        edge_type is "produces" (from an event to an artifact) or "consumes"
        (from an artifact to an event). The view reads the rows exactly as
        recorded, superseded and retracted ones included: edges to and from superseded
        events and artifacts are all here, a corrected event and its
        correction each have their own edges, and there is no active_only
        toggle -- this is the full recorded graph, not the current one. Use
        get_artifact_lineage (which follows corrections by default) to walk
        the current graph, and get_events / get_artifacts with
        active_only=False to see whether an id is current.

        A filter left out (or null) is simply not applied -- it does not
        mean "where this column IS NULL". Ordered by edge_type, from_id,
        to_id. Calling with no filters at all returns the whole edge list,
        so results are capped; check `truncated` in the returned
        {"row_count", "limit", "truncated", "rows"} envelope.
        """
        return db.select_from("lab.provenance_edge", {
            "from_id": from_id, "to_id": to_id, "edge_type": edge_type,
        }, limit=limit)
