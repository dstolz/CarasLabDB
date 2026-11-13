"""Read tools for people, projects, subjects, and sessions.

Only the per-tool docstrings reach the calling LLM, so the envelope and
None-filter notes are repeated in each one rather than stated once here.
"""

from typing import Optional

from .. import db
from . import OptText


def register(app):
    @app.tool()
    def get_persons(
        person_id: OptText = None,
        email: OptText = None,
        full_name: OptText = None,
        is_active: Optional[bool] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List lab members, optionally filtered by id, email, name, or active status.

        Each row is a lab.person: person_id (what recorded_by, created_by,
        set_by, applied_by, retracted_by ... in other tables refer to),
        full_name, email, role, is_active, created_at, and db_login -- the
        PostgreSQL login this person connects to the database with (null if
        none is mapped). db_login is what the *_login columns elsewhere
        (recorded_login, created_login, applied_login, set_login, ...)
        record, so it ties "who was connected" to a person; it is not a
        password or credential.

        email matches case-insensitively, as the database's uniqueness rule
        does ("Dan@umd.edu" and "dan@umd.edu" are one person); full_name is
        matched exactly, case included.
        A filter left out (or null) is not applied -- it never means "IS NULL".
        Ordered by full_name. Returns {"row_count", "limit", "truncated",
        "rows"}; `truncated` true means more rows matched than were returned
        (raise `limit`, max 1000).
        """
        return db.select_from("lab.person", {
            "person_id": person_id,
            "full_name": full_name, "is_active": is_active,
        }, limit=limit, ci_filters={"email": email})

    @app.tool()
    def get_projects(
        project_id: OptText = None,
        name: OptText = None,
        is_active: Optional[bool] = None,
        tags: Optional[list[str]] = None,
        any_tags: Optional[list[str]] = None,
        none_tags: Optional[list[str]] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List projects, optionally filtered by id, name, active status, or tags.

        name is matched exactly, case included. A filter left out (or null)
        is not applied -- it never means "IS NULL". Ordered by name.

        Tag filters (current tags only; see get_tag_namespaces / get_tags):
        `tags` = the project must have ALL of these, `any_tags` = at least
        ONE of these, `none_tags` = NONE of these. A tag is `namespace:value`,
        lowercase (e.g. ["topic:x", "auditory_cortex"]); a bare tag with no colon
        means `tag:<x>`; "namespace:*" matches any tag in that namespace
        (none_tags=["topic:*"] = no topic tag). Unset or empty lists are not
        applied. A tag that is not registered, or whose namespace does not
        exist or does not apply to projects, is an error naming the tag --
        never an empty or unfiltered result.

        Returns {"row_count", "limit", "truncated", "rows"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.project", {
            "project_id": project_id, "name": name, "is_active": is_active,
        }, limit=limit, tag_filters=("project", tags, any_tags, none_tags))

    @app.tool()
    def get_project_members(
        project_id: OptText = None,
        person_id: OptText = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List project<->person membership rows, optionally filtered by either id.

        A filter left out (or null) is not applied -- it never means "IS NULL".
        Ordered by project_id, person_id. Returns {"row_count", "limit",
        "truncated", "rows"}; `truncated` true means more rows matched than
        were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.project_member", {
            "project_id": project_id, "person_id": person_id,
        }, limit=limit)

    @app.tool()
    def get_project_artifacts(
        project_id: OptText = None,
        kind: OptText = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List project-level documents/links (file, google_doc, google_sheet, url, other).

        A filter left out (or null) is not applied -- it never means "IS NULL".
        Ordered by project_id, title. Returns {"row_count", "limit",
        "truncated", "rows"}; `truncated` true means more rows matched than
        were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.project_artifact", {
            "project_id": project_id, "kind": kind,
        }, limit=limit)

    @app.tool()
    def get_subjects(
        subject_id: OptText = None,
        project_id: OptText = None,
        species_code: OptText = None,
        sex: OptText = None,
        tags: Optional[list[str]] = None,
        any_tags: Optional[list[str]] = None,
        none_tags: Optional[list[str]] = None,
        limit: int = db.DEFAULT_LIMIT,
        cursor: OptText = None,
    ) -> dict:
        """List subjects (animals), optionally filtered by id, project, species, sex, or tags.

        subject_id is the lab's own id for the animal and is matched exactly,
        case included ("G-0421" is not "g-0421"); sex is 'M', 'F' or 'U'.
        A filter left out (or null) is not applied -- it never means "IS NULL".
        Ordered by subject_id. Counts by project and species:
        get_counts(question="subjects_by_project_species").

        Tag filters (current tags only; see get_tag_namespaces / get_tags):
        `tags` = the subject must have ALL of these, `any_tags` = at least
        ONE of these, `none_tags` = NONE of these. A tag is `namespace:value`,
        lowercase (e.g. ["cohort:a", "topic:x"]); a bare tag with no colon
        means `tag:<x>`; "namespace:*" matches any tag in that namespace
        (none_tags=["topic:*"] = no topic tag). Unset or empty lists are not
        applied. A tag that is not registered, or whose namespace does not
        exist or does not apply to subjects, is an error naming the tag --
        never an empty or unfiltered result.

        Returns {"row_count", "limit", "truncated", "next_cursor", "rows"}.
        `truncated` true means more rows matched than were returned: call
        again with the same arguments and cursor=<next_cursor> for the next
        page (null when nothing is left); `limit` (max 1000) caps each page.
        """
        return db.select_from("lab.subject", {
            "subject_id": subject_id, "project_id": project_id,
            "species_code": species_code, "sex": sex,
        }, limit=limit, tag_filters=("subject", tags, any_tags, none_tags),
            paged=True, cursor=cursor)

    @app.tool()
    def get_sessions(
        session_id: OptText = None,
        subject_id: OptText = None,
        label: OptText = None,
        storage_root_id: Optional[int] = None,
        tags: Optional[list[str]] = None,
        any_tags: Optional[list[str]] = None,
        none_tags: Optional[list[str]] = None,
        limit: int = db.DEFAULT_LIMIT,
        cursor: OptText = None,
    ) -> dict:
        """List sessions (NAS folders under a subject), optionally filtered.

        subject_id and label are matched exactly, case included. A filter
        left out (or null) is not applied -- it never means "IS NULL".
        Ordered by subject_id, label. Counts per subject:
        get_counts(question="sessions_per_subject").

        Tag filters (current tags only; see get_tag_namespaces / get_tags):
        `tags` = the session must have ALL of these, `any_tags` = at least
        ONE of these, `none_tags` = NONE of these. A tag is `namespace:value`,
        lowercase (e.g. ["cohort:a", "qc:pass"]); a bare tag with no colon
        means `tag:<x>`; "namespace:*" matches any tag in that namespace
        (none_tags=["qc:*"] = not yet QC'd). Unset or empty lists are not
        applied. A tag that is not registered, or whose namespace does not
        exist or does not apply to sessions, is an error naming the tag --
        never an empty or unfiltered result.

        Returns {"row_count", "limit", "truncated", "next_cursor", "rows"}.
        `truncated` true means more rows matched than were returned: call
        again with the same arguments and cursor=<next_cursor> for the next
        page (null when nothing is left); `limit` (max 1000) caps each page.
        """
        return db.select_from("lab.session", {
            "session_id": session_id, "subject_id": subject_id,
            "label": label, "storage_root_id": storage_root_id,
        }, limit=limit, tag_filters=("session", tags, any_tags, none_tags),
            paged=True, cursor=cursor)

    @app.tool()
    def get_subject_current(
        subject_id: OptText = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """Subject dimension enriched with latest weight and endpoint status.

        subject_id is matched exactly, case included; left out (or null) it
        is not applied as a filter -- every subject is returned, not subjects
        with a NULL id. Ordered by subject_id. Returns {"row_count", "limit",
        "truncated", "rows"}; `truncated` true means more rows matched than
        were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.subject_current", {
            "subject_id": subject_id,
        }, limit=limit)
