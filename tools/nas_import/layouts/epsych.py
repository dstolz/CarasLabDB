"""Layout ``epsych``: ``<dir>/<subject folder>/<files>``, no deeper folders.

Recognition (name first, then content; a disagreement holds):

* ``<SUBJ>_<yyMMdd>T<HHmmss>[_<suffix>].mat`` -- behavior data, start to the
  second; ``<SUBJ>_<dd-Mon-yyyy>[_A|_B].mat`` and ``<SUBJ>_<yyMMdd>.mat`` --
  date only (:mod:`..names`). Content: a MAT 5.0 file with top-level ``Data``
  and ``Info``; the trial count is numel(Data) (:mod:`..mat5`).
* Files sharing the subject (as spelled) and the date/time text are ONE
  session and ONE event (``_psych``, ``_delay`` ... twins). Their trial counts
  must agree. Two sessions of one folder whose stamps are equal and whose
  subjects differ only in (ASCII) case are both held.
* ``<stem>.ts`` / ``<stem>-<n>.ts`` -- session video (role ``video``), where
  ``<stem>`` is a .mat file's stem of the session or its base stem
  ``<SUBJ>_<stamp>``. Content: MPEG-TS sync bytes. A video matching no
  session is held (``video_without_mat``).
* ``<X>_conv.mp4`` -- converted from ``<X>.ts`` of the same folder; its
  ``converted_from`` is that file's path. Held when ``<X>.ts`` is absent or
  held.
* A zero-byte file is held. Anything else is held (``unrecognised_name``).

A session's identity never depends on which of its files exist: its label
is the base stem ``<SUBJ>_<stamp>`` (for the date-only forms the whole stem,
so ``_A`` and ``_B`` stay two sessions), its ``session_path`` is
``<dir>/<subject folder>/<SUBJ>_<stamp>.mat`` whether or not that plain file
exists (a note ``epsych_no_plain_file`` says when it does not), and its
``source_value`` is the base stem. So adding a twin or a video later
changes neither the session id, the event id, the label nor the digest.

A member held for a transient reason (``unreadable_file``,
``changed_during_scan``) holds the whole session: what could be read at
that moment must not decide the session. A link, special entry or
unstorable name that would be a member (a twin or a video of the session)
holds the session with its own code and is part of the signature.

Mapping: .mat -> role ``raw``, ``{"kind": "epsych"}``; .ts -> role ``video``,
``{"kind": "video"}``; _conv.mp4 -> role ``video``,
``{"kind": "video_converted", "converted_from": <path>}``; every file also
``source_mtime``.
"""

from __future__ import annotations

import dataclasses
import re
from collections import defaultdict

from ..cache import HeaderReader
from ..content import TRANSIENT, ContentProblem
from ..mat5 import epsych_trials
from ..model import Group, Hold, HeldItem, LayoutResult, ListedFile, Listing, Note, ReportedItem
from ..names import BadNameTime, EpsychName, ascii_fold, parse_epsych
from ._common import (empty_folders, group_file, held, odd_hold_sentence, parts_under,
                      split_listing, unstorable_reason)

NAME = "epsych"
_NUMBERED = re.compile(r"(?P<stem>.+)-(?P<n>[0-9]+)\Z")
CONV_SUFFIX = "_conv.mp4"


def interpret_listing(listing: Listing, reader: HeaderReader) -> LayoutResult:
    """Groups and held items of one ePsych directory listing."""
    files_ok, odd = split_listing(listing)
    loose: list[HeldItem] = []
    by_folder: dict[str, list[ListedFile]] = defaultdict(list)
    odd_by_folder: dict[str, list[HeldItem]] = defaultdict(list)
    for f in files_ok:
        parts = parts_under(listing, f.path)
        if len(parts) == 1:
            loose.append(held(f, "not_in_subject_folder",
                              "a file directly in %s, not in a subject folder" % listing.spec.path))
        elif len(parts) > 2:
            loose.append(held(f, "unexpected_depth",
                              "the epsych layout has no folders inside a subject folder"))
        else:
            by_folder[parts[0]].append(f)
    for h in odd:
        parts = parts_under(listing, h.path)
        if len(parts) == 2:
            odd_by_folder[parts[0]].append(h)
        else:
            loose.append(h)
    groups: list[Group] = []
    for folder in sorted(set(by_folder) | set(odd_by_folder)):
        if unstorable_reason("%s/%s" % (listing.spec.path, folder)) is not None:
            loose += odd_by_folder.get(folder, [])   # everything in it is path_not_storable
            continue
        g, h = _folder(listing, reader, folder, by_folder.get(folder, []),
                       odd_by_folder.get(folder, []))
        groups += g
        loose += h
    reported: list[ReportedItem] = empty_folders(listing)
    return LayoutResult(tuple(groups), tuple(sorted(loose, key=lambda x: x.path)), tuple(reported))


def _name(path: str) -> str:
    return path.rsplit("/", 1)[1]


def _folder(listing: Listing, reader: HeaderReader, folder: str, files: list[ListedFile],
            odd: list[HeldItem]):
    spec = listing.spec
    loose: list[HeldItem] = []
    mats: dict[str, list[tuple[ListedFile, EpsychName]]] = defaultdict(list)
    videos: list[ListedFile] = []
    convs: list[ListedFile] = []
    for f in sorted(files, key=lambda x: x.path):
        name = _name(f.path)
        if name.endswith(".mat"):
            try:
                parsed = parse_epsych(name)
            except BadNameTime as exc:
                loose.append(held(f, "invalid_name_time", "the name holds an invalid date or "
                                  "time: %s" % exc))
                continue
            if parsed is None:
                loose.append(held(f, "unrecognised_name", "not an ePsych session file name "
                                  "(<subject>_<yyMMdd>T<HHmmss>[_suffix].mat, "
                                  "<subject>_<dd-Mon-yyyy>[_A|_B].mat or <subject>_<yyMMdd>.mat)"))
                continue
            mats[parsed.base_stem].append((f, parsed))
        elif name.endswith(CONV_SUFFIX):
            convs.append(f)
        elif name.endswith(".ts"):
            videos.append(f)
        else:
            loose.append(held(f, "unrecognised_name", "not a file the epsych layout knows "
                              "(.mat session file, .ts video, _conv.mp4)"))

    # Which session a stem names: its base stem and every .mat stem.
    stem_owner: dict[str, str] = {}
    for base, members in mats.items():
        stem_owner[base] = base
        for f, _p in members:
            stem_owner[_name(f.path)[:-4]] = base

    def owner(stem: str) -> str | None:
        if stem in stem_owner:
            return stem_owner[stem]
        m = _NUMBERED.match(stem)
        if m and m["stem"] in stem_owner:
            return stem_owner[m["stem"]]
        return None

    def odd_owner(name: str) -> str | None:
        if name.endswith(".mat"):
            try:
                p = parse_epsych(name)
            except BadNameTime:
                return None
            return p.base_stem if p is not None and p.base_stem in mats else None
        if name.endswith(CONV_SUFFIX):
            return owner(name[:-len(CONV_SUFFIX)])
        if name.endswith(".ts"):
            return owner(name[:-3])
        return None

    vids: dict[str, list[ListedFile]] = defaultdict(list)
    for f in videos:
        base = owner(_name(f.path)[:-3])
        if base is None:
            loose.append(held(f, "video_without_mat", "no ePsych session file of this folder "
                              "matches the video's name%s"
                              % (" (and it holds zero bytes)" if f.size == 0 else "")))
        else:
            vids[base].append(f)
    conv: dict[str, list[ListedFile]] = defaultdict(list)
    for f in convs:
        base = owner(_name(f.path)[:-len(CONV_SUFFIX)])
        if base is None:
            loose.append(held(f, "video_without_mat", "no ePsych session file of this folder "
                              "matches the converted video's name"))
        else:
            conv[base].append(f)
    odd_of: dict[str, list[HeldItem]] = defaultdict(list)
    for h in odd:
        base = odd_owner(_name(h.path))
        if base is None:
            loose.append(h)
        else:
            odd_of[base].append(h)

    # Sessions whose subject spellings differ only in case but share a stamp.
    clash: dict[tuple[str, str], list[str]] = defaultdict(list)
    for base, members in mats.items():
        p = members[0][1]
        clash[(ascii_fold(p.subject), p.stamp)].append(base)

    groups = []
    for base in sorted(mats):
        p0 = mats[base][0][1]
        rivals = [b for b in clash[(ascii_fold(p0.subject), p0.stamp)] if b != base]
        groups.append(_group(spec, reader, folder, base, mats[base], vids[base], conv[base],
                             odd_of[base], rivals))
    return groups, loose


def _group(spec, reader, folder, base, members, videos, convs, odd, rivals) -> Group:
    source_path = "%s/%s/%s" % (spec.path, folder, base)
    key = "behavior:%s:%s" % (spec.root, source_path)
    files = []
    held_files: list[HeldItem] = [dataclasses.replace(h, group_key=key) for h in odd]
    valid: list[tuple[ListedFile, EpsychName, int]] = []
    p0 = members[0][1]

    for f, p in members:
        if f.size == 0:
            held_files.append(held(f, "zero_byte", "the session file holds zero bytes", key))
            continue
        try:
            n = epsych_trials(reader.read(f, "mat5"))
        except ContentProblem as exc:
            held_files.append(held(f, exc.code, exc.sentence, key))
            continue
        valid.append((f, p, n))
        files.append(group_file(f, "raw", {"kind": "epsych"}))

    good_ts: set[str] = set()
    held_ts: set[str] = set()
    for f in videos:
        if f.size == 0:
            held_files.append(held(f, "zero_byte", "the video holds zero bytes", key))
            held_ts.add(f.path)
            continue
        try:
            reader.read(f, "ts")
        except ContentProblem as exc:
            held_files.append(held(f, exc.code, exc.sentence, key))
            held_ts.add(f.path)
            continue
        good_ts.add(f.path)
        files.append(group_file(f, "video", {"kind": "video"}))

    for f in convs:
        source = f.path[:-len(CONV_SUFFIX)] + ".ts"
        if f.size == 0:
            held_files.append(held(f, "zero_byte", "the converted video holds zero bytes", key))
        elif source in held_ts:
            held_files.append(held(f, "converted_video_source_held",
                                   "its source %s is held" % source, key))
        elif source not in good_ts:
            held_files.append(held(f, "converted_video_without_source",
                                   "its source %s is not in the folder" % source, key))
        else:
            files.append(group_file(f, "video", {"kind": "video_converted",
                                                 "converted_from": source}))

    hold = None
    notes = []
    trials = sorted({n for _f, _p, n in valid})
    transient = [h for h in held_files if h.reason_code in TRANSIENT]
    if odd:
        hold = Hold(odd[0].reason_code, odd_hold_sentence(odd[0]))
    elif transient:
        hold = Hold(transient[0].reason_code, "%s: %s" % (_name(transient[0].path),
                                                         transient[0].sentence))
    elif rivals:
        hold = Hold("epsych_duplicate_session",
                    "sessions %s share the time %s with this one; the subject is spelled "
                    "differently" % (", ".join(sorted(rivals)), p0.stamp))
    elif not valid:
        hold = Hold("no_valid_epsych_file", "no file of the session is a readable ePsych "
                    "session file")
    elif len(trials) > 1:
        hold = Hold("epsych_trials_disagree", "the session's files give %s trials: %s" % (
            " and ".join(str(t) for t in trials),
            "; ".join("%s %d" % (_name(f.path), n) for f, _p, n in valid)))
    suffixes = sorted({p.suffix for _f, p in members if p.suffix})
    if suffixes:
        notes.append(Note("epsych_suffix", "twin files with suffix %s" % ", ".join(suffixes)))
    plain_name = base + ".mat"
    if not any(_name(f.path) == plain_name for f, _p in members) and \
            not any(_name(h.path) == plain_name for h in odd):
        notes.append(Note("epsych_no_plain_file", "there is no %s; the session path names it "
                          "all the same" % plain_name))

    detail = {"trials_completed": trials[0]} if hold is None else {}
    return Group(
        key=key, kind="behavior", layout=NAME, root=spec.root, directory=spec.path,
        rig=spec.rig, time_zone=spec.time_zone, source_path=source_path,
        source_value=base, subject_folder=folder, subject_in_name=p0.subject,
        label=base, session_path=source_path + ".mat", start_local=p0.start_local,
        date=p0.date, precision=p0.precision, duration=None,
        files=tuple(sorted(files, key=lambda x: x.path)),
        held_files=tuple(sorted(held_files, key=lambda x: x.path)),
        detail=detail, notes=tuple(notes),
        status="ready" if hold is None else "held", hold=hold)
