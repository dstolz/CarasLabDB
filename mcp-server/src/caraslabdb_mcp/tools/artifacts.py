"""Read tools for artifacts (files on the NAS) and their consumption/verification records."""

from typing import Optional

from .. import db
from . import OptText


def register(app):
    @app.tool()
    def get_artifacts(
        artifact_id: OptText = None,
        produced_by_event_id: OptText = None,
        subject_id: OptText = None,
        session_id: OptText = None,
        role: OptText = None,
        checksum: OptText = None,
        supersedes: OptText = None,
        created_from: OptText = None,
        created_before: OptText = None,
        tags: Optional[list[str]] = None,
        any_tags: Optional[list[str]] = None,
        none_tags: Optional[list[str]] = None,
        active_only: bool = True,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List artifacts (checksummed files on the NAS produced by an event).

        By default reads lab.artifact_active: current rows only, i.e.
        artifacts that no correction has replaced. With active_only=False it
        reads lab.artifact_version, the full correction history, and every
        row then carries `is_current` (false for a row that was corrected
        away) and `superseded_by` (the artifact_id of the correction that
        replaced it, else null) -- never treat a row with is_current=false
        as the current facts. Each row's own `supersedes` is the artifact_id
        it replaced; to find the correction of artifact X use supersedes=X
        with active_only=False. Ordered newest-first by created_at.

        checksum is a hex digest; case and surrounding whitespace are
        ignored (the database stores checksums lower-case), so the output of
        any hashing tool can be passed as is. subject_id and role are matched
        exactly, case included.

        created_from (inclusive) and created_before (exclusive) bound
        created_at, the time the file was registered. Each is an ISO-8601
        date or timestamp; a value without a UTC offset is read in the
        database session's time zone.

        A filter left out (or null) is simply not applied -- it does not
        mean "where this column IS NULL".

        Tag filters (current tags only; see get_tag_namespaces / get_tags):
        `tags` = the artifact must have ALL of these, `any_tags` = at least
        ONE of these, `none_tags` = NONE of these. A tag is `namespace:value`,
        lowercase (e.g. ["stage:raw", "qc:pass"]); a bare tag with no colon
        means `tag:<x>`; "namespace:*" matches any tag in that namespace
        (none_tags=["qc:*"] = not yet QC'd). Unset or empty lists are not
        applied. A tag that is not registered, or whose namespace does not
        exist or does not apply to artifacts, is an error naming the tag --
        never an empty or unfiltered result.

        Returns {"row_count": n, "limit": n, "truncated": bool, "rows":
        [...]}. `truncated` true means more rows matched than were returned:
        filter more narrowly or raise `limit` (max 1000).
        """
        if checksum is not None:
            # Stored lower-case (trg_artifact_normalize); PowerShell's
            # Get-FileHash, for one, prints upper-case.
            checksum = checksum.strip().lower()
        table = "lab.artifact_active" if active_only else "lab.artifact_version"
        return db.select_from(table, {
            "artifact_id": artifact_id, "produced_by_event_id": produced_by_event_id,
            "subject_id": subject_id, "session_id": session_id,
            "role": role, "checksum": checksum, "supersedes": supersedes,
        }, limit=limit, order_by=db.ORDER_BY_ARTIFACT,
            time_ranges={"created_at": (created_from, created_before)},
            tag_filters=("artifact", tags, any_tags, none_tags))

    @app.tool()
    def get_event_inputs(
        event_id: OptText = None,
        artifact_id: OptText = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List event<->artifact consumption edges (what artifacts an event read).

        Reads lab.event_input exactly as recorded, superseded rows included:
        there is no active_only toggle. An edge names the event and artifact
        rows that existed when it was written, so after a correction the
        edges of the superseded event remain next to those re-declared on
        its correction (the same consumption then appears under both event
        ids), and an edge may point at an artifact row that has since been
        corrected. Looking up the current row's id can therefore return
        nothing. For "what did this come from / what was made from this"
        use get_artifact_lineage, which follows corrections; use this tool
        for the edges as written, and get_events / get_artifacts with
        active_only=False to see whether an id is current.

        A filter left out (or null) is simply not applied -- it does not
        mean "where this column IS NULL". Ordered by event_id, artifact_id.
        Calling with neither id set walks the whole consumption table, so
        results are capped; see `truncated` in the returned {"row_count",
        "limit", "truncated", "rows"} envelope.
        """
        return db.select_from("lab.event_input", {
            "event_id": event_id, "artifact_id": artifact_id,
        }, limit=limit)

    @app.tool()
    def get_artifact_verifications(
        artifact_id: OptText = None,
        latest_per_file: bool = False,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List checksum verifications of artifacts (status ok/missing/mismatch).

        By default this is the verification log: one row per check, newest
        first by verified_at, each recorded against one artifact row. A
        check belongs to the file, though, and a correction gives the same
        file a new artifact row -- so the log for the current row's id can
        be empty although the file was checked.

        latest_per_file=True answers "what is the latest check of this
        file" instead (lab.artifact_verification_latest): one row per
        artifact whose file has ever been checked, taken across every
        artifact row describing the same file (same storage root, path and
        checksum), with `verified_artifact_id` naming the row the check was
        recorded against. An artifact with no row there has never been
        verified. Ordered by artifact_id.

        artifact_id left out (or null) means "do not filter" -- i.e. every
        artifact; the result is capped and reports `truncated` in the
        returned {"row_count", "limit", "truncated", "rows"} envelope.
        """
        if latest_per_file:
            return db.select_from("lab.artifact_verification_latest", {
                "artifact_id": artifact_id,
            }, limit=limit)
        return db.select_from("lab.artifact_verification", {
            "artifact_id": artifact_id,
        }, limit=limit, order_by=db.ORDER_BY_VERIFICATION)
