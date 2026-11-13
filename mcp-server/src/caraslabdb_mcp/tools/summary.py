"""Exact counts for a fixed set of questions.

Every list tool stops at 1000 rows, so "how many recordings are there" cannot
be answered by listing. get_counts answers a fixed, allowlisted set of such
questions with aggregate SQL that is written out in full below: the caller
picks a question by name and may narrow it with bound values, but supplies no
identifier, and each question's SQL is a literal of this module.
"""

from .. import db
from . import OptText

# Active (current) events / artifacts, or every row ever written. Both are
# fixed relation names chosen by a boolean, never by caller text.
_EVENTS = {True: "lab.event_active", False: "lab.event"}
_ARTIFACTS = {True: "lab.artifact_active", False: "lab.artifact"}

# A current tag or variable value counts under active_only only if the event
# or artifact it is on is itself current. Fixed text; `c` is the view's alias.
_ACTIVE_ENTITY = (
    "(NOT %s OR ((c.entity_kind <> 'event' OR EXISTS "
    "(SELECT 1 FROM lab.event_active x WHERE x.event_id = c.event_id)) "
    "AND (c.entity_kind <> 'artifact' OR EXISTS "
    "(SELECT 1 FROM lab.artifact_active x WHERE x.artifact_id = c.artifact_id))))"
)


def _events_by_type(active_only, subject_id, project_id, entity_kind):
    sql = (
        "SELECT e.event_type, count(*) AS n "
        f"FROM {_EVENTS[active_only]} e "
        "LEFT JOIN lab.subject s ON s.subject_id = e.subject_id "
        "WHERE (%s::text IS NULL OR e.subject_id = %s::text) "
        "AND (%s::uuid IS NULL OR s.project_id = %s::uuid) "
        "GROUP BY e.event_type ORDER BY e.event_type")
    return sql, [subject_id, subject_id, project_id, project_id]


def _artifacts_by_role(active_only, subject_id, project_id, entity_kind):
    # An artifact names its subject directly, through its session, or (a
    # cross-animal analysis output) not at all.
    sql = (
        "SELECT a.role, count(*) AS n, sum(a.size_bytes) AS total_size_bytes, "
        "count(a.size_bytes) AS n_with_size "
        f"FROM {_ARTIFACTS[active_only]} a "
        "LEFT JOIN lab.session se ON se.session_id = a.session_id "
        "LEFT JOIN lab.subject s ON s.subject_id = coalesce(a.subject_id, se.subject_id) "
        "WHERE (%s::text IS NULL OR s.subject_id = %s::text) "
        "AND (%s::uuid IS NULL OR s.project_id = %s::uuid) "
        "GROUP BY a.role ORDER BY a.role NULLS LAST")
    return sql, [subject_id, subject_id, project_id, project_id]


def _subjects_by_project_species(active_only, subject_id, project_id, entity_kind):
    sql = (
        "SELECT s.project_id, p.name AS project_name, s.species_code, count(*) AS n "
        "FROM lab.subject s JOIN lab.project p ON p.project_id = s.project_id "
        "WHERE (%s::uuid IS NULL OR s.project_id = %s::uuid) "
        "GROUP BY s.project_id, p.name, s.species_code "
        "ORDER BY p.name, s.project_id, s.species_code NULLS LAST")
    return sql, [project_id, project_id]


def _sessions_per_subject(active_only, subject_id, project_id, entity_kind):
    sql = (
        "SELECT s.subject_id, count(se.session_id) AS n "
        "FROM lab.subject s LEFT JOIN lab.session se ON se.subject_id = s.subject_id "
        "WHERE (%s::text IS NULL OR s.subject_id = %s::text) "
        "AND (%s::uuid IS NULL OR s.project_id = %s::uuid) "
        "GROUP BY s.subject_id ORDER BY s.subject_id")
    return sql, [subject_id, subject_id, project_id, project_id]


def _current_tags_by_tag(active_only, subject_id, project_id, entity_kind):
    sql = (
        "SELECT c.entity_kind, c.tag, c.display_tag, count(*) AS n "
        "FROM lab.tag_current c "
        f"WHERE (%s::text IS NULL OR c.entity_kind = %s::text) AND {_ACTIVE_ENTITY} "
        "GROUP BY c.entity_kind, c.tag, c.display_tag ORDER BY c.entity_kind, c.tag")
    return sql, [entity_kind, entity_kind, active_only]


def _current_variables_by_variable(active_only, subject_id, project_id, entity_kind):
    sql = (
        "SELECT c.entity_kind, c.variable, c.label, c.units, c.value_type, count(*) AS n, "
        "min(c.value_num) AS min_value_num, max(c.value_num) AS max_value_num "
        "FROM lab.variable_current c "
        f"WHERE (%s::text IS NULL OR c.entity_kind = %s::text) AND {_ACTIVE_ENTITY} "
        "GROUP BY c.entity_kind, c.variable, c.label, c.units, c.value_type "
        "ORDER BY c.entity_kind, c.variable")
    return sql, [entity_kind, entity_kind, active_only]


# question -> (SQL builder, the optional arguments it accepts). Passing an
# argument a question does not use is an error, not a silent no-op.
QUESTIONS = {
    "events_by_type": (_events_by_type, {"subject_id", "project_id"}),
    "artifacts_by_role": (_artifacts_by_role, {"subject_id", "project_id"}),
    "subjects_by_project_species": (_subjects_by_project_species, {"project_id"}),
    "sessions_per_subject": (_sessions_per_subject, {"subject_id", "project_id"}),
    "current_tags_by_tag": (_current_tags_by_tag, {"entity_kind"}),
    "current_variables_by_variable": (_current_variables_by_variable, {"entity_kind"}),
}


def register(app):
    @app.tool()
    def get_counts(
        question: str,
        subject_id: OptText = None,
        project_id: OptText = None,
        entity_kind: OptText = None,
        active_only: bool = True,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """Exact counts for a fixed set of questions -- not limited to 1000 rows.

        The list tools return at most 1000 rows per call, so use this to
        count. `question` is one of:

        - "events_by_type": one row per event_type with n. Optional
          subject_id, project_id (the event's subject's project).
        - "artifacts_by_role": one row per role (null last) with n,
          total_size_bytes (exact, a decimal string; sums only files whose
          size is recorded) and n_with_size. Optional subject_id, project_id
          (the artifact's subject, directly or through its session).
        - "subjects_by_project_species": one row per (project, species) with
          project_id, project_name, species_code and n. Optional project_id.
        - "sessions_per_subject": one row per subject with n (subjects with
          no session included, n = 0). Optional subject_id, project_id.
        - "current_tags_by_tag": one row per (entity_kind, tag) with
          display_tag and n, the number of entities currently carrying it.
          Optional entity_kind.
        - "current_variables_by_variable": one row per (entity_kind,
          variable) with label, units, value_type, n (entities with a
          current value) and, for numbers, min_value_num / max_value_num
          (exact decimal strings). Optional entity_kind.

        Any other question, or an argument the question does not take, is
        an error. subject_id is matched exactly, case included; project_id
        is a uuid (see get_projects); entity_kind is "event", "artifact",
        "subject", "session" or "project". active_only (default True) counts
        only current events and artifacts -- superseded and retracted rows
        are left out, also when they carry tags or variables; False counts
        every row ever written. It does not affect subjects and sessions,
        which are edited in place.

        Returns {"row_count", "limit", "truncated", "question", "rows"};
        each count in the rows is exact, and `truncated` is true only if
        there are more groups (rows) than `limit` (max 1000).
        """
        if question not in QUESTIONS:
            raise ValueError(
                f"Unknown question {question!r}; expected one of "
                f"{', '.join(QUESTIONS)}.")
        build, accepted = QUESTIONS[question]
        given = {k for k, v in (("subject_id", subject_id), ("project_id", project_id),
                                ("entity_kind", entity_kind)) if v is not None}
        if given - accepted:
            raise ValueError(
                f"Question {question!r} does not take {', '.join(sorted(given - accepted))}; "
                f"it takes {', '.join(sorted(accepted)) or 'no filters'}.")
        if entity_kind is not None:
            db.tag_pk(entity_kind)
        if project_id is not None:
            project_id = db.entity_id_value("project", project_id)
        sql, params = build(bool(active_only), subject_id, project_id, entity_kind)
        return db.fetch_limited(sql, params, limit=limit, extra={"question": question})
