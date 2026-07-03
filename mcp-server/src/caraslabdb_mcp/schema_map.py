"""Fixed internal map of event types to their detail tables/columns.

This is the one place `get_event_detail` needs a table name that depends on
data read from the database (the event's `event_type`). Rather than trust
that value directly, it is looked up in this hardcoded dict -- built by hand
from design_docs/schema.sql, not introspected at runtime -- so a caller can
never influence which table gets joined beyond the 8 known event types.
"""

EVENT_TYPES = (
    "birth", "surgery", "recording", "behavior",
    "husbandry", "endpoint", "histology", "analysis",
)

EVENT_DETAIL_TABLE = {t: f"lab.{t}_event" for t in EVENT_TYPES}

EVENT_DETAIL_COLUMNS = {
    "birth": ("dam_subject_id", "sire_subject_id", "litter_id", "birth_weight_g"),
    "surgery": (
        "procedure", "surgeon_id", "anesthesia", "target_region", "hemisphere",
        "stereotax_ap_mm", "stereotax_ml_mm", "stereotax_dv_mm", "probe_id", "outcome",
    ),
    "recording": (
        "acquisition_system_code", "probe_id", "modality", "sample_rate_hz",
        "n_channels", "duration_s", "stimulus_protocol", "hardware_config",
    ),
    "behavior": ("task", "paradigm", "stage", "trials_completed", "performance", "reward"),
    "husbandry": ("measure", "weight_g", "water_ml", "health_status"),
    "endpoint": ("method", "perfusion_fixative", "tissue_collected", "disposition"),
    "histology": ("technique", "target_region", "stain", "microscope"),
    "analysis": (
        "pipeline_id", "pipeline_name", "code_version", "parameters",
        "environment", "started_at", "finished_at", "status",
    ),
}
