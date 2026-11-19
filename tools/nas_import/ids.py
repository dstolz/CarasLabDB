"""Deterministic ids, the event digest, the group signature and the attributes.

Ids (``uuid5`` under :data:`NAMESPACE`; the namespace must never change, or
every id the importer ever minted would be minted again differently and a
re-run would register everything twice):

* session: ``uuid5(NAMESPACE, "session:<root>:<session relative_path>")``
* event:   ``uuid5(NAMESPACE, "event:<event_type>:<root>:<source_path>")``,
  where ``source_path`` is the recording folder or the ePsych session's base
  path (``<dir>/<subject folder>/<subject>_<stamp>``, no extension), so the
  id does not change when a twin file or a video is added.

``client_digest(group)``: SHA-256 hex of the canonical JSON (sorted keys,
``,``/``:`` separators, UTF-8, no floats) of exactly these values:

* ``digest_format`` (1), ``event_type``, ``event_id``, ``subject_id``,
  ``session_id``;
* ``occurred_at_local`` (wall-clock text), ``time_zone``,
  ``occurred_precision`` (``second`` | ``day``);
* ``detail``: the detail row's values (recording: acquisition_system_code,
  modality, sample_rate_hz, n_channels, duration_s; behavior:
  trials_completed), numbers other than counts as exact decimal text;
* ``import``: the ``attributes.import`` block (tool name, layout, root,
  path, source_value, override when there is one).

Not in it: the tool's version, the files (a file added to a registered
folder is a new artifact, not a correction), sizes and times, the session's
own columns other than its id, notes.

``signature(group)``: SHA-256 hex of the canonical JSON list of
``[path, size, mtime_ns]`` of ALL the group's listed files (registrable and
held one by one), sorted by path. Two listings of an unchanged group give the
same signature; any added, removed or touched file changes it. The database
side registers a group only when two complete listings at least the minimum
age apart give the same signature.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import uuid

from .model import TOOL_NAME, Group

NAMESPACE = uuid.UUID("8061b6cb-00dc-44fb-b6a9-c3f8ac5ab649")
DIGEST_FORMAT = 1

OCCURRED_AT_SOURCE = {
    ("recording", "second"): "recording folder name",       # LabCapture.copiedSession's text
    ("behavior", "second"): "ePsych file name",
    ("behavior", "day"): "ePsych file name (date only)",
}


def canonical_json(value) -> str:
    """Sorted keys, no spaces, UTF-8 text; refuses floats (exactness)."""
    def check(v):
        if isinstance(v, float):
            raise TypeError("a float in canonical JSON: %r" % v)
        if isinstance(v, dict):
            for k, x in v.items():
                if not isinstance(k, str):
                    raise TypeError("a non-text key %r" % (k,))
                check(x)
        elif isinstance(v, (list, tuple)):
            for x in v:
                check(x)
    check(value)
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def session_id(root: str, path: str) -> str:
    return str(uuid.uuid5(NAMESPACE, "session:%s:%s" % (root, path)))


def event_id(event_type: str, root: str, path: str) -> str:
    return str(uuid.uuid5(NAMESPACE, "event:%s:%s:%s" % (event_type, root, path)))


def group_event_id(group: Group) -> str:
    return event_id(group.kind, group.root, group.source_path)


def group_session_id(group: Group) -> str:
    return session_id(group.root, group.session_path)


def mtime_text(mtime_ns: int) -> str:
    """``st_mtime_ns`` as UTC text with nine decimals, by integer arithmetic.

    E.g. ``2026-03-07T15:15:00.123456789Z``; the attribute ``source_mtime``.
    """
    secs, ns = divmod(int(mtime_ns), 1_000_000_000)
    day = datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=secs)
    return day.strftime("%Y-%m-%dT%H:%M:%S") + ".%09dZ" % ns


def import_block(group: Group) -> dict:
    """``attributes.import``: tool, layout, root, path, source_value, override."""
    block = {"tool": TOOL_NAME, "layout": group.layout, "root": group.root,
             "path": group.source_path, "source_value": group.source_value}
    if group.override is not None:
        block["override"] = {"subject_id": group.override.subject_id,
                             "reason": group.override.reason}
    return block


def digest_source(group: Group) -> dict:
    """The values ``client_digest`` is taken of (see the module docstring)."""
    if group.status != "ready" or group.subject_id is None:
        raise ValueError("group %s is not ready to register (%s)" % (group.key, group.status))
    return {
        "digest_format": DIGEST_FORMAT,
        "event_type": group.kind,
        "event_id": group_event_id(group),
        "subject_id": group.subject_id,
        "session_id": group_session_id(group),
        "occurred_at_local": group.occurred_local,
        "time_zone": group.time_zone,
        "occurred_precision": group.precision,
        "detail": dict(group.detail),
        "import": import_block(group),
    }


def client_digest(group: Group) -> str:
    """SHA-256 hex of the canonical JSON of ``digest_source(group)``."""
    return sha256_text(canonical_json(digest_source(group)))


def signature(group: Group) -> str:
    """SHA-256 hex over sorted [path, size, mtime_ns] of every listed file of the group."""
    rows = [[f.path, f.size, f.mtime_ns] for f in group.files]
    rows += [[h.path, h.size, h.mtime_ns] for h in group.held_files]
    return sha256_text(canonical_json(sorted(rows)))


def event_attributes(group: Group, code_version: str) -> dict:
    """The event's attributes: import block, LabCapture provenance, client_digest.

    ``captured_by_tool`` is the tool name, ``code_version`` the caller's
    version text (not in the digest), ``occurred_at_source`` says where the
    time came from, ``occurred_precision`` is ``day`` for a date-only session
    (absent otherwise, as in the master-log import).
    """
    attrs = {
        "import": import_block(group),
        "captured_by_tool": TOOL_NAME,
        "code_version": code_version,
        "occurred_at_source": OCCURRED_AT_SOURCE[(group.kind, group.precision)],
        "client_digest": client_digest(group),
    }
    if group.precision == "day":
        attrs["occurred_precision"] = "day"
    return attrs
