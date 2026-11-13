"""Read tools for user-defined variables (lab.variable, lab.variable_value).

A variable is a named value lab members attach to an event, artifact,
subject, session or project ('probe depth' = 1200 um on a session, 'housing'
= 'pair' on an animal). The definition (lab.variable) gives its label, units,
value type ('number' or 'text') and the entity kinds it applies to. Values
are an append-only log (lab.variable_value: every 'set' and 'unset'), and an
entity's current values are lab.variable_current, the latest row per
(entity, variable) when it is a 'set'.

Variable names are compared in their canonical spelling, which the database
defines (lab.fn_canonical_variable: lower case, whitespace runs collapsed),
so 'Probe  Depth' and 'probe depth' are one variable. A name that is not
defined is an error listing the defined ones -- never an empty result that
looks like "no values".

Only the per-tool docstrings reach the calling LLM, so these notes are
repeated in each one.
"""

from .. import db
from . import OptNumber, OptText

# How many defined names an "unknown variable" error lists.
_NAMES_IN_ERROR = 100


def _resolve_variable(cur, name, kind):
    """The canonical name and definition of `name`; ValueError if unusable.

    Runs on the tool's own cursor, so the check and the query that uses its
    result share one read-only transaction.
    """
    cur.execute(
        "SELECT c.name, v.name IS NOT NULL AS defined, v.value_type, v.applies_to "
        "FROM (SELECT lab.fn_canonical_variable(%s) AS name) c "
        "LEFT JOIN lab.variable v ON v.name = c.name", [name])
    canonical, defined, value_type, applies_to = cur.fetchone()
    if not defined:
        cur.execute("SELECT name FROM lab.variable ORDER BY name LIMIT %s",
                    [_NAMES_IN_ERROR + 1])
        names = [r[0] for r in cur.fetchall()]
        listed = ", ".join(repr(n) for n in names[:_NAMES_IN_ERROR]) or "none"
        more = ", ..." if len(names) > _NAMES_IN_ERROR else ""
        raise ValueError(
            f"No variable named {canonical!r} is defined (nothing was queried). "
            f"Defined variables: {listed}{more}. See get_variable_definitions.")
    if kind not in applies_to:
        raise ValueError(
            f"Variable {canonical!r} applies to {', '.join(applies_to)} only, "
            f"not to {kind}.")
    return canonical, value_type


def register(app):
    @app.tool()
    def get_variable_definitions(
        entity_kind: OptText = None,
        include_retired: bool = False,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List the defined user variables (lab.variable): what can be set on what.

        A variable is a named value lab members attach to events, artifacts,
        subjects, sessions and projects ('probe depth' = 1200 um on a
        session). Each row: `name` (the canonical name, lower case with
        single spaces -- what get_variables / find_by_variable take; any
        spelling differing only in case or spacing means the same variable),
        `label` (the name shown to people), `description`, `units` (null =
        none), `value_type` ('number' or 'text'), `applies_to` (the entity
        kinds it may be set on), `retired_at` (set = takes no new values;
        existing values stay), `created_at`, `created_by`.

        entity_kind ("event", "artifact", "subject", "session" or "project")
        keeps only variables that apply to that kind. Retired variables are
        left out unless include_retired=True. Ordered by name.

        Returns {"row_count", "limit", "truncated", "rows"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        if entity_kind is not None:
            db.tag_pk(entity_kind)
        return db.fetch_limited(
            "SELECT name, label, description, units, value_type, applies_to, "
            "retired_at, created_at, created_by FROM lab.variable "
            "WHERE (%s OR retired_at IS NULL) "
            "AND (%s::text IS NULL OR %s::text = ANY (applies_to)) ORDER BY name",
            [include_retired, entity_kind, entity_kind], limit=limit)

    @app.tool()
    def get_variables(
        entity_kind: str,
        entity_id: OptText = None,
        name: OptText = None,
        current_only: bool = True,
        active_only: bool = True,
        limit: int = db.DEFAULT_LIMIT,
        cursor: OptText = None,
    ) -> dict:
        """User-variable values of one entity, of one variable across entities, or both.

        entity_kind is one of "event", "artifact", "subject", "session",
        "project" (anything else is an error). entity_id is that entity's id
        (a uuid, or the subject_id text for a subject, matched exactly).
        name is a variable name (see get_variable_definitions); case and
        spacing are ignored ('Probe  Depth' = 'probe depth'), and a name
        that is not defined, or does not apply to entity_kind, is an error
        listing the defined variables -- never an empty result. Give
        entity_id for "this session's variables", name for "every probe
        depth", both for one value, neither for every value of that kind.

        current_only=True (default): current values (lab.variable_current),
        one row per (entity, variable) with entity_id, variable, label,
        units, value_type, value_num (numbers, as exact decimal strings, e.g.
        "1200.50"), value_text, value (either, as text), note, set_at (when
        this value was set: its "last updated" time), set_by (person_id) and
        set_login. A variable that was unset has no row. Ordered by
        entity_kind, entity_id, variable.

        current_only=False: the full log (lab.variable_value), every 'set'
        and 'unset' row in the order written, oldest first by value_id, with
        op, value_num, value_text, note, set_at, set_by, set_login and the
        entity's typed id column (event_id, artifact_id, subject_id,
        session_id or project_id). The last row per entity and variable is
        the current state.

        active_only (default True) applies only when entity_id is left out
        and entity_kind is "event" or "artifact": values on superseded or
        retracted rows are then skipped (a correction carries its
        predecessor's values forward, so they would otherwise appear twice).
        A named entity_id is always read as named, whatever its state.

        Returns {"row_count", "limit", "truncated", "next_cursor", "rows"}.
        `truncated` true means more rows matched than were returned: call
        again with the same arguments and cursor=<next_cursor> for the next
        page (null when nothing is left); `limit` (max 1000) caps each page.
        Counts per variable: get_counts(question="current_variables_by_variable").
        """
        pk = db.tag_pk(entity_kind)
        entity_id = db.entity_id_value(entity_kind, entity_id)

        def resolve(cur):
            if name is None:
                return {}
            return {"variable": _resolve_variable(cur, name, entity_kind)[0]}

        active = (entity_kind if active_only and entity_id is None
                  and entity_kind in db.ACTIVE_ENTITY_CLAUSE else None)
        if current_only:
            table, order_by = "lab.variable_current", db.ORDER_BY_VARIABLE_CURRENT
        else:
            table, order_by = "lab.variable_value", db.ORDER_BY_VARIABLE_VALUE
        return db.select_from(
            table, {"entity_kind": entity_kind, pk: entity_id},
            limit=limit, order_by=order_by, active_entities=active,
            paged=True, cursor=cursor, resolve=resolve)

    @app.tool()
    def find_by_variable(
        entity_kind: str,
        name: str,
        equals: OptNumber = None,
        at_least: OptNumber = None,
        at_most: OptNumber = None,
        text_equals: OptText = None,
        active_only: bool = True,
        limit: int = db.DEFAULT_LIMIT,
        cursor: OptText = None,
    ) -> dict:
        """Find entities by the current value of a user variable.

        entity_kind is one of "event", "artifact", "subject", "session",
        "project"; name is a variable name (see get_variable_definitions;
        case and spacing are ignored). A name that is not defined, or does
        not apply to entity_kind, is an error listing the defined variables.

        For a number variable: equals, at_least, at_most (both bounds
        inclusive), each a number or a numeric string, compared exactly
        with the stored decimal (equals=1200.5 matches 1200.50). For a text
        variable: text_equals, matched exactly, case included. A filter of
        the wrong kind for the variable's value_type is an error. With no
        value filter every entity that currently has the variable matches.
        Only current values count (lab.variable_current); a variable that
        was unset does not match.

        active_only (default True) skips superseded and retracted events and
        artifacts; it has no effect on other kinds.

        Rows are the matching current values: entity_id (look the entity up
        with get_events, get_artifacts, get_subjects, get_sessions or
        get_projects), variable, value_num (an exact decimal string), value_text,
        value, units, set_at, set_by, ... Ordered by entity_id.

        Returns {"row_count", "limit", "truncated", "next_cursor", "rows"}.
        `truncated` true means more entities matched than were returned:
        call again with the same arguments and cursor=<next_cursor> for the
        next page; `limit` (max 1000) caps each page.
        """
        db.tag_pk(entity_kind)
        numeric = any(v is not None for v in (equals, at_least, at_most))

        def resolve(cur):
            canonical, value_type = _resolve_variable(cur, name, entity_kind)
            if numeric and value_type != "number":
                raise ValueError(
                    f"Variable {canonical!r} holds text; use text_equals, not "
                    f"equals / at_least / at_most.")
            if text_equals is not None and value_type != "text":
                raise ValueError(
                    f"Variable {canonical!r} holds numbers; use equals / at_least / "
                    f"at_most, not text_equals.")
            return {"variable": canonical}

        active = (entity_kind if active_only and entity_kind in db.ACTIVE_ENTITY_CLAUSE
                  else None)
        return db.select_from(
            "lab.variable_current",
            {"entity_kind": entity_kind, "value_num": equals, "value_text": text_equals},
            limit=limit, order_by=db.ORDER_BY_VARIABLE_CURRENT,
            num_ranges={"value_num": (at_least, at_most)}, active_entities=active,
            paged=True, cursor=cursor, resolve=resolve)

