"""Data model of the NAS importer's database-free half.

Everything here is a frozen dataclass: the stages (walk -> layout -> subjects
-> pairing) never modify a value, they return new ones
(``dataclasses.replace``). Paths are always relative to the storage root,
with ``/`` separators, spelled exactly as the directory listing gave them.
Sizes and modification times are whole numbers (``st_size``,
``st_mtime_ns``); nothing here holds a binary float.

Categories of what a scan finds (each listed file ends up in exactly one):

* a file of a :class:`Group` -- ``group.files`` (registrable) or
  ``group.held_files`` (held one by one, still part of the group);
* a loose :class:`HeldItem` -- held, belongs to no group;
* a :class:`ReportedItem` -- not registered and nothing to decide: an empty
  folder, or a file under a level-1 folder an override skips;
* an :class:`IgnoredItem` -- ignored by name (``.DS_Store`` ...), counted.

A group's ``status`` is one of ``ready`` (registrable, once the database side
has seen it unchanged for the directory's minimum age), ``held`` (see
``group.hold``) or ``skipped`` (an override said ``skip``). No group is
``ready`` from an incomplete listing.

Every held item and every group hold carries a stable snake_case
``reason_code`` from :data:`REASON_CODES` and a sentence for people.
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from fractions import Fraction

TOOL_NAME = "import_nas_files"

# reason code -> what it means. A code is part of the interface (it is stored
# in lab.scan_file.reason_code): never rename one, only add.
REASON_CODES: dict[str, str] = {
    # walker / any layout
    "symbolic_link": "a symbolic link, junction or other reparse point; never followed",
    "not_a_regular_file": "neither a regular file nor a folder (device, FIFO, socket)",
    "path_not_storable": "the path cannot be stored as it is (not UTF-8, a backslash, or "
                         "white space at an end)",
    "unreadable_file": "the file could not be opened or read",
    "changed_during_scan": "the file's size or modification time changed between the "
                           "listing and reading it",
    "zero_byte": "the file holds zero bytes",
    "not_in_subject_folder": "a file directly in the listed directory, not in a subject folder",
    "unexpected_depth": "a file deeper than the layout allows",
    "unrecognised_name": "the name matches no rule of the layout",
    "invalid_name_time": "the name holds an invalid date or time",
    # MAT files
    "mat_v73": "a MATLAB v7.3 (HDF5) file; only MAT 5.0 is read",
    "mat_not_mat5": "not a MAT 5.0 file (a v4 file or not a MAT file)",
    "mat_truncated": "the MAT file ends inside its header or a variable",
    "mat_corrupt": "the MAT file's structure cannot be read",
    "mat_big_endian": "a big-endian MAT file, which this reader does not read",
    "mat_not_epsych": "the MAT file lacks the variables Data and Info of an ePsych session",
    "mat_data_size_unknown": "the size of the variable Data cannot be read from its header",
    # ePsych groups
    "epsych_trials_disagree": "files of one session give different trial counts",
    "epsych_duplicate_session": "two sessions of one subject folder share a time but spell "
                                "the subject differently",
    "no_valid_epsych_file": "no file of the session is a readable ePsych session file",
    "video_without_mat": "a video whose name matches no ePsych session file",
    "video_not_mpeg_ts": "a .ts file without MPEG-TS sync bytes at its packet starts",
    "converted_video_without_source": "a _conv.mp4 whose .ts is not in the folder",
    "converted_video_source_held": "a _conv.mp4 whose .ts is held",
    # Intan groups
    "not_in_recording_folder": "a file directly in a subject folder, not in a recording folder",
    "unrecognised_folder": "a folder whose name is not <name>_<yyMMdd>_<HHmmss>",
    "recording_folder_without_rhd": "a recording-named folder holding no .rhd file",
    "rhd_in_subfolder": "an .rhd file in a subfolder of a recording folder",
    "intan_split_format": "an info.rhd file: a split-format recording, not read by this layout",
    "rhd_unknown_version": "an .rhd file whose main version is not 1, 2 or 3",
    "rhd_bad_magic": "an .rhd file without the Intan magic number 0xC6912702",
    "rhd_truncated": "the .rhd file ends inside its header",
    "rhd_bad_header": "the .rhd header holds a value this reader cannot accept",
    "rhd_partial_block": "the .rhd data is not a whole number of data blocks",
    "rhd_header_mismatch": "the .rhd files of one recording disagree on sample rate or "
                           "channel count",
    "rhd_no_amplifier_channels": "the .rhd header has no enabled amplifier channel",
    "rhd_duration_inexact": "the duration has no exact decimal value",
    # subjects and overrides
    "subject_mismatch": "the name names another subject than the subject folder",
    "subject_folder_case_variant": "the subject folder matches a subject only when case is ignored",
    "override_unknown_subject": "the override names a subject that does not exist",
    "override_skip": "an override says to skip it",
    "unknown_subject": "in a level-1 folder that is not a known subject",
    "not_a_subject_folder": "retired: no longer produced (see unknown_subject)",
    "name_case_conflict": "another name in the same folder differs from it only in case",
    "listing_incomplete": "part of the listing could not be read; nothing is registered",
    "empty_folder": "an empty folder",
    # pairing and whole-scan checks
    "pairing_ambiguous": "another candidate lies within the ambiguity margin",
    "paired_recording_held": "the recording it pairs with is held or not registrable",
    "session_label_conflict": "two sessions of one subject would get the same label",
}

# Codes of notes: things done or noticed that do not stop registration.
NOTE_CODES: dict[str, str] = {
    "subject_name_case_variant": "the subject in the name differs from the folder only in case",
    "override_applied": "an override named the subject",
    "epsych_suffix": "the session has suffixed twin files",
    "rhd_no_data_blocks": "an .rhd file holds a header and no data block",
    "pairing_paired": "paired with a session of the other directory",
    "pairing_unpaired": "no partner within the pairing window",
    "pairing_short": "the recording is shorter than the pairing minimum",
    "pairing_ambiguous": "the pairing is ambiguous",
    "pairing_date_only": "a date-only session is never paired",
    "pairing_skipped_recording": "a recording in the pairing window was skipped by an override",
    "epsych_no_plain_file": "the session has no file without a suffix",
}


def with_hold(g: "Group", hold: "Hold") -> "Group":
    """G held for HOLD; a group already held (or skipped) keeps its state and notes this one."""
    if g.status in ("held", "skipped") and g.hold is not None:
        return dataclasses.replace(g, notes=g.notes + (Note(hold.reason_code,
                                                            "also: " + hold.sentence),))
    return dataclasses.replace(g, status="held", hold=hold)


def check_reason(code: str) -> str:
    """Return CODE if it is a known reason code, else raise ValueError."""
    if code not in REASON_CODES:
        raise ValueError("unknown reason code %r" % code)
    return code


@dataclass(frozen=True)
class ListedFile:
    """One regular file as listed: path under the root, size, st_mtime_ns."""
    path: str
    size: int
    mtime_ns: int


@dataclass(frozen=True)
class DirectorySpec:
    """One directory to read.

    ``min_age_min`` is carried only as data for the database side; nothing in
    this package acts on it.
    """
    root: str
    path: str
    layout: str
    time_zone: str               # IANA zone of the wall-clock times in the names
    min_age_min: int
    rig: str | None = None
    pair_with: str | None = None   # path of the directory this one pairs with (same root)
    paired_by: str | None = None   # path of the directory whose pair_with names this one


@dataclass(frozen=True)
class UnreadableItem:
    """A folder that could not be listed or a file that could not be stat'ed."""
    path: str
    is_dir: bool
    error: str


@dataclass(frozen=True)
class IgnoredItem:
    """An entry ignored by name; a folder counts the files beneath it."""
    path: str
    reason_code: str            # "ignored_name" | "root_marker"
    is_dir: bool
    file_count: int | None      # files beneath an ignored folder (None if unknown)
    error: str | None = None


@dataclass(frozen=True)
class Listing:
    """What the walker saw of one directory.

    ``complete`` is False when anything could not be listed or stat'ed
    (see ``unreadable``): the caller must then conclude nothing from absent
    files and register nothing from this listing.
    """
    spec: DirectorySpec
    files: tuple[ListedFile, ...]
    dirs: tuple[str, ...]
    links: tuple[str, ...]
    special: tuple[str, ...]
    ignored: tuple[IgnoredItem, ...]
    unreadable: tuple[UnreadableItem, ...]
    complete: bool


@dataclass(frozen=True)
class HeldItem:
    """A held file (or, for ``is_dir``, folder) with its reason."""
    path: str
    reason_code: str
    sentence: str
    size: int | None = None
    mtime_ns: int | None = None
    group_key: str | None = None

    def __post_init__(self):
        check_reason(self.reason_code)


@dataclass(frozen=True)
class ReportedItem:
    """A file or folder that is not registered by rule; nothing to decide."""
    path: str
    reason_code: str
    sentence: str
    is_dir: bool = False
    size: int | None = None
    mtime_ns: int | None = None

    def __post_init__(self):
        check_reason(self.reason_code)


@dataclass(frozen=True)
class Note:
    """Something done or noticed about a group that does not stop it."""
    code: str
    sentence: str


@dataclass(frozen=True)
class Hold:
    """Why a whole group is held."""
    reason_code: str
    sentence: str

    def __post_init__(self):
        check_reason(self.reason_code)


@dataclass(frozen=True)
class GroupFile:
    """A registrable file of a group: what its lab.artifact row says."""
    path: str
    size: int
    mtime_ns: int
    role: str                    # "raw" | "video"
    format: str | None           # lower-case extension without the dot; None without one
    attributes: dict = field(hash=False)


@dataclass(frozen=True)
class Override:
    """One row of the reviewed overrides CSV."""
    root: str
    path: str
    subject_id: str | None       # None when skip
    skip: bool
    reason: str
    line: int


@dataclass(frozen=True)
class Pairing:
    """The pairing result of a group (recording or timestamped ePsych)."""
    status: str                  # paired | unpaired | short | ambiguous | date_only
    partner_key: str | None = None
    delta_s: int | None = None   # ePsych start minus recording start, seconds
    note: str = ""


@dataclass(frozen=True)
class Group:
    """One session and one event, with its files.

    key            stable while files are added: ``recording:<root>:<folder>``
                   or ``behavior:<root>:<subject folder>/<subject>_<stamp>``
    source_path    the recording folder, or the ePsych session's base path
                   (``<dir>/<folder>/<subject>_<stamp>``, no extension): the
                   path of the event id
    source_value   the verbatim name the time was read from
    session_path   the session's relative_path: the recording folder, the
                   ePsych file (unpaired), or the paired recording's folder
    start_local    lab wall-clock start ``YYYY-MM-DD HH:MM:SS``; None for a
                   date-only session
    date           ``YYYY-MM-DD``
    precision      ``second`` | ``day``
    duration       exact recording duration in seconds (recording only)
    detail         the event detail row's values (numbers as exact text)
    """
    key: str
    kind: str
    layout: str
    root: str
    directory: str
    rig: str | None
    time_zone: str
    source_path: str
    source_value: str
    subject_folder: str
    subject_in_name: str
    label: str
    session_path: str
    start_local: str | None
    date: str
    precision: str
    duration: Fraction | None
    files: tuple[GroupFile, ...]
    held_files: tuple[HeldItem, ...]
    detail: dict = field(hash=False)
    notes: tuple[Note, ...] = ()
    status: str = "ready"
    hold: Hold | None = None
    subject_id: str | None = None
    override: Override | None = None
    pairing: Pairing | None = None

    @property
    def occurred_local(self) -> str:
        """Wall-clock occurred_at text: the start, or 12:00 of a date-only day."""
        return self.start_local if self.start_local is not None else self.date + " 12:00:00"

    def all_paths(self) -> tuple[str, ...]:
        """Every listed file of the group, registrable or held, sorted."""
        return tuple(sorted([f.path for f in self.files] + [h.path for h in self.held_files]))


@dataclass(frozen=True)
class LayoutResult:
    """What a layout makes of one listing."""
    groups: tuple[Group, ...]
    held: tuple[HeldItem, ...]
    reported: tuple[ReportedItem, ...]


@dataclass(frozen=True)
class Interpretation:
    """The whole database-free result of a scan."""
    groups: tuple[Group, ...]
    held: tuple[HeldItem, ...]
    reported: tuple[ReportedItem, ...]
    ignored: tuple[IgnoredItem, ...]
    unreadable: tuple[UnreadableItem, ...]
    unused_overrides: tuple[Override, ...]
    complete: bool
    # Header entries from FRESH reads in this pass, by (root, path, size,
    # mtime_ns), for the caller to store (cache.HeaderCache); never a
    # transient outcome. Empty for files whose entry came from the cache.
    headers: dict = field(default_factory=dict, hash=False)
