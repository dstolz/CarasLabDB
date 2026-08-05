"""Reference/lookup table tools -- small, static, rarely-changing vocab tables.

These tables are short enough that the default limit is unlikely to bite, but
they take the same `limit` and return the same envelope as every other tool:
a caller should never have to know which tables are "small" to know whether
it saw all the rows.
"""

from typing import Optional

from .. import db


def register(app):
    @app.tool()
    def get_species(limit: int = db.DEFAULT_LIMIT) -> dict:
        """List all species reference rows (code, common_name).

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows exist than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.species", {}, limit=limit)

    @app.tool()
    def get_storage_roots(limit: int = db.DEFAULT_LIMIT) -> dict:
        """List all NAS storage roots (root_id, name, description).

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows exist than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.storage_root", {}, limit=limit)

    @app.tool()
    def get_probes(
        probe_id: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List probes, optionally filtered by probe_id.

        probe_id left as None is not applied as a filter -- it never means
        "IS NULL". Returns {"rows", "row_count", "limit", "truncated"};
        `truncated` true means more rows matched than were returned.
        """
        return db.select_from("lab.probe", {"probe_id": probe_id}, limit=limit)

    @app.tool()
    def get_pipelines(
        pipeline_id: Optional[str] = None,
        name: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List analysis pipelines, optionally filtered by pipeline_id or name.

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned.
        """
        return db.select_from("lab.pipeline", {
            "pipeline_id": pipeline_id, "name": name,
        }, limit=limit)

    @app.tool()
    def get_event_types(limit: int = db.DEFAULT_LIMIT) -> dict:
        """List the 8 known event type codes/labels (birth, surgery, recording, ...).

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows exist than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.event_type", {}, limit=limit)

    @app.tool()
    def get_artifact_roles(limit: int = db.DEFAULT_LIMIT) -> dict:
        """List artifact role codes/labels (raw, spikes, lfp, waveforms, ...).

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows exist than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.artifact_role", {}, limit=limit)

    @app.tool()
    def get_acquisition_systems(limit: int = db.DEFAULT_LIMIT) -> dict:
        """List acquisition system codes/labels (intan_rhx, open_ephys, ...).

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows exist than were returned (raise `limit`, max 1000).
        """
        return db.select_from("lab.acquisition_system", {}, limit=limit)
