"""Reading the start of a listed file, and the MPEG-TS check.

``open_listed(root_path, listed)`` opens a file for reading only and checks
that its size and ``st_mtime_ns`` are still what the listing said; if not
(the file is being written or was replaced), :class:`ContentProblem`
``changed_during_scan``. An OSError becomes ``unreadable_file``. The readers
(:mod:`.mat5`, :mod:`.rhd`, :func:`check_mpeg_ts`) take an open binary file
and the listed size, and raise :class:`ContentProblem` with a reason code.
"""

from __future__ import annotations

import os
from contextlib import contextmanager

from .model import ListedFile, check_reason

# Version of what check_mpeg_ts makes of a file's bytes (cache.py). Raise it
# whenever its result for the same bytes could change.
TS_READER = "ts/1"

# Outcomes that depend on the moment, not on the bytes: never cached.
TRANSIENT = frozenset({"unreadable_file", "changed_during_scan"})

TS_PACKET = 188
TS_SYNC = 0x47
TS_PACKETS_CHECKED = 8


class ContentProblem(Exception):
    """A file's content does not hold what its name says; has a reason code."""

    def __init__(self, code: str, sentence: str):
        super().__init__(sentence)
        self.code = check_reason(code)
        self.sentence = sentence


def absolute_path(root_path: str, rel: str) -> str:
    """The file's path on this computer: ROOT_PATH joined with REL's '/' parts."""
    return os.path.join(root_path, *rel.split("/"))


@contextmanager
def open_listed(root_path: str, listed: ListedFile):
    """Open LISTED for reading; ContentProblem if it changed since it was listed."""
    path = absolute_path(root_path, listed.path)
    try:
        fh = open(path, "rb")
    except OSError as exc:
        raise ContentProblem("unreadable_file", "cannot open the file: %s" % exc) from exc
    try:
        try:
            st = os.fstat(fh.fileno())
        except OSError as exc:
            raise ContentProblem("unreadable_file", "cannot stat the open file: %s" % exc) from exc
        if st.st_size != listed.size or st.st_mtime_ns != listed.mtime_ns:
            raise ContentProblem(
                "changed_during_scan",
                "listed with %d bytes and mtime_ns %d, now %d bytes and mtime_ns %d"
                % (listed.size, listed.mtime_ns, st.st_size, st.st_mtime_ns))
        yield fh
    except OSError as exc:
        raise ContentProblem("unreadable_file", "cannot read the file: %s" % exc) from exc
    finally:
        fh.close()


def check_mpeg_ts(fh, size: int) -> int:
    """Check the sync byte 0x47 at the start of the first packets of an MPEG-TS file.

    Checks min(8, size // 188) packets of 188 bytes; returns that number.
    ContentProblem ``video_not_mpeg_ts`` when the file is shorter than one
    packet or a sync byte is missing.
    """
    if size < TS_PACKET:
        raise ContentProblem("video_not_mpeg_ts",
                             "%d bytes, shorter than one 188-byte MPEG-TS packet" % size)
    n = min(TS_PACKETS_CHECKED, size // TS_PACKET)
    data = fh.read(n * TS_PACKET)
    if len(data) != n * TS_PACKET:
        raise ContentProblem("unreadable_file", "the file ended early while reading it")
    for k in range(n):
        if data[k * TS_PACKET] != TS_SYNC:
            raise ContentProblem("video_not_mpeg_ts",
                                 "no MPEG-TS sync byte 0x47 at byte %d (packet %d)"
                                 % (k * TS_PACKET, k + 1))
    return n
