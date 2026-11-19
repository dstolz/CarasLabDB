"""Subjects of groups, and the reviewed overrides file.

The subject of a group is its level-1 folder (the folder directly under the
listed directory), which must be a known subject (a ``lab.subject`` row,
compared exactly). Then:

* the subject named in the file or folder name equals it: nothing to say;
* it differs only in case (``SUBj-ID-1278_...`` in ``SUBJ-ID-1278``):
  accepted, note ``subject_name_case_variant``;
* it names another subject: held, ``subject_mismatch``, until an override
  names the subject.

A level-1 folder that is not a known subject (``TEST``, ``TEST_SUBJECT``,
``SUBJ-ID-TEST``, ``videos``, ...) is a test folder: its groups and loose
files are *reported* (``not_a_subject_folder``), not registered and not held.
One that matches a known subject only when case is ignored is held
(``subject_folder_case_variant``): it is real data under a misspelt folder.

Overrides are a CSV with the header ``root,relative_path,subject_id,reason``
(UTF-8, a BOM allowed). ``subject_id`` is a subject or the word ``skip``.
``relative_path`` names a group by its recording folder, its ePsych session
base path or any one of its files. Parsing is strict: a wrong header, a row
of another length, an empty or space-padded value, a path that is not clean
or a second row for the same (root, path) is an :class:`OverrideError`
naming the line. An override names the subject whatever the folder says
(its reason is stored on the event); ``skip`` leaves the group unregistered
(status ``skipped``). An override naming an unknown subject holds the group
(``override_unknown_subject``). Overrides that match no group are returned so
the caller can report them.
"""

from __future__ import annotations

import csv
import dataclasses
import io
from collections.abc import Collection, Iterable, Sequence

from .model import Group, HeldItem, Hold, Note, Override, ReportedItem
from .walk import check_relative_path

OVERRIDE_HEADER = ["root", "relative_path", "subject_id", "reason"]
SKIP = "skip"


class OverrideError(ValueError):
    """The overrides file is malformed; names the line."""


def parse_overrides(text: str) -> tuple[Override, ...]:
    """Parse the overrides CSV TEXT strictly (see the module docstring)."""
    if text.startswith("﻿"):
        text = text[1:]
    rows = list(csv.reader(io.StringIO(text, newline=""), strict=True))
    if not rows or rows[0] != OVERRIDE_HEADER:
        raise OverrideError("line 1: the header must be %s" % ",".join(OVERRIDE_HEADER))
    out: list[Override] = []
    seen: dict[tuple[str, str], int] = {}
    for line, row in enumerate(rows[1:], start=2):
        if row == []:
            continue                                  # an empty line
        if len(row) != 4:
            raise OverrideError("line %d: %d fields, expected 4" % (line, len(row)))
        for name, value in zip(OVERRIDE_HEADER, row):
            if value == "":
                raise OverrideError("line %d: %s is empty" % (line, name))
            if value != value.strip():
                raise OverrideError("line %d: %s has white space at an end" % (line, name))
        root, path, subject, reason = row
        try:
            check_relative_path(path)
        except ValueError as exc:
            raise OverrideError("line %d: %s" % (line, exc)) from None
        if (root, path) in seen:
            raise OverrideError("line %d: %s:%s is already overridden on line %d"
                                % (line, root, path, seen[(root, path)]))
        seen[(root, path)] = line
        skip = subject == SKIP
        out.append(Override(root, path, None if skip else subject, skip, reason, line))
    return tuple(out)


def read_overrides(path: str) -> tuple[Override, ...]:
    """Read and parse the overrides file at PATH."""
    with open(path, encoding="utf-8", newline="") as fh:
        return parse_overrides(fh.read())


def _hold(g: Group, hold: Hold, status: str = "held") -> Group:
    if g.status == "held" and g.hold is not None and status == "held":
        return dataclasses.replace(g, notes=g.notes + (Note(hold.reason_code, "also: " + hold.sentence),))
    return dataclasses.replace(g, status=status, hold=hold)


def _case_variant(name: str, known: Collection[str]) -> str | None:
    folded = [k for k in known if k.casefold() == name.casefold()]
    return sorted(folded)[0] if folded else None


def resolve_group(g: Group, known: Collection[str], override: Override | None) -> Group:
    """The group with its subject resolved (or held, skipped, reported)."""
    if override is not None:
        g = dataclasses.replace(g, override=override)
        if override.skip:
            return dataclasses.replace(g, status="skipped",
                                       hold=Hold("override_skip", "skipped by the override on "
                                                 "line %d: %s" % (override.line, override.reason)))
        if override.subject_id not in known:
            return _hold(g, Hold("override_unknown_subject", "the override on line %d names %s, "
                                 "which is not a subject" % (override.line, override.subject_id)))
        return dataclasses.replace(g, subject_id=override.subject_id, notes=g.notes + (
            Note("override_applied", "subject %s from the override on line %d (%s); the folder "
                 "is %s and the name says %s" % (override.subject_id, override.line,
                                                 override.reason, g.subject_folder,
                                                 g.subject_in_name)),))
    folder = g.subject_folder
    if folder not in known:
        variant = _case_variant(folder, known)
        if variant is not None:
            return _hold(g, Hold("subject_folder_case_variant", "the folder %s is subject %s "
                                 "only if case is ignored" % (folder, variant)))
        return dataclasses.replace(g, status="reported",
                                   hold=Hold("not_a_subject_folder", "%s is not a subject; "
                                             "a test folder is reported, not registered" % folder))
    if g.subject_in_name == folder:
        return dataclasses.replace(g, subject_id=folder)
    if g.subject_in_name.casefold() == folder.casefold():
        return dataclasses.replace(g, subject_id=folder, notes=g.notes + (
            Note("subject_name_case_variant", "the name spells the subject %s, the folder %s"
                 % (g.subject_in_name, folder)),))
    return _hold(g, Hold("subject_mismatch", "the name says %s but the folder is %s; an "
                         "override must name the subject" % (g.subject_in_name, folder)))


def _paths_of(g: Group) -> set[str]:
    return {g.source_path, g.session_path} | set(g.all_paths())


def resolve_subjects(groups: Sequence[Group], known_subjects: Collection[str],
                     overrides: Sequence[Override] = ()) -> tuple[tuple[Group, ...], tuple[Override, ...]]:
    """Resolve every group's subject; returns the groups and the unused overrides.

    OverrideError when two overrides name one group or one names two groups.
    """
    known = frozenset(known_subjects)
    by_key: dict[tuple[str, str], Group] = {}
    for g in groups:
        for p in _paths_of(g):
            by_key[(g.root, p)] = g
    chosen: dict[str, Override] = {}
    used: set[int] = set()
    for o in overrides:
        g = by_key.get((o.root, o.path))
        if g is None:
            continue
        if g.key in chosen:
            raise OverrideError("lines %d and %d both override %s"
                                % (chosen[g.key].line, o.line, g.key))
        chosen[g.key] = o
        used.add(o.line)
    out = tuple(resolve_group(g, known, chosen.get(g.key)) for g in groups)
    return out, tuple(o for o in overrides if o.line not in used)


def subject_folder_of(directory: str, path: str) -> str | None:
    """The level-1 folder of PATH under DIRECTORY; None for a file directly in it."""
    rest = path[len(directory) + 1:].split("/")
    return rest[0] if len(rest) > 1 else None


def reclassify_loose(directory: str, held: Iterable[HeldItem], known_subjects: Collection[str]
                     ) -> tuple[tuple[HeldItem, ...], tuple[ReportedItem, ...]]:
    """Loose held items in a test folder become reported items; the rest stay held."""
    known = frozenset(known_subjects)
    keep: list[HeldItem] = []
    reported: list[ReportedItem] = []
    for h in held:
        folder = subject_folder_of(directory, h.path)
        if folder is None or folder in known or _case_variant(folder, known) is not None:
            keep.append(h)
        else:
            reported.append(ReportedItem(h.path, "not_a_subject_folder",
                                         "%s is not a subject; a test folder is reported, not "
                                         "registered (%s)" % (folder, h.sentence),
                                         size=h.size, mtime_ns=h.mtime_ns))
    return tuple(keep), tuple(reported)
