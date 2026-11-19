"""Top-level variable names, classes and dimensions of a MAT 5.0 file.

A standard-library reader of the "MAT-File Format" (MathWorks, Level 5):

* a 128-byte header: 116 bytes of text starting ``MATLAB 5.0 MAT-file``,
  8 bytes of subsystem offset, the version 0x0100 and the endian indicator
  ``IM`` (little-endian; ``MI`` is big-endian);
* then top-level data elements, each an 8-byte tag (type, byte count) and
  its data: ``miMATRIX`` (14) or ``miCOMPRESSED`` (15, a zlib stream holding
  one ``miMATRIX``). The next element starts right after the byte count.

For each variable only the start is read: the array-flags, dimensions and
name sub-elements of its ``miMATRIX``. A compressed variable is inflated with
``zlib.decompressobj`` only until those are complete (at most
:data:`HEADER_CAP` bytes of output); the rest is skipped by the element's
byte count. So a file is read for its 128-byte header and a few hundred
bytes per variable, whatever its size.

Classified, as :class:`MatProblem` (a ContentProblem) with a reason code:
``mat_v73`` (MATLAB 7.3, HDF5), ``mat_not_mat5`` (v4 or not a MAT file),
``mat_truncated`` (ends inside the header, a tag or an element),
``mat_corrupt`` (a structure that cannot be read, a zlib error, a duplicate
variable name), ``mat_big_endian`` (not read).

Not verified: the bytes of a variable beyond its header (a compressed
variable's stream is not inflated to its end, so damage there goes unseen;
the SHA-256 fixes the bytes, and MATLAB would report it on load).

The ePsych rule (ephys_analysis ``epsychSessionMeta.m``): an ePsych session
file has top-level variables ``Data`` and ``Info``; its trial count is the
number of elements of ``Data``, ``prod(size(Data))`` (see
:func:`epsych_trials`).
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass

from .content import ContentProblem

MI_INT8 = 1
MI_INT32 = 5
MI_UINT32 = 6
MI_MATRIX = 14
MI_COMPRESSED = 15

# Version of what this reader makes of a file's bytes, stored with every
# cached result (cache.py). Raise it whenever the result for the same bytes
# could change (a fix, a new class, another problem code): older cache
# entries are then ignored and the files read again.
READER = "mat5/1"

HEADER_CAP = 64 * 1024
CHUNK = 4096

CLASSES = {
    1: "cell", 2: "struct", 3: "object", 4: "char", 5: "sparse", 6: "double",
    7: "single", 8: "int8", 9: "uint8", 10: "int16", 11: "uint16", 12: "int32",
    13: "uint32", 14: "int64", 15: "uint64", 16: "function_handle", 17: "opaque",
}
MX_OPAQUE = 17


class MatProblem(ContentProblem):
    """The file is not a readable MAT 5.0 file (reason code in ``code``)."""


class _NeedMore(Exception):
    pass


@dataclass(frozen=True)
class MatVariable:
    """One top-level variable: name, class name and dimensions (None: not stored)."""
    name: str
    mclass: str
    dims: tuple[int, ...] | None
    compressed: bool

    @property
    def numel(self) -> int | None:
        """prod(dims); None when the dimensions are not stored (opaque class)."""
        if self.dims is None:
            return None
        n = 1
        for d in self.dims:
            n *= d
        return n


def _sub(buf: bytes, pos: int):
    """One sub-element at POS: (type, data, next position); _NeedMore if BUF is short."""
    if len(buf) < pos + 8:
        raise _NeedMore()
    first, second = struct.unpack_from("<II", buf, pos)
    if first >> 16:                       # small data element: 4-byte tag, data in 4 bytes
        dtype, n = first & 0xFFFF, first >> 16
        if n > 4:
            raise MatProblem("mat_corrupt", "a small data element claims %d bytes" % n)
        return dtype, buf[pos + 4:pos + 4 + n], pos + 8
    dtype, n = first, second
    end = pos + 8 + n
    if len(buf) < end:
        raise _NeedMore()
    return dtype, buf[pos + 8:end], pos + 8 + ((n + 7) // 8) * 8


def _parse_matrix(buf: bytes, compressed: bool) -> MatVariable:
    """Flags, dims and name of the miMATRIX body BUF (after its own tag)."""
    dtype, data, pos = _sub(buf, 0)
    if dtype != MI_UINT32 or len(data) != 8:
        raise MatProblem("mat_corrupt", "a variable without its array-flags sub-element")
    flags, _nzmax = struct.unpack("<II", data)
    code = flags & 0xFF
    mclass = CLASSES.get(code)
    if mclass is None:
        raise MatProblem("mat_corrupt", "unknown array class %d" % code)
    dims: tuple[int, ...] | None = None
    # An opaque (MCOS) object is described as storing its name right after
    # the flags, with no dimensions; accept either order for it, since no
    # fixture of one was available (a dims sub-element is read when present).
    opaque_without_dims = (code == MX_OPAQUE and len(buf) >= pos + 4
                           and struct.unpack_from("<I", buf, pos)[0] & 0xFFFF == MI_INT8)
    if not opaque_without_dims:
        dtype, data, pos = _sub(buf, pos)
        if dtype != MI_INT32 or len(data) % 4 or len(data) < 8:
            raise MatProblem("mat_corrupt", "a variable without a valid dimensions sub-element")
        dims = struct.unpack("<%di" % (len(data) // 4), data)
        if any(d < 0 for d in dims):
            raise MatProblem("mat_corrupt", "negative dimensions %r" % (dims,))
    dtype, data, pos = _sub(buf, pos)
    if dtype != MI_INT8:
        raise MatProblem("mat_corrupt", "a variable without its name sub-element")
    try:
        name = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise MatProblem("mat_corrupt", "a variable name that is not ASCII") from exc
    return MatVariable(name, mclass, dims, compressed)


def _read_exact(fh, n: int, what: str) -> bytes:
    data = fh.read(n)
    if len(data) != n:
        raise MatProblem("mat_truncated", "the file ends inside %s" % what)
    return data


def _compressed_variable(fh, nbytes: int) -> MatVariable:
    d = zlib.decompressobj()
    out = b""
    remaining = nbytes
    while True:
        if len(out) >= 8:
            dtype, inner = struct.unpack_from("<II", out, 0)
            if dtype != MI_MATRIX:
                raise MatProblem("mat_corrupt", "a compressed element that does not hold a matrix")
            try:
                return _parse_matrix(out[8:8 + inner], True)
            except _NeedMore:
                if len(out) >= 8 + inner:
                    raise MatProblem("mat_corrupt", "a variable whose header overruns it") from None
        if len(out) >= HEADER_CAP:
            raise MatProblem("mat_corrupt", "a variable header longer than %d bytes" % HEADER_CAP)
        if d.unconsumed_tail:
            data = d.unconsumed_tail
        elif remaining > 0 and not d.eof:
            data = _read_exact(fh, min(CHUNK, remaining), "a compressed variable")
            remaining -= len(data)
        else:
            raise MatProblem("mat_corrupt", "a compressed variable ends inside its header")
        try:
            out += d.decompress(data, HEADER_CAP - len(out))
        except zlib.error as exc:
            raise MatProblem("mat_corrupt", "a compressed variable cannot be inflated: %s" % exc) from exc


def read_variables(fh, size: int) -> tuple[MatVariable, ...]:
    """The top-level variables of the MAT 5.0 file open as FH (SIZE bytes), in file order."""
    head = fh.read(128)
    if len(head) < 128:
        prefix = b"MATLAB 5.0 MAT-file"
        if head and (head.startswith(prefix) or prefix.startswith(head)):
            raise MatProblem("mat_truncated", "%d bytes, shorter than the 128-byte header" % size)
        raise MatProblem("mat_not_mat5", "%d bytes and no MAT 5.0 header" % size)
    text, version, endian = head[:116], head[124:126], head[126:128]
    if text.startswith(b"MATLAB 7.3 MAT-file") or version in (b"\x00\x02", b"\x02\x00"):
        raise MatProblem("mat_v73", "a MATLAB 7.3 (HDF5) file")
    if not text.startswith(b"MATLAB 5.0 MAT-file"):
        raise MatProblem("mat_not_mat5", "no 'MATLAB 5.0 MAT-file' header text (a v4 file "
                                         "or not a MAT file)")
    if endian == b"MI":
        raise MatProblem("mat_big_endian", "a big-endian MAT 5.0 file, which is not read")
    if endian != b"IM" or version != b"\x00\x01":
        raise MatProblem("mat_corrupt", "an invalid version or endian indicator in the header")

    variables: list[MatVariable] = []
    offset = 128
    while offset < size:
        if size - offset < 8:
            raise MatProblem("mat_truncated", "%d stray bytes after the last variable"
                             % (size - offset))
        fh.seek(offset)
        dtype, nbytes = struct.unpack("<II", _read_exact(fh, 8, "a variable's tag"))
        if dtype >> 16:
            raise MatProblem("mat_corrupt", "a small data element at the top level")
        end = offset + 8 + nbytes
        if end > size:
            raise MatProblem("mat_truncated", "a variable at byte %d claims %d bytes; the file "
                             "ends %d bytes early" % (offset, nbytes, end - size))
        if dtype == MI_COMPRESSED:
            var = _compressed_variable(fh, nbytes)
        elif dtype == MI_MATRIX:
            if nbytes == 0:
                raise MatProblem("mat_corrupt", "an empty top-level matrix element")
            body = _read_exact(fh, min(nbytes, HEADER_CAP), "a variable")
            try:
                var = _parse_matrix(body, False)
            except _NeedMore:
                raise MatProblem("mat_corrupt", "a variable whose header overruns it") from None
        else:
            raise MatProblem("mat_corrupt", "a top-level element of type %d" % dtype)
        if var.name and any(v.name == var.name for v in variables):
            raise MatProblem("mat_corrupt", "the variable %s appears twice" % var.name)
        variables.append(var)
        offset = end
    return tuple(variables)


def epsych_trials(variables: tuple[MatVariable, ...]) -> int:
    """Trials of an ePsych session: numel(Data). MatProblem if Data or Info is missing.

    ``mat_not_epsych`` without ``Data`` and ``Info``; ``mat_data_size_unknown``
    when Data's dimensions are not stored (an opaque object).
    """
    names = {v.name: v for v in variables}
    missing = [n for n in ("Data", "Info") if n not in names]
    if missing:
        raise MatProblem("mat_not_epsych", "no variable %s (an ePsych session file has Data "
                         "and Info)" % " or ".join(missing))
    n = names["Data"].numel
    if n is None or names["Data"].mclass == "opaque":
        raise MatProblem("mat_data_size_unknown", "Data is a %s object whose size is not in "
                         "its header" % names["Data"].mclass)
    return n


def to_entry(variables: tuple[MatVariable, ...]) -> dict:
    """A JSON-ready cache entry of VARIABLES (see cache.py)."""
    return {"reader": READER, "variables": [
        [v.name, v.mclass, None if v.dims is None else list(v.dims), v.compressed]
        for v in variables]}


def from_entry(entry: dict) -> tuple[MatVariable, ...]:
    """The variables of a cache entry; ValueError if it is not well formed."""
    rows = entry["variables"]
    if not isinstance(rows, list):
        raise ValueError("variables is not a list")
    out = []
    for row in rows:
        name, mclass, dims, compressed = row
        if (not isinstance(name, str) or mclass not in CLASSES.values()
                or not isinstance(compressed, bool)
                or not (dims is None or (isinstance(dims, list) and all(
                    type(d) is int and d >= 0 for d in dims)))):
            raise ValueError("a malformed variable row")
        out.append(MatVariable(name, mclass, None if dims is None else tuple(dims), compressed))
    return tuple(out)
