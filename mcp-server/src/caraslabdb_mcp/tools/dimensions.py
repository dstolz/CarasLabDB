"""Read tools for people, projects, subjects, and sessions.

Only the per-tool docstrings reach the calling LLM, so the envelope and
None-filter notes are repeated in each one rather than stated once here.
"""

from typing import Optional

from .. import db


def register(app):
    @app.tool()
    def get_persons(
        person_id: Optional[str] = None,
        email: Optional[str] = None,
        full_name: Optional[str] = None,
        is_active: Optional[bool] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List lab members, optionally filtered by id, email, name, or active status.

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.person", {
            "person_id": person_id, "email": email,
            "full_name": full_name, "is_active": is_active,
        }, limit=limit)

    @app.tool()
    def get_projects(
        project_id: Optional[str] = None,
        name: Optional[str] = None,
        is_active: Optional[bool] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List projects, optionally filtered by id, name, or active status.

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.project", {
            "project_id": project_id, "name": name, "is_active": is_active,
        }, limit=limit)

    @app.tool()
    def get_project_members(
        project_id: Optional[str] = None,
        person_id: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List project<->person membership rows, optionally filtered by either id.

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.project_member", {
            "project_id": project_id, "person_id": person_id,
        }, limit=limit)

    @app.tool()
    def get_project_artifacts(
        project_id: Optional[str] = None,
        kind: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List project-level documents/links (files, google_doc, google_sheet, url).

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.project_artifact", {
            "project_id": project_id, "kind": kind,
        }, limit=limit)

    @app.tool()
    def get_subjects(
        subject_id: Optional[str] = None,
        project_id: Optional[str] = None,
        species_code: Optional[str] = None,
        sex: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List subjects (animals), optionally filtered by id, project, species, or sex.

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.subject", {
            "subject_id": subject_id, "project_id": project_id,
            "species_code": species_code, "sex": sex,
        }, limit=limit)

    @app.tool()
    def get_sessions(
        session_id: Optional[str] = None,
        subject_id: Optional[str] = None,
        label: Optional[str] = None,
        storage_root_id: Optional[int] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List sessions (NAS folders under a subject), optionally filtered.

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.session", {
            "session_id": session_id, "subject_id": subject_id,
            "label": label, "storage_root_id": storage_root_id,
        }, limit=limit)

    @app.tool()
    def get_subject_current(
        subject_id: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """Subject dimension enriched with latest weight and endpoint status.

        subject_id left as None is not applied as a filter -- it returns every
        subject, not subjects with a NULL id. Returns {"rows", "row_count",
        "limit", "truncated"}; `truncated` true means more rows matched than
        were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.subject_current", {
            "subject_id": subject_id,
        }, limit=limit)
