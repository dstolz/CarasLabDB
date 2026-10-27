"""Read tools for the tag vocabulary and the tags on lab entities.

Tag syntax, shared by every tool here and by the `tags` / `any_tags` /
`none_tags` filters on get_events, get_artifacts, get_subjects, get_sessions
and get_projects (see design_docs/tagging.md): a tag is `namespace:value`,
lowercase (e.g. `stage:raw`, `cohort:a`, `qc:fail`). A bare tag with no colon
is shorthand for `tag:<x>`, so `auditory_cortex` and `tag:auditory_cortex`
are the same tag. In a filter, `namespace:*` matches any current tag in that
namespace. Case and surrounding whitespace are ignored; the database does the
matching (lab.fn_tag_match), so these tools only bind the tokens.

Only the per-tool docstrings reach the calling LLM, so the syntax note is
repeated in each one rather than stated once here.
"""

from typing import Optional

from .. import db


def register(app):
    @app.tool()
    def get_tag_namespaces(limit: int = db.DEFAULT_LIMIT) -> dict:
        """List tag namespaces and their policies (lab.tag_namespace).

        A tag is `namespace:value` (e.g. `stage:raw`); a bare tag such as
        `auditory_cortex` means `tag:auditory_cortex`, in the reserved `tag`
        namespace. Each row is one namespace with: `mutability` ('mutable' =
        a tag can be removed or replaced, history kept; 'immutable' = once
        set it is permanent), `cardinality` ('single' = at most one current
        tag of the namespace per entity; 'multi' = any number),
        `open_vocabulary` (true = new values can be created on the fly; false
        = only registered values, see get_tags), and `applies_to`, the list
        of entity kinds it may be put on (event, artifact, subject, session,
        project). Ordered by namespace.

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.fetch_limited(
            "SELECT namespace, description, mutability, cardinality, "
            "open_vocabulary, applies_to, created_at, created_by "
            "FROM lab.tag_namespace ORDER BY namespace",
            limit=limit)

    @app.tool()
    def get_tags(
        namespace: Optional[str] = None,
        include_retired: bool = False,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List registered tags (the vocabulary), optionally for one namespace.

        A tag is `namespace:value` (e.g. `stage:raw`); a bare tag such as
        `auditory_cortex` is stored as `tag:auditory_cortex`. Rows carry
        `tag`, `namespace`, `value`, `description` and `retired_at`. Retired
        tags (retired_at set) can no longer be applied to new entities but
        stay on the ones that have them; they are left out unless
        include_retired=True. This lists the vocabulary, not what is applied
        to what -- use get_entity_tags or find_by_tags for that. Open
        namespaces (see get_tag_namespaces) may hold values nobody has
        registered yet, so absence here is not proof a tag is unused.
        Ordered by tag.

        namespace is the namespace name without a colon (e.g. "stage"). A
        namespace left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        return db.fetch_limited(
            "SELECT tag, namespace, value, description, retired_at, "
            "created_at, created_by FROM lab.tag "
            "WHERE (%s::text IS NULL OR namespace = %s) "
            "AND (%s OR retired_at IS NULL) ORDER BY tag",
            [namespace, namespace, include_retired], limit=limit)

    @app.tool()
    def get_entity_tags(
        entity_kind: str,
        entity_id: str,
        include_history: bool = False,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List the tags on one event, artifact, subject, session or project.

        entity_kind is one of "event", "artifact", "subject", "session",
        "project"; anything else raises ValueError. entity_id is that
        entity's id (a uuid, or the subject_id text for a subject). A tag is
        `namespace:value`; a bare tag is stored as `tag:<x>` and its
        `display_tag` is the bare form.

        By default returns the entity's current tags (lab.tag_current), one
        row per tag with `tag`, `namespace`, `value`, `display_tag`, `note`,
        `applied_at`, `applied_by`, ordered by tag. With include_history=True
        returns the full assignment log (lab.tag_assignment) instead, newest
        first: every `op` 'add' and 'remove', including tags since removed or
        replaced, so you can see when and why a tag changed.

        Tags are put on specific rows: a superseded event or artifact keeps
        the tags it had, and its correction is tagged separately.

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        pk = db.tag_pk(entity_kind)
        if include_history:
            return db.select_from(
                "lab.tag_assignment",
                {"entity_kind": entity_kind, pk: entity_id},
                limit=limit, order_by=db.ORDER_BY_TAG_ASSIGNMENT)
        return db.select_from(
            "lab.tag_current",
            {"entity_kind": entity_kind, pk: entity_id},
            limit=limit, order_by=db.ORDER_BY_TAG_CURRENT)

    @app.tool()
    def find_by_tags(
        entity_kind: str,
        all_of: Optional[list[str]] = None,
        any_of: Optional[list[str]] = None,
        none_of: Optional[list[str]] = None,
        active_only: bool = True,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """Find entities by their current tags; returns entity ids.

        entity_kind is one of "event", "artifact", "subject", "session",
        "project"; anything else raises ValueError. An entity matches when it
        has ALL of all_of, at least ONE of any_of (an empty any_of is no
        constraint), and NONE of none_of. Lists left as None or empty are not
        applied; with all three empty every entity of that kind matches (up
        to `limit`). Untagged entities count, so none_of alone finds
        entities lacking a tag.

        Tags are `namespace:value`, lowercase, e.g. ["stage:raw",
        "cohort:a"]. A bare tag with no colon is shorthand for tag:<x>
        ("auditory_cortex" = "tag:auditory_cortex"). "namespace:*" matches
        any current tag in that namespace (none_of=["qc:*"] = never
        QC-checked). Example: artifacts that are raw, from cohort A, and not
        failed -- all_of=["stage:raw", "cohort:a"], none_of=["qc:fail"].

        active_only (default True) skips superseded events and artifacts,
        like get_events / get_artifacts; it has no effect on other kinds.

        Returns {"rows": [{"entity_id": ...}, ...], "row_count", "limit",
        "truncated"}, ordered by entity_id. Look the rows up with get_events,
        get_artifacts, get_subjects, get_sessions or get_projects, or pass
        the same tags to those tools directly to get full rows. `truncated`
        true means more entities matched than were returned (raise `limit`,
        max 1000).
        """
        db.tag_pk(entity_kind)
        sql = (
            "SELECT entity_id FROM lab.fn_find_by_tags("
            "%s, %s::text[], %s::text[], %s::text[], %s) ORDER BY entity_id"
        )
        return db.fetch_limited(
            sql,
            [entity_kind, db.tag_array(all_of), db.tag_array(any_of),
             db.tag_array(none_of), active_only],
            limit=limit)
