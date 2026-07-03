"""Reference/lookup table tools -- small, static, rarely-changing vocab tables."""

from typing import Optional

from .. import db


def register(app):
    @app.tool()
    def get_species() -> list[dict]:
        """List all species reference rows (code, common_name)."""
        return db.select_from("lab.species", {})

    @app.tool()
    def get_storage_roots() -> list[dict]:
        """List all NAS storage roots (root_id, name, description)."""
        return db.select_from("lab.storage_root", {})

    @app.tool()
    def get_probes(probe_id: Optional[str] = None) -> list[dict]:
        """List probes, optionally filtered by probe_id."""
        return db.select_from("lab.probe", {"probe_id": probe_id})

    @app.tool()
    def get_pipelines(pipeline_id: Optional[str] = None, name: Optional[str] = None) -> list[dict]:
        """List analysis pipelines, optionally filtered by pipeline_id or name."""
        return db.select_from("lab.pipeline", {"pipeline_id": pipeline_id, "name": name})

    @app.tool()
    def get_event_types() -> list[dict]:
        """List the 8 known event type codes/labels (birth, surgery, recording, ...)."""
        return db.select_from("lab.event_type", {})

    @app.tool()
    def get_artifact_roles() -> list[dict]:
        """List artifact role codes/labels (raw, spikes, lfp, waveforms, ...)."""
        return db.select_from("lab.artifact_role", {})

    @app.tool()
    def get_acquisition_systems() -> list[dict]:
        """List acquisition system codes/labels (intan_rhx, open_ephys, ...)."""
        return db.select_from("lab.acquisition_system", {})
