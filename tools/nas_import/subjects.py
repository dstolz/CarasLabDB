"""Subjects of groups, and the reviewed overrides file.

The subject of a group is its level-1 folder (the folder directly under the
listed directory), which must be a known subject (a ``lab.subject`` row,
compared exactly). Then:

* the subject named in the file or folder name equals it: nothing to say;
* it differs only in case (``SUBj-ID-1278_...`` in ``SUBJ-ID-1278``):
  accepted, note ``subject_name_case_variant``;
* it names another subject: held, ``subject_mismatch``, until an override
  names the subject.

A level-1 folder that is not a known subject (``TEST``, ``videos``, a subject
missing from ``lab.subject``, a misspelt folder) is never set aside
silently: its groups and loose files are HELD (``unknown_subject``). One that
matches a known subject only when ASCII case is ignored is held
(``subject_folder_case_variant``). Only a person sets a folder aside: an
override row whose ``relative_path`` is a level-1 folder
(``<directory>/<folder>``) with ``skip`` covers everything under it -- its
groups become ``skipped`` and its loose files reported (``override_skip``).
A folder-level row naming a subject is an :class:`OverrideError`. A
group-level row is more specific and wins over a folder-level one.

Overrides are a CSV with the header ``root,relative_path,subject_id,reason``
(UTF-8, a BOM allowed). ``subject_id`` is a subject or the word ``skip``.
``relative_path`` names a group by its recording folder, its ePsych session
base path or session path, or any one of its files, or a level-1 folder.
Parsing is strict: a wrong header, a row of another length, an empty or
space-padded value, a path that is not clean, a second row for the same
(root, path) or a CSV syntax error (an unterminated quote) is an
:class:`OverrideError` naming the line where the row starts. An override
names the subject whatever the folder says (its reason is stored on the
event, so rewording a reason changes the event's digest: documented);
``skip`` leaves the group unregistered (status ``skipped``). An override
naming an unknown subject holds the group (``override_unknown_subject``).
Overrides that match nothing are returned so the caller can report them.

"Differs only in case" is :func:`..names.ascii_fold` everywhere.
"""

from __future__ import annotations

import csv
import dataclasses
import io
from collections.abc import Collection, Sequence

from .model import Group, HeldItem, Hold, Note, Override, ReportedItem, with_hold
from .names import ascii_fold
from .walk import check_relative_path

OVERRIDE_HEADER = ["root", "relative_path", "subject_id", "reason"]
SKIP = "skip"


class OverrideError(ValueError):
    """The overrides file is malformed; names the line."""


def parse_overrides(text: str) -> tuple[Override, ...]:
    """Parse the overrides CSV TEXT strictly (see the module docstring)."""
    if text.startswith("\ufeff"):
        text = text[1:]
    reader = csv.reader(io.StringIO(text, newline=""), strict=True)
    rows: list[tuple[int, list[str]]] = []
    start = 1
    try:
        for row in reader:
            rows.append((start, row))
            start = reader.line_num + 1
    except csv.Error as exc:
        raise OverrideError("line %d: %s" % (start, exc)) from None
    if not rows or rows[0][1] != OVERRIDE_HEADER:
        raise OverrideError("line 1: the header must be %s" % ",".join(OVERRIDE_HEADER))
    out: list[Override] = []
    seen: dict[tuple[str, str], int] = {}
    for line, row in rows[1:]:
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


def case_variant(name: str, known: Collection[str]) -> str | None:
    """The known subject NAME equals when ASCII case is ignored (not exactly), or None."""
    folded = sorted(k for k in known if ascii_fold(k) == ascii_fold(name) and k != name)
    return folded[0] if folded else None


def _skip(g: Group, o: Override) -> Group:
    return dataclasses.replace(g, status="skipped", override=o, hold=Hold(
        "override_skip", "skipped by the override on line %d: %s" % (o.line, o.reason)))


def resolve_group(g: Group, known: Collection[str], override: Override | None) -> Group:
    """The group with its subject resolved (or held, or skipped) by a group-level override."""
    if override is not None:
        g = dataclasses.replace(g, override=override)
        if override.skip:
            return _skip(g, override)
        if override.subject_id not in known:
            return with_hold(g, Hold("override_unknown_subject", "the override on line %d names "
                                     "%s, which is not a subject" % (override.line,
                                                                     override.subject_id)))
        return dataclasses.replace(g, subject_id=override.subject_id, notes=g.notes + (
            Note("override_applied", "subject %s from the override on line %d (%s); the folder "
                 "is %s and the name says %s" % (override.subject_id, override.line,
                                                 override.reason, g.subject_folder,
                                                 g.subject_in_name)),))
    folder = g.subject_folder
    if folder not in known:
        variant = case_variant(folder, known)
        if variant is not None:
            return with_hold(g, Hold("subject_folder_case_variant", "the folder %s is subject %s "
                                     "only if case is ignored" % (folder, variant)))
        return with_hold(g, Hold("unknown_subject", "%s is not a known subject; an override "
                                 "may skip the folder or name the subject" % folder))
    if g.subject_in_name == folder:
        return dataclasses.replace(g, subject_id=folder)
    if ascii_fold(g.subject_in_name) == ascii_fold(folder):
        return dataclasses.replace(g, subject_id=folder, notes=g.notes + (
            Note("subject_name_case_variant", "the name spells the subject %s, the folder %s"
                 % (g.subject_in_name, folder)),))
    return with_hold(g, Hold("subject_mismatch", "the name says %s but the folder is %s; an "
                             "override must name the subject" % (g.subject_in_name, folder)))


def _paths_of(g: Group) -> set[str]:
    return {g.source_path, g.session_path} | set(g.all_paths())


def subject_folder_of(directory: str, path: str) -> str | None:
    """The level-1 folder of PATH under DIRECTORY; None for a file directly in it."""
    rest = path[len(directory) + 1:].split("/")
    return rest[0] if len(rest) > 1 else None


def resolve_subjects(groups: Sequence[Group], known_subjects: Collection[str],
                     overrides: Sequence[Override] = (),
                     loose: Sequence[tuple[str, str, HeldItem]] = ()
                     ) -> tuple[tuple[Group, ...], tuple[HeldItem, ...], tuple[ReportedItem, ...],
                                tuple[Override, ...]]:
    """Resolve every group's subject, and place loose held items by their folder.

    LOOSE holds (root, directory, held item). Returns the groups, the loose
    items still held, the loose items reported (under a skipped folder) and
    the unused overrides. OverrideError when two overrides name one group or
    a folder-level override names a subject.
    """
    known = frozenset(known_subjects)
    by_path: dict[tuple[str, str], Group] = {}
    for g in groups:
        for p in _paths_of(g):
            by_path[(g.root, p)] = g
    folders: dict[tuple[str, str], tuple[str, str]] = {}      # (root, dir/folder) -> (dir, folder)
    for g in groups:
        folders[(g.root, g.directory + "/" + g.subject_folder)] = (g.directory, g.subject_folder)
    for root, directory, h in loose:
        f = subject_folder_of(directory, h.path)
        if f is not None:
            folders[(root, directory + "/" + f)] = (directory, f)

    chosen: dict[str, Override] = {}
    folder_skip: dict[tuple[str, str, str], Override] = {}   # (root, dir, folder) -> override
    used: set[int] = set()
    for o in overrides:
        g = by_path.get((o.root, o.path))
        if g is not None:
            if g.key in chosen:
                raise OverrideError("lines %d and %d both override %s"
                                    % (chosen[g.key].line, o.line, g.key))
            chosen[g.key] = o
            used.add(o.line)
            continue
        target = folders.get((o.root, o.path))
        if target is not None:
            if not o.skip:
                raise OverrideError("line %d: %s is a folder; a folder-level override can only "
                                    "skip it" % (o.line, o.path))
            folder_skip[(o.root,) + target] = o
            used.add(o.line)

    out = []
    for g in groups:
        if g.key in chosen:
            out.append(resolve_group(g, known, chosen[g.key]))
        elif (g.root, g.directory, g.subject_folder) in folder_skip:
            out.append(_skip(g, folder_skip[(g.root, g.directory, g.subject_folder)]))
        else:
            out.append(resolve_group(g, known, None))

    keep: list[HeldItem] = []
    reported: list[ReportedItem] = []
    for root, directory, h in loose:
        f = subject_folder_of(directory, h.path)
        o = folder_skip.get((root, directory, f)) if f is not None else None
        if o is not None:
            reported.append(ReportedItem(h.path, "override_skip", "the folder is skipped by the "
                                         "override on line %d (%s); held as: %s"
                                         % (o.line, o.reason, h.sentence),
                                         size=h.size, mtime_ns=h.mtime_ns))
        elif (f is None or f in known or case_variant(f, known) is not None
              or h.reason_code == "path_not_storable"):
            keep.append(h)
        else:
            keep.append(dataclasses.replace(h, reason_code="unknown_subject", sentence=(
                "%s is not a known subject (%s: %s)" % (f, h.reason_code, h.sentence))))
    return tuple(out), tuple(keep), tuple(reported), tuple(o for o in overrides
                                                            if o.line not in used)
