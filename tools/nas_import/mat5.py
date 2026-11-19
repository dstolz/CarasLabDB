"""Top-level variable names, classes and dimensions of a MAT 5.0 file.

A standard-library reader of the "MAT-File Format" (MathWorks, Level 5):

* a 128-byte header: 116 bytes of text starting ``MATLAB 5.0 MAT-file``,
  8 bytes of subsystem offset, the version 0x0100 and the endian indicator
  ``IM`` (little-endian; ``MI`` is big-endian);
* then top-level data elements, each an 8-byte tag (type, byte count) and
  its data: ``miMATRIX`` (14) or ``miCOMPRESSED`` (15, a zlib stream holding
  one ``miMATRIX``). The next element starts right after the byte count.

For each variable only the start is read: the array-flags, dimensions and
name sub-elements of its ``miMATRIX`` (and, for a struct, its field names).
A compressed variable is inflated with ``zlib.decompressobj`` only until
those are complete; the rest is skipped by the element's byte count. Measured
bounds: one read of at most :data:`CHUNK` (4,096) bytes of compressed data
per compressed variable for ordinary headers, and at most :data:`HEADER_CAP`
(65,536) bytes per uncompressed variable (or of inflated output).

Plausibility (``mat_corrupt``): a variable's byte count must be able to hold
its elements -- at least one byte per element of a numeric, logical or char
array (no MAT storage type is smaller), an 8-byte tag per cell, and an 8-byte
tag per field per element of a struct array with fields. Sparse arrays,
objects, function handles and opaque objects are not bounded.

Classified, as :class:`MatProblem` (a ContentProblem) with a reason code:
``mat_v73`` (MATLAB 7.3, HDF5), ``mat_not_mat5`` (v4 or not a MAT file),
``mat_truncated`` (ends inside the header, a tag or an element),
``mat_corrupt`` (a structure that cannot be read, a zlib error, a duplicate
variable name, an implausible byte count), ``mat_big_endian`` (not read).

:func:`read_variables` is the cheap header pass. :func:`verify_file` is the
full structural pass, for a file about to be registered: it inflates every
compressed variable to its end in constant memory (zlib verifies the
stream's Adler-32), checks that it holds exactly one ``miMATRIX`` whose byte
count equals the inflated length and that nothing follows the stream, and
that the sub-elements of every uncompressed variable tile it exactly and
agree with its dimensions (data bytes of a numeric array, fields of a
struct array, cells of a cell array).

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
READER = "mat5/2"

HEADER_CAP = 64 * 1024
CHUNK = 4096

CLASSES = {
    1: "cell", 2: "struct", 3: "object", 4: "char", 5: "sparse", 6: "double",
    7: "single", 8: "int8", 9: "uint8", 10: "int16", 11: "uint16", 12: "int32",
    13: "uint32", 14: "int64", 15: "uint64", 16: "function_handle", 17: "opaque",
}
MX_OPAQUE = 17
NUMERIC = frozenset({"char", "double", "single", "int8", "uint8", "int16", "uint16", "int32",
                     "uint32", "int64", "uint64"})
INFLATE_CHUNK = 1 << 20


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


def _parse_matrix(buf: bytes, compressed: bool, body_len: int, capped: bool) -> MatVariable:
    """Flags, dims and name of the miMATRIX body BUF (after its own tag).

    BODY_LEN is the body's byte count; CAPPED says BUF stops short of it
    because no more will be read. _NeedMore when BUF is too short.
    """
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
    var = MatVariable(name, mclass, dims, compressed)
    if pos > body_len:
        raise MatProblem("mat_corrupt", "a variable whose header overruns it")

    numel = var.numel
    if not numel or code == MX_OPAQUE:
        return var
    nfields = None
    if mclass == "struct":
        try:
            dtype, data, p2 = _sub(buf, pos)
            if dtype != MI_INT32 or len(data) != 4:
                raise MatProblem("mat_corrupt", "a struct without its field-name length")
            flen = struct.unpack("<i", data)[0]
            dtype, data, p2 = _sub(buf, p2)
            if dtype != MI_INT8 or flen < 0 or (flen and len(data) % flen):
                raise MatProblem("mat_corrupt", "a struct with malformed field names")
            nfields = len(data) // flen if flen else 0
            pos = p2
        except _NeedMore:
            if len(buf) >= body_len:
                raise MatProblem("mat_corrupt", "a struct whose field names overrun it") from None
            if not capped:
                raise
            nfields = None                   # beyond what is read: no bound
    remaining = body_len - pos
    if mclass in NUMERIC:
        need = 8 if numel <= 4 else 8 + numel
    elif mclass == "cell":
        need = 8 * numel
    elif mclass == "struct" and nfields:
        need = 8 * numel * nfields
    else:
        return var
    if remaining < need:
        raise MatProblem("mat_corrupt", "%s is a %s of %s elements in %d bytes, too few to hold "
                         "them" % (name or "a variable", mclass, "x".join(map(str, dims)), remaining))
    return var


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
            capped = len(out) >= HEADER_CAP
            try:
                return _parse_matrix(out[8:8 + inner], True, inner, capped)
            except _NeedMore:
                if len(out) >= 8 + inner or capped:
                    raise MatProblem("mat_corrupt", "a variable whose header overruns it") from None
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
    fh.seek(0)
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
                var = _parse_matrix(body, False, nbytes, nbytes > HEADER_CAP)
            except _NeedMore:
                raise MatProblem("mat_corrupt", "a variable whose header overruns it") from None
        else:
            raise MatProblem("mat_corrupt", "a top-level element of type %d" % dtype)
        if var.name and any(v.name == var.name for v in variables):
            raise MatProblem("mat_corrupt", "the variable %s appears twice" % var.name)
        variables.append(var)
        offset = end
    return tuple(variables)


def _inflate_whole(fh, nbytes: int, offset: int) -> None:
    """Inflate one compressed element to its end; check it is exactly one miMATRIX."""
    d = zlib.decompressobj()
    remaining = nbytes
    head = b""
    total = 0
    try:
        while remaining > 0:
            data = _read_exact(fh, min(CHUNK * 16, remaining), "a compressed variable")
            remaining -= len(data)
            while data:
                if d.eof:
                    raise MatProblem("mat_corrupt", "%d bytes follow the zlib stream of the "
                                     "variable at byte %d" % (len(data) + remaining, offset))
                out = d.decompress(data, INFLATE_CHUNK)
                if len(head) < 8:
                    head += out[:8 - len(head)]
                total += len(out)
                data = d.unconsumed_tail
        if not d.eof:
            out = d.flush()
            total += len(out)
            if len(head) < 8:
                head += out[:8 - len(head)]
        if not d.eof:
            raise MatProblem("mat_truncated", "the zlib stream of the variable at byte %d does "
                             "not end" % offset)
        if d.unused_data:
            raise MatProblem("mat_corrupt", "%d bytes follow the zlib stream of the variable at "
                             "byte %d" % (len(d.unused_data), offset))
    except zlib.error as exc:
        raise MatProblem("mat_corrupt", "the variable at byte %d cannot be inflated: %s"
                         % (offset, exc)) from exc
    if len(head) < 8:
        raise MatProblem("mat_corrupt", "the variable at byte %d inflates to %d bytes" % (offset, total))
    dtype, inner = struct.unpack("<II", head)
    if dtype != MI_MATRIX or 8 + inner != total:
        raise MatProblem("mat_corrupt", "the variable at byte %d inflates to %d bytes, its matrix "
                         "claims %d" % (offset, total, 8 + inner))


_TYPE_BYTES = {1: 1, 2: 1, 3: 2, 4: 2, 5: 4, 6: 4, 7: 4, 9: 8, 12: 8, 13: 8, 17: 2, 18: 4}
_COMPLEX = 0x0800
_SMALL_READ = 1 << 20


def _children(fh, start: int, end: int, what: str):
    """(type, byte count, data offset) of each sub-element tiling [start, end)."""
    out = []
    pos = start
    while pos < end:
        if end - pos < 8:
            raise MatProblem("mat_corrupt", "%s ends inside a sub-element tag" % what)
        fh.seek(pos)
        first, second = struct.unpack("<II", _read_exact(fh, 8, "a sub-element tag"))
        if first >> 16:
            n = first >> 16
            if n > 4:
                raise MatProblem("mat_corrupt", "%s has a small element of %d bytes" % (what, n))
            out.append((first & 0xFFFF, n, pos + 4))
            pos += 8
        else:
            out.append((first, second, pos + 8))
            pos += 8 + ((second + 7) // 8) * 8
    if pos != end:
        raise MatProblem("mat_corrupt", "the sub-elements of %s overrun it" % what)
    return out


def _data(fh, child, limit=_SMALL_READ) -> bytes:
    dtype, n, at = child
    if n > limit:
        raise MatProblem("mat_corrupt", "a header sub-element of %d bytes" % n)
    fh.seek(at)
    return _read_exact(fh, n, "a sub-element")


def _check_body(fh, offset: int, nbytes: int) -> None:
    """An uncompressed variable: its sub-elements tile it, and their number and
    sizes agree with its class and dimensions (numeric data bytes = numel x the
    storage type's size; numel x nfields fields of a struct; numel cells)."""
    what = "the variable at byte %d" % offset
    kids = _children(fh, offset + 8, offset + 8 + nbytes, what)
    if len(kids) < 3:
        raise MatProblem("mat_corrupt", "%s lacks its header sub-elements" % what)
    if kids[0][0] != MI_UINT32 or kids[0][1] != 8:
        raise MatProblem("mat_corrupt", "%s lacks its array flags" % what)
    flags = struct.unpack("<II", _data(fh, kids[0]))[0]
    code = flags & 0xFF
    if code == MX_OPAQUE:
        return
    if kids[1][0] != MI_INT32 or kids[1][1] % 4 or kids[1][1] < 8:
        raise MatProblem("mat_corrupt", "%s lacks valid dimensions" % what)
    dims = struct.unpack("<%di" % (kids[1][1] // 4), _data(fh, kids[1]))
    numel = 1
    for d in dims:
        numel *= d
    rest = kids[3:]
    mclass = CLASSES.get(code)
    if mclass in NUMERIC:
        want = 2 if flags & _COMPLEX else 1
        if len(rest) != want and not (numel == 0 and not rest):
            raise MatProblem("mat_corrupt", "%s (%s) has %d data parts, not %d"
                             % (what, mclass, len(rest), want))
        for dtype, n, _at in rest:
            size = _TYPE_BYTES.get(dtype)
            if size is not None and n != numel * size:
                raise MatProblem("mat_corrupt", "%s holds %d bytes of data for %d elements"
                                 % (what, n, numel))
    elif mclass == "struct":
        if len(rest) < 2:
            raise MatProblem("mat_corrupt", "%s is a struct without field names" % what)
        if rest[0][0] != MI_INT32 or rest[0][1] != 4:
            raise MatProblem("mat_corrupt", "%s lacks its field-name length" % what)
        flen = struct.unpack("<i", _data(fh, rest[0]))[0]
        nfields = rest[1][1] // flen if flen > 0 else 0
        if len(rest) - 2 != numel * nfields:
            raise MatProblem("mat_corrupt", "%s holds %d fields for %d elements of %d fields"
                             % (what, len(rest) - 2, numel, nfields))
    elif mclass == "cell":
        if len(rest) != numel:
            raise MatProblem("mat_corrupt", "%s holds %d cells for %d elements"
                             % (what, len(rest), numel))


def verify_file(fh, size: int) -> None:
    """Full structural check of the MAT 5.0 file open as FH; MatProblem on damage.

    Runs :func:`read_variables`, then inflates every compressed variable to
    its end (constant memory; zlib checks the stream) and checks that the
    sub-elements of every uncompressed variable tile it.
    """
    read_variables(fh, size)
    offset = 128
    while offset < size:
        fh.seek(offset)
        dtype, nbytes = struct.unpack("<II", _read_exact(fh, 8, "a variable's tag"))
        if dtype == MI_COMPRESSED:
            _inflate_whole(fh, nbytes, offset)
        else:
            _check_body(fh, offset, nbytes)
        offset += 8 + nbytes


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


def from_entry(entry: dict, size: int) -> tuple[MatVariable, ...]:
    """The variables of a cache entry for a file of SIZE bytes; ValueError unless every
    value is one a fresh read could give (classes, int32 dimensions, ASCII names, at
    most one variable per 8 bytes of the file, no repeated name).
    """
    if set(entry) != {"reader", "variables"}:
        raise ValueError("unexpected keys")
    rows = entry["variables"]
    if not isinstance(rows, list) or len(rows) * 8 > max(0, size - 128):
        raise ValueError("variables is not a plausible list")
    out = []
    seen = set()
    for row in rows:
        if not isinstance(row, list) or len(row) != 4:
            raise ValueError("a malformed variable row")
        name, mclass, dims, compressed = row
        if (not isinstance(name, str) or not name.isascii() or len(name) > 65535
                or not isinstance(mclass, str) or mclass not in CLASSES.values()
                or type(compressed) is not bool
                or not (dims is None or (isinstance(dims, list) and 2 <= len(dims) <= 16384
                                         and all(type(d) is int and 0 <= d <= 0x7FFFFFFF
                                                 for d in dims)))
                or (dims is None and mclass != "opaque")):
            raise ValueError("a malformed variable row")
        if name and name in seen:
            raise ValueError("a repeated variable")
        seen.add(name)
        out.append(MatVariable(name, mclass, None if dims is None else tuple(dims), compressed))
    return tuple(out)
