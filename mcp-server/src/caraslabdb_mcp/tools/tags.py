"""Read tools for the tagging layer: namespaces, the tag vocabulary, and the
append-only lab.tag_assignment log (current tags are derived from it).

Tag spelling, repeated in each docstring because only those reach the LLM:
a tag is canonical `namespace:value`; a bare tag with no namespace belongs
to the reserved `tag` namespace (`auditory_cortex` == `tag:auditory_cortex`);
input is case-insensitive (the database canonicalizes it); and a filter
element may be a `namespace:*` wildcard matching any current tag of that
namespace. lab.fn_tag_match is the single definition of those semantics.
"""

import uuid
from typing import Optional

from .. import db


def _check_kind(entity_kind):
    if entity_kind not in db.TAG_KINDS:
        raise ValueError(
            f"entity_kind must be one of {', '.join(db.TAG_KINDS)}, got {entity_kind!r}.")


def _normalize_entity_id(entity_kind, entity_id):
    """The id as the text lab.tag_current / lab.fn_tag_entity_id compare on.

    Every kind but `subject` is keyed by uuid, so a malformed id is rejected
    here with a clear ValueError rather than as a database cast error, and a
    well-formed one is lower-cased to match the stored text form.
    """
    if entity_kind == "subject":
        return entity_id
    try:
        return str(uuid.UUID(entity_id))
    except (ValueError, AttributeError, TypeError):
        raise ValueError(
            f"entity_id for a {entity_kind} must be a uuid, got {entity_id!r}.") from None


def register(app):
    @app.tool()
    def get_tag_namespaces(
        namespace: Optional[str] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List tag namespaces and their policies (lab.tag_namespace).

        Each row says whether a namespace's tags may be changed once applied
        (mutability: mutable|immutable), how many of its tags an entity may
        carry at once (cardinality: single|multi), whether lab.fn_tag may
        create new values on the fly (open_vocabulary) and which entity kinds
        it applies to (applies_to). The reserved `tag` namespace holds bare
        tags written without a namespace. Ordered by namespace.

        namespace left as None is not applied as a filter -- it never means
        "IS NULL". Returns {"rows", "row_count", "limit", "truncated"};
        `truncated` true means more rows matched than were returned (raise
        `limit`, max 1000).
        """
        return db.select_from("lab.tag_namespace", {
            "namespace": namespace,
        }, limit=limit, order_by=db.ORDER_BY_TAG_NAMESPACE)

    @app.tool()
    def get_tags(
        namespace: Optional[str] = None,
        tag: Optional[str] = None,
        include_retired: bool = False,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """List the tag vocabulary (lab.tag): canonical `namespace:value` rows.

        `tag` matches the canonical spelling case-insensitively; a bare tag
        (no colon) is looked up in the reserved `tag` namespace, so
        tag="Auditory_Cortex" finds "tag:auditory_cortex". namespace filters
        to one namespace (case-insensitively). Retired tags (retired_at set;
        they stay in the log but cannot be applied again) are excluded unless
        include_retired=True. Ordered by tag.

        A filter left as None is not applied -- it never means "IS NULL".
        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        if tag is not None:
            # Mirror lab.fn_canonical_tag: trim, and a bare tag is `tag:` + value
            # (lower-casing is the ci_filter's job).
            tag = tag.strip()
            if ":" not in tag:
                tag = "tag:" + tag
        return db.select_from("lab.tag", {}, limit=limit, order_by=db.ORDER_BY_TAG,
                              ci_filters={"namespace": namespace, "tag": tag},
                              null_filters={"retired_at": None if include_retired else True})

    @app.tool()
    def get_entity_tags(
        entity_kind: str,
        entity_id: str,
        include_history: bool = False,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """The current tags of one entity, or its full tag add/remove history.

        entity_kind is one of event, artifact, subject, session, project;
        entity_id is that entity's primary key (a uuid for every kind but
        subject, whose id is text). A malformed uuid raises ValueError before
        any query runs.

        By default reads lab.tag_current: one row per tag the entity carries
        now, with namespace, value, display_tag (the bare value for the
        reserved `tag` namespace, the canonical `namespace:value` otherwise),
        note, applied_at and applied_by. Ordered by tag. An entity with no
        tags returns zero rows -- that is not an error.

        With include_history=True reads the append-only lab.tag_assignment
        log instead: every 'add' and 'remove' row ever applied to the entity,
        newest first (applied_at DESC, assignment_id DESC). The newest row per
        tag is what decides whether it is current.

        Returns {"rows", "row_count", "limit", "truncated"}; `truncated` true
        means more rows matched than were returned (raise `limit`, max 1000).
        """
        _check_kind(entity_kind)
        entity_id = _normalize_entity_id(entity_kind, entity_id)
        if include_history:
            # The id column is fixed by kind (db.TAG_PK), never caller-named.
            return db.select_from("lab.tag_assignment", {
                "entity_kind": entity_kind, db.TAG_PK[entity_kind]: entity_id,
            }, limit=limit, order_by=db.ORDER_BY_TAG_ASSIGNMENT)
        return db.select_from("lab.tag_current", {
            "entity_kind": entity_kind, "entity_id": entity_id,
        }, limit=limit, order_by=db.ORDER_BY_TAG)

    @app.tool()
    def find_by_tags(
        entity_kind: str,
        all_of: Optional[list[str]] = None,
        any_of: Optional[list[str]] = None,
        none_of: Optional[list[str]] = None,
        limit: int = db.DEFAULT_LIMIT,
    ) -> dict:
        """Ids of the tagged entities of one kind whose current tags match a filter.

        Wraps lab.fn_find_by_tags. entity_kind is one of event, artifact,
        subject, session, project. Every tag in all_of must be current on
        the entity, at least one of any_of must be (when any_of is given),
        and none of none_of may be. Each element is a canonical
        `namespace:value` tag, a bare tag (`auditory_cortex`, i.e.
        `tag:auditory_cortex`), or a `namespace:*` wildcard that matches any
        current tag of that namespace (`qc:*` = "has any qc verdict"). Input
        is case-insensitive. An empty or None list imposes nothing.

        Only entities that have (or once had) a tag are considered, so an
        entity with no tags at all is never returned -- not even by a filter
        that is only none_of. To include untagged rows, use the `tags` /
        `any_tags` / `none_tags` parameters of get_events, get_artifacts,
        get_subjects, get_sessions or get_projects instead, which apply the
        same filter to the whole table.

        Rows are {"entity_id": text} ordered by entity_id. Returns {"rows",
        "row_count", "limit", "truncated"}; `truncated` true means more
        matched than were returned (raise `limit`, max 1000).
        """
        _check_kind(entity_kind)
        lists = []
        for name, tags in (("all_of", all_of), ("any_of", any_of), ("none_of", none_of)):
            tags = list(tags or [])
            if not all(isinstance(t, str) for t in tags):
                raise ValueError(f"{name} must be a list of strings.")
            lists.append(tags)
        sql = ("SELECT entity_id FROM lab.fn_find_by_tags("
               "%s, %s::text[], %s::text[], %s::text[])")
        return db.fetch_limited(sql, [entity_kind] + lists, limit=limit)
