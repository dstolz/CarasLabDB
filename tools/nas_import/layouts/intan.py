"""Layout ``intan``: ``<dir>/<subject folder>/<SUBJ>_<yyMMdd>_<HHmmss>/<files>``.

A recording folder is a folder directly under a subject folder whose name
has the Intan form (:func:`..names.parse_intan_folder`); it is registrable
when it holds at least one ``.rhd`` file directly (as ``IntanReader.discoverFiles`` finds them,
extension compared without case). EVERY file in it, recursively, belongs to
the recording: one session, one ``recording`` event, one ``raw`` artifact per
file (``{"kind": "raw", "reader": "intan"}`` as ``LabCapture.copiedSession``
writes them, plus ``source_mtime``), ``settings.xml`` and ``_manifest.json``
included.

Content: every ``.rhd`` directly in the folder is parsed (:mod:`..rhd`); the
event's ``sample_rate_hz``, ``n_channels`` and ``duration_s`` come from them
(exact decimal text). The whole recording is held when:

* an ``.rhd`` cannot be parsed or is not a whole number of data blocks
  (``rhd_bad_magic``, ``rhd_truncated``, ``rhd_bad_header``,
  ``rhd_partial_block``, ``unreadable_file``, ``changed_during_scan``);
* the files disagree on sample rate or channel count (``rhd_header_mismatch``);
* an ``.rhd`` lies in a subfolder (``rhd_in_subfolder``) or an ``info.rhd``
  says it is a split-format recording (``intan_split_format``);
* the duration has no exact decimal (``rhd_duration_inexact``).

A folder with the recording name but no ``.rhd`` directly in it is still a
group, held ``recording_folder_without_rhd`` (so it takes part in pairing:
an ePsych session near it is never registered alone). A link, a special
entry or a file with an unstorable name anywhere in a recording folder
holds the whole recording with that entry's code and is part of the
group's signature. A zero-byte file other than an ``.rhd`` is held on its
own (``zero_byte``), inside the group. Files directly in the listed
directory or in a subject folder, and folders of another name, are held;
empty folders are reported.
"""

from __future__ import annotations

import dataclasses
from collections import defaultdict

from ..cache import HeaderReader
from ..content import ContentProblem
from ..model import Group, Hold, HeldItem, LayoutResult, ListedFile, Listing, Note
from ..names import BadNameTime, parse_intan_folder
from ..rhd import decimal_text, recording_summary
from ._common import (empty_folders, file_format, group_file, held, odd_hold_sentence,
                      parts_under, split_listing, unstorable_reason)

NAME = "intan"
ACQUISITION_SYSTEM = "intan_rhx"          # LabCapture.acquisitionSystem("intan")


def interpret_listing(listing: Listing, reader: HeaderReader) -> LayoutResult:
    """Groups and held items of one Intan directory listing."""
    spec = listing.spec
    files_ok, odd = split_listing(listing)
    loose: list[HeldItem] = []
    folders: dict[tuple[str, str], list[ListedFile]] = defaultdict(list)
    odd_in: dict[tuple[str, str], list[HeldItem]] = defaultdict(list)
    for f in files_ok:
        parts = parts_under(listing, f.path)
        if len(parts) == 1:
            loose.append(held(f, "not_in_subject_folder",
                              "a file directly in %s, not in a subject folder" % spec.path))
        elif len(parts) == 2:
            loose.append(held(f, "not_in_recording_folder",
                              "a file directly in the subject folder, not in a recording folder"))
        else:
            folders[(parts[0], parts[1])].append(f)
    for h in odd:
        parts = parts_under(listing, h.path)
        if len(parts) >= 3:
            odd_in[(parts[0], parts[1])].append(h)
        else:
            loose.append(h)

    groups: list[Group] = []
    for (subject_folder, rec) in sorted(set(folders) | set(odd_in)):
        files = sorted(folders.get((subject_folder, rec), []), key=lambda x: x.path)
        odd_here = odd_in.get((subject_folder, rec), [])
        folder_path = "%s/%s/%s" % (spec.path, subject_folder, rec)
        if unstorable_reason(folder_path) is not None:
            loose += odd_here       # every entry below is already path_not_storable
            continue
        try:
            parsed = parse_intan_folder(rec)
        except BadNameTime as exc:
            loose += [held(f, "invalid_name_time", "the folder %s holds an invalid date or time: %s"
                           % (rec, exc)) for f in files] + odd_here
            continue
        if parsed is None:
            loose += [held(f, "unrecognised_folder", "the folder %s is not named "
                           "<subject>_<yyMMdd>_<HHmmss>" % rec) for f in files] + odd_here
            continue
        direct = [f for f in files if f.path.count("/") == folder_path.count("/") + 1]
        rhds = [f for f in direct if file_format(f.path) == "rhd"]
        groups.append(_group(listing, reader, subject_folder, rec, parsed, folder_path,
                             files, rhds, odd_here))
    return LayoutResult(tuple(groups), tuple(sorted(loose, key=lambda x: x.path)),
                        tuple(empty_folders(listing)))


def _group(listing, reader, subject_folder, rec, parsed, folder_path, files, rhds, odd) -> Group:
    spec = listing.spec
    key = "recording:%s:%s" % (spec.root, folder_path)
    hold: Hold | None = None
    notes: list[Note] = []
    held_files: list[HeldItem] = [dataclasses.replace(h, group_key=key) for h in odd]
    out = []
    rhd_paths = {f.path for f in rhds}

    nested = [f.path for f in files if f.path not in rhd_paths and file_format(f.path) == "rhd"]
    split = [f.path for f in files if f.path.rsplit("/", 1)[1].lower() == "info.rhd"]
    if odd:
        hold = Hold(odd[0].reason_code, odd_hold_sentence(odd[0]))
    elif split:
        hold = Hold("intan_split_format", "%s: a split-format recording, which this layout "
                    "does not read" % split[0])
    elif nested:
        hold = Hold("rhd_in_subfolder", "%s lies in a subfolder of the recording folder"
                    % nested[0])
    elif not rhds:
        hold = Hold("recording_folder_without_rhd", "the folder %s holds no .rhd file" % rec)

    headers = []
    if hold is None:
        for f in rhds:
            try:
                headers.append((f.path.rsplit("/", 1)[1], reader.read(f, "rhd")))
            except ContentProblem as exc:
                hold = Hold(exc.code, "%s: %s" % (f.path.rsplit("/", 1)[1], exc.sentence))
                break
    duration = None
    detail: dict = {}
    if hold is None:
        try:
            summary = recording_summary(headers)
        except ContentProblem as exc:
            hold = Hold(exc.code, exc.sentence)
        else:
            rate_text = decimal_text(summary.sample_rate)
            dur_text = decimal_text(summary.duration)
            if rate_text is None or dur_text is None:
                hold = Hold("rhd_duration_inexact", "%d samples at %s Hz have no exact decimal "
                            "duration" % (summary.total_samples, summary.sample_rate))
            else:
                duration = summary.duration
                detail = {"acquisition_system_code": ACQUISITION_SYSTEM, "modality": "ephys",
                          "sample_rate_hz": rate_text, "n_channels": summary.n_channels,
                          "duration_s": dur_text}
                if summary.files_without_data:
                    notes.append(Note("rhd_no_data_blocks", "no data block in %s"
                                      % ", ".join(summary.files_without_data)))

    for f in files:
        if f.size == 0 and f.path not in rhd_paths:
            held_files.append(held(f, "zero_byte", "the file holds zero bytes", key))
        else:
            out.append(group_file(f, "raw", {"kind": "raw", "reader": "intan"}))

    return Group(
        key=key, kind="recording", layout=NAME, root=spec.root, directory=spec.path,
        rig=spec.rig, time_zone=spec.time_zone, source_path=folder_path, source_value=rec,
        subject_folder=subject_folder, subject_in_name=parsed.subject, label=rec,
        session_path=folder_path, start_local=parsed.start_local, date=parsed.date,
        precision="second", duration=duration, files=tuple(out),
        held_files=tuple(held_files), detail=detail, notes=tuple(notes),
        status="ready" if hold is None else "held", hold=hold)
