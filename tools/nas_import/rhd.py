"""Header of an Intan RHD2000 traditional-format file (``*.rhd``).

A port of ephys_analysis ``pipeline/@IntanReader/parseIntanHeader.m``
(itself a header-only extraction of Intan's ``read_Intan_RHD2000_file``):
the same fields in the same order, the same version conditions, the same
bytes-per-block formula, the same whole-block count from the file size.
Little-endian throughout. What it gives:

* ``sample_rate`` -- the header's float32, as an exact :class:`Fraction`
  (a float32 is a dyadic rational, so its decimal text is exact);
* ``num_amplifier_channels`` -- enabled channels of signal type 0;
* ``header_bytes``, ``bytes_per_block``, ``samples_per_block`` (60 for
  main version 1, else 128), ``num_data_blocks`` and ``num_samples``.

Differences from the MATLAB, all towards refusing rather than guessing
(each a :class:`RhdProblem` with a reason code):

* a size that is not a whole number of data blocks is ``rhd_partial_block``
  (parseIntanHeader floors the count and flags ``partialBlock``;
  refreshMetadata only warns);
* a negative signal-group or channel count, an odd QString byte length, a
  non-finite or non-positive sample rate are ``rhd_bad_header`` (MATLAB would
  loop zero times, fail in fread, or divide by it);
* an unknown signal type is ``rhd_bad_header`` (MATLAB errors too).

``recording_summary`` combines the headers of one recording folder as
``IntanReader.refreshMetadata`` does: every file must have the first file's
amplifier channel count and sample rate (``rhd_header_mismatch`` otherwise);
the duration is the sum of each file's samples over the sample rate, kept
exact as a Fraction.
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from fractions import Fraction

from .content import ContentProblem

# Version of what this reader makes of a file's bytes, stored with every
# cached result (cache.py). Raise it whenever the result for the same bytes
# could change: older cache entries are then ignored and the files read again.
READER = "rhd/1"

MAGIC = 0xC6912702
NULL_QSTRING = 0xFFFFFFFF


class RhdProblem(ContentProblem):
    """The .rhd header cannot be read or accepted (reason code in ``code``)."""


@dataclass(frozen=True)
class RhdHeader:
    main_version: int
    secondary_version: int
    sample_rate: Fraction
    num_amplifier_channels: int
    num_aux_input_channels: int
    num_supply_voltage_channels: int
    num_board_adc_channels: int
    num_board_dig_in_channels: int
    num_board_dig_out_channels: int
    num_temp_sensor_channels: int
    samples_per_block: int
    bytes_per_block: int
    header_bytes: int
    file_size: int
    num_data_blocks: int

    @property
    def num_samples(self) -> int:
        """Amplifier samples in the file: samples_per_block * num_data_blocks."""
        return self.samples_per_block * self.num_data_blocks


class _Reader:
    def __init__(self, fh, size: int):
        self.fh = fh
        self.size = size
        self.pos = 0

    def take(self, n: int) -> bytes:
        if self.pos + n > self.size:
            raise RhdProblem("rhd_truncated", "the file (%d bytes) ends inside its header"
                             % self.size)
        data = self.fh.read(n)
        if len(data) != n:
            raise RhdProblem("rhd_truncated", "the file ends inside its header")
        self.pos += n
        return data

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def i16(self) -> int:
        return struct.unpack("<h", self.take(2))[0]

    def f32(self) -> float:
        return struct.unpack("<f", self.take(4))[0]

    def qstring(self) -> str:
        n = self.u32()
        if n == NULL_QSTRING:
            return ""
        if n % 2:
            raise RhdProblem("rhd_bad_header", "a QString of an odd byte length %d" % n)
        data = self.take(n)
        return data.decode("utf-16-le", errors="replace")


def read_header(fh, size: int) -> RhdHeader:
    """Parse the header of the .rhd file open as FH (SIZE bytes); see the module docstring."""
    r = _Reader(fh, size)
    if size < 4:
        raise RhdProblem("rhd_truncated", "%d bytes, shorter than the magic number" % size)
    magic = r.u32()
    if magic != MAGIC:
        raise RhdProblem("rhd_bad_magic", "magic number 0x%08X, not 0xC6912702" % magic)
    main = r.i16()
    secondary = r.i16()
    spb = 60 if main == 1 else 128

    rate = r.f32()
    if not math.isfinite(rate) or rate <= 0:
        raise RhdProblem("rhd_bad_header", "sample rate %r" % rate)
    r.i16()                                    # dsp_enabled
    for _ in range(6):                          # actual dsp cutoff, lower, upper; desired x3
        r.f32()
    r.i16()                                    # notch_filter_mode
    r.f32()                                    # desired impedance test frequency
    r.f32()                                    # actual impedance test frequency
    for _ in range(3):                          # notes
        r.qstring()
    num_temp = 0
    if (main == 1 and secondary >= 1) or main > 1:
        num_temp = r.i16()
    if (main == 1 and secondary >= 3) or main > 1:
        r.i16()                                # board_mode
    if main > 1:
        r.qstring()                            # reference channel

    counts = [0] * 6                            # by signal type 0..5
    groups = r.i16()
    if groups < 0:
        raise RhdProblem("rhd_bad_header", "%d signal groups" % groups)
    for _g in range(groups):
        r.qstring()                            # group name
        r.qstring()                            # group prefix
        enabled = r.i16()
        nchan = r.i16()
        r.i16()                                # num amp channels
        if nchan < 0:
            raise RhdProblem("rhd_bad_header", "a signal group of %d channels" % nchan)
        if nchan > 0 and enabled > 0:
            for _c in range(nchan):
                r.qstring()                    # native name
                r.qstring()                    # custom name
                r.i16()                        # native order
                r.i16()                        # custom order
                signal_type = r.i16()
                channel_enabled = r.i16()
                for _k in range(6):            # chip channel, board stream, trigger fields
                    r.i16()
                r.f32()                        # impedance magnitude
                r.f32()                        # impedance phase
                if channel_enabled:
                    if not 0 <= signal_type <= 5:
                        raise RhdProblem("rhd_bad_header", "unknown channel type %d" % signal_type)
                    counts[signal_type] += 1
    n_amp, n_aux, n_supply, n_adc, n_din, n_dout = counts
    if num_temp < 0:
        raise RhdProblem("rhd_bad_header", "%d temperature sensor channels" % num_temp)

    # Bytes per data block, term by term as in parseIntanHeader.m.
    bpb = spb * 4
    bpb += spb * 2 * n_amp
    bpb += (spb // 4) * 2 * n_aux
    bpb += 1 * 2 * n_supply
    bpb += spb * 2 * n_adc
    if n_din > 0:
        bpb += spb * 2
    if n_dout > 0:
        bpb += spb * 2
    if num_temp > 0:
        bpb += 1 * 2 * num_temp

    header_bytes = r.pos
    remaining = size - header_bytes
    blocks, rest = divmod(remaining, bpb)
    if rest:
        raise RhdProblem("rhd_partial_block",
                         "%d bytes after the %d-byte header are %d whole data blocks of %d bytes "
                         "and %d bytes more" % (remaining, header_bytes, blocks, bpb, rest))
    return RhdHeader(main, secondary, Fraction(rate), n_amp, n_aux, n_supply, n_adc, n_din,
                     n_dout, num_temp, spb, bpb, header_bytes, size, blocks)


@dataclass(frozen=True)
class RecordingSummary:
    sample_rate: Fraction
    n_channels: int
    total_samples: int
    duration: Fraction           # seconds, exact
    n_files: int
    files_without_data: tuple[str, ...]


def recording_summary(headers: list[tuple[str, RhdHeader]]) -> RecordingSummary:
    """Combine the headers (name, header) of one recording's .rhd files.

    The first file in name order sets the rate and channel count; any file
    that differs is ``rhd_header_mismatch``. No amplifier channel is
    ``rhd_no_amplifier_channels``.
    """
    if not headers:
        raise ValueError("no .rhd header")
    headers = sorted(headers)
    first_name, first = headers[0]
    for name, h in headers[1:]:
        if h.num_amplifier_channels != first.num_amplifier_channels:
            raise RhdProblem("rhd_header_mismatch",
                             "%s has %d amplifier channels, %s has %d"
                             % (name, h.num_amplifier_channels, first_name,
                                first.num_amplifier_channels))
        if h.sample_rate != first.sample_rate:
            raise RhdProblem("rhd_header_mismatch",
                             "%s is sampled at %s Hz, %s at %s Hz"
                             % (name, decimal_text(h.sample_rate), first_name,
                                decimal_text(first.sample_rate)))
    if first.num_amplifier_channels <= 0:
        raise RhdProblem("rhd_no_amplifier_channels", "no enabled amplifier channel")
    total = sum(h.num_samples for _, h in headers)
    return RecordingSummary(first.sample_rate, first.num_amplifier_channels, total,
                            Fraction(total) / first.sample_rate, len(headers),
                            tuple(n for n, h in headers if h.num_data_blocks == 0))


def decimal_text(value: Fraction) -> str | None:
    """VALUE as exact decimal text ("25000", "60.5"); None when it has no finite decimal."""
    value = Fraction(value)
    den = value.denominator
    twos = fives = 0
    while den % 2 == 0:
        den //= 2
        twos += 1
    while den % 5 == 0:
        den //= 5
        fives += 1
    if den != 1:
        return None
    places = max(twos, fives)
    scaled = value * 10 ** places
    assert scaled.denominator == 1
    n = scaled.numerator
    sign = "-" if n < 0 else ""
    digits = str(abs(n))
    if places == 0:
        return sign + digits
    digits = digits.rjust(places + 1, "0")
    whole, frac = digits[:-places], digits[-places:]
    return sign + whole + "." + frac


_INT_FIELDS = ("main_version", "secondary_version", "num_amplifier_channels",
               "num_aux_input_channels", "num_supply_voltage_channels", "num_board_adc_channels",
               "num_board_dig_in_channels", "num_board_dig_out_channels",
               "num_temp_sensor_channels", "samples_per_block", "bytes_per_block", "header_bytes",
               "file_size", "num_data_blocks")


def to_entry(h: RhdHeader) -> dict:
    """A JSON-ready cache entry of H; the sample rate as exact "num/den" text."""
    header = {f: getattr(h, f) for f in _INT_FIELDS}
    header["sample_rate"] = "%d/%d" % (h.sample_rate.numerator, h.sample_rate.denominator)
    return {"reader": READER, "header": header}


def from_entry(entry: dict) -> RhdHeader:
    """The header of a cache entry; ValueError if it is not well formed."""
    header = entry["header"]
    if not isinstance(header, dict) or set(header) != set(_INT_FIELDS) | {"sample_rate"}:
        raise ValueError("a malformed header entry")
    values = {}
    for f in _INT_FIELDS:
        if type(header[f]) is not int:
            raise ValueError("%s is not a whole number" % f)
        values[f] = header[f]
    text = header["sample_rate"]
    if not isinstance(text, str):
        raise ValueError("sample_rate is not text")
    rate = Fraction(text)
    if rate <= 0:
        raise ValueError("sample_rate is not positive")
    return RhdHeader(sample_rate=rate, **values)
