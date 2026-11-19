"""Header of an Intan RHD2000 traditional-format file (``*.rhd``).

A port of ephys_analysis ``pipeline/@IntanReader/parseIntanHeader.m``
(itself a header-only extraction of Intan's ``read_Intan_RHD2000_file``),
checked against the Intan RHX source (commit 3c58677, 3.5.2): the writer
``Engine/Processing/SaveManagers/savemanager.cpp`` / ``savefile.cpp`` and
RHX's own reader ``Engine/Processing/DataFileReaders/datafilereader.cpp``.
The same fields in the same order, the same version conditions, the same
bytes-per-block formula, the same whole-block count from the file size.
Little-endian throughout. What it gives:

* ``sample_rate`` -- one of the rates RHX offers (:data:`RHX_RATES`, from
  ``AbstractRHXController::getSampleRate``), as an exact :class:`Fraction`
  of the LISTED rate: the stored float32 must equal that rate's float32
  exactly (so 3333.33 Hz is kept as 10000/3, which has no decimal text);
* ``num_amplifier_channels`` -- enabled channels of signal type 0;
* ``header_bytes``, ``bytes_per_block``, ``samples_per_block`` (60 for
  main version 1, else 128), ``num_data_blocks`` and ``num_samples``.

Differences from the MATLAB, all towards refusing rather than guessing
(each a :class:`RhdProblem` with a reason code):

* a size that is not a whole number of data blocks is ``rhd_partial_block``
  (parseIntanHeader floors the count and flags ``partialBlock``;
  refreshMetadata only warns);
* a main version other than 1, 2 or 3 is ``rhd_unknown_version``;
* a sample rate that is not exactly one of :data:`RHX_RATES` is
  ``rhd_bad_header``;
* more than 12 signal groups, more than 136 channels or 128 amplifier
  channels in a group (the bounds of RHX's reader, datafilereader.cpp
  lines 498 and 527-538), a negative count, an odd QString byte length or
  one longer than :data:`QSTRING_MAX`, an unknown signal type are
  ``rhd_bad_header``.
* In a main-version-3 file, a signal group's amplifier-channel count (the
  third int16 of the group record; savefile.cpp:380) must equal the number
  of its channel records of type 0, enabled or not (``rhd_bad_header``):
  this catches a channel type changed by damage into another type of the
  same block size, which no other header check sees. Its temperature-sensor
  count must be 0, as RHX writes it (savemanager.cpp:107-111).
* Not detectable from one header: a sample rate damaged into another RHX
  rate (a recording of two or more files is then held
  ``rhd_header_mismatch``), and a swap between board signal types of equal
  block size.
* The channel records of a signal group are read whether or not the group
  is enabled, and an enabled channel counts whatever its group says: the
  RHX writer writes every channel record (savefile.cpp 374-408) and RHX's
  reader counts every enabled channel. (parseIntanHeader.m reads the
  records of enabled groups only.)

Not read: the 32-bit timestamps inside the data blocks (gaps and resets of
the acquisition clock are not detected; the duration is samples / rate).

``recording_summary`` combines the headers of one recording folder as
``IntanReader.refreshMetadata`` does: every file must have the first file's
amplifier channel count and sample rate (``rhd_header_mismatch`` otherwise);
the duration is the sum of each file's samples over the sample rate, kept
exact as a Fraction. At 30 kHz and 15 kHz most block counts give a duration
with no finite decimal; such recordings are held ``rhd_duration_inexact``
(documented; ``duration_s`` is a numeric column and is never rounded).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from fractions import Fraction

from .content import ContentProblem

# Version of what this reader makes of a file's bytes, stored with every
# cached result (cache.py). Raise it whenever the result for the same bytes
# could change: older cache entries are then ignored and the files read again.
READER = "rhd/3"

MAGIC = 0xC6912702
NULL_QSTRING = 0xFFFFFFFF
QSTRING_MAX = 65536             # bytes; longer is rhd_bad_header (no allocation)
MAX_GROUPS = 12                 # datafilereader.cpp:498
MAX_GROUP_CHANNELS = 2 * (64 + 3 + 1)   # datafilereader.cpp:527
MAX_GROUP_AMPLIFIERS = 2 * 64           # datafilereader.cpp:534
VERSIONS = (1, 2, 3)

# AbstractRHXController::getSampleRate (abstractrhxcontroller.cpp 354-409):
# every rate RHX can record at, exactly.
RHX_RATES = tuple(Fraction(r) for r in (
    1000, 1250, 1500, 2000, 2500, 3000, Fraction(10000, 3), 4000, 5000, 6250, 8000, 10000,
    12500, 15000, 20000, 25000, 30000))
_RATE_BY_F32 = {struct.pack("<f", float(r)): r for r in RHX_RATES}


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

    def f32_bytes(self) -> bytes:
        return self.take(4)

    def qstring(self) -> str:
        n = self.u32()
        if n == NULL_QSTRING:
            return ""
        if n % 2:
            raise RhdProblem("rhd_bad_header", "a QString of an odd byte length %d" % n)
        if n > QSTRING_MAX:
            raise RhdProblem("rhd_bad_header", "a QString claiming %d bytes (more than %d)"
                             % (n, QSTRING_MAX))
        data = self.take(n)
        return data.decode("utf-16-le", errors="replace")


def block_bytes(spb: int, n_amp: int, n_aux: int, n_supply: int, n_adc: int, n_din: int,
                n_dout: int, n_temp: int) -> int:
    """Bytes per data block, term by term as in parseIntanHeader.m."""
    bpb = spb * 4
    bpb += spb * 2 * n_amp
    bpb += (spb // 4) * 2 * n_aux
    bpb += 1 * 2 * n_supply
    bpb += spb * 2 * n_adc
    if n_din > 0:
        bpb += spb * 2
    if n_dout > 0:
        bpb += spb * 2
    if n_temp > 0:
        bpb += 1 * 2 * n_temp
    return bpb


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
    if main not in VERSIONS:
        raise RhdProblem("rhd_unknown_version", "file version %d.%d; only main versions 1, 2 "
                         "and 3 are known" % (main, secondary))
    spb = 60 if main == 1 else 128

    raw_rate = r.f32_bytes()
    rate = _RATE_BY_F32.get(raw_rate)
    if rate is None:
        raise RhdProblem("rhd_bad_header", "sample rate %r Hz is not a rate RHX records at"
                         % struct.unpack("<f", raw_rate)[0])
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
    if not 0 <= groups <= MAX_GROUPS:
        raise RhdProblem("rhd_bad_header", "%d signal groups" % groups)
    for _g in range(groups):
        r.qstring()                            # group name
        r.qstring()                            # group prefix
        r.i16()                                # group enabled: not used (see the docstring)
        nchan = r.i16()
        namp = r.i16()
        if not 0 <= nchan <= MAX_GROUP_CHANNELS or not 0 <= namp <= MAX_GROUP_AMPLIFIERS:
            raise RhdProblem("rhd_bad_header", "a signal group of %d channels (%d amplifier)"
                             % (nchan, namp))
        amp_records = 0
        for _c in range(nchan):
            r.qstring()                        # native name
            r.qstring()                        # custom name
            r.i16()                            # native order
            r.i16()                            # custom order
            signal_type = r.i16()
            channel_enabled = r.i16()
            for _k in range(6):                # chip channel, board stream, trigger fields
                r.i16()
            r.f32()                            # impedance magnitude
            r.f32()                            # impedance phase
            if not 0 <= signal_type <= 5:
                raise RhdProblem("rhd_bad_header", "unknown channel type %d" % signal_type)
            if signal_type == 0:
                amp_records += 1
            if channel_enabled:
                counts[signal_type] += 1
        # The RHX writer stores, per group, the number of its amplifier channel
        # records, enabled or not (savefile.cpp:380, numChannels(AmplifierSignal)).
        # Checked for main version 3 (RHX) only: the RHX source does not show how
        # the older RHD2000 software (versions 1 and 2) filled it.
        if main == 3 and namp != amp_records:
            raise RhdProblem("rhd_bad_header", "a signal group says %d amplifier channels but "
                             "holds %d amplifier channel records" % (namp, amp_records))
    n_amp, n_aux, n_supply, n_adc, n_din, n_dout = counts
    if num_temp < 0:
        raise RhdProblem("rhd_bad_header", "%d temperature sensor channels" % num_temp)
    if main == 3 and num_temp != 0:
        # RHX (main version 3) always writes 0 here for an .rhd file (savemanager.cpp:107-111).
        raise RhdProblem("rhd_bad_header", "%d temperature sensor channels in a version-3 file "
                         "(RHX writes 0)" % num_temp)

    bpb = block_bytes(spb, n_amp, n_aux, n_supply, n_adc, n_din, n_dout, num_temp)

    header_bytes = r.pos
    remaining = size - header_bytes
    blocks, rest = divmod(remaining, bpb)
    if rest:
        raise RhdProblem("rhd_partial_block",
                         "%d bytes after the %d-byte header are %d whole data blocks of %d bytes "
                         "and %d bytes more" % (remaining, header_bytes, blocks, bpb, rest))
    return RhdHeader(main, secondary, rate, n_amp, n_aux, n_supply, n_adc, n_din,
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


def from_entry(entry: dict, size: int) -> RhdHeader:
    """The header of a cache entry for a file of SIZE bytes; ValueError unless it is
    exactly what a fresh read of such a file could give (same bounds, same arithmetic).
    """
    if set(entry) != {"reader", "header"}:
        raise ValueError("unexpected keys")
    header = entry["header"]
    if not isinstance(header, dict) or set(header) != set(_INT_FIELDS) | {"sample_rate"}:
        raise ValueError("a malformed header entry")
    v = {}
    for f in _INT_FIELDS:
        if type(header[f]) is not int or header[f] < 0:
            raise ValueError("%s is not a whole number" % f)
        v[f] = header[f]
    text = header["sample_rate"]
    if not isinstance(text, str) or len(text) > 32:
        raise ValueError("sample_rate is not short text")
    num, sep, den = text.partition("/")
    if sep != "/" or not num.isdigit() or not den.isdigit() or not num.isascii() or not den.isascii():
        raise ValueError("sample_rate is not num/den")
    if int(den) == 0:
        raise ValueError("sample_rate has a zero denominator")
    rate = Fraction(int(num), int(den))
    if rate not in RHX_RATES:
        raise ValueError("sample_rate is not an RHX rate")
    if v["main_version"] not in VERSIONS or v["secondary_version"] > 32767:
        raise ValueError("version")
    counts = [v[f] for f in ("num_amplifier_channels", "num_aux_input_channels",
                             "num_supply_voltage_channels", "num_board_adc_channels",
                             "num_board_dig_in_channels", "num_board_dig_out_channels")]
    if any(c > MAX_GROUPS * MAX_GROUP_CHANNELS for c in counts) or v["num_temp_sensor_channels"] > 32767:
        raise ValueError("counts out of range")
    spb = 60 if v["main_version"] == 1 else 128
    if v["samples_per_block"] != spb:
        raise ValueError("samples per block")
    if v["bytes_per_block"] != block_bytes(spb, *counts, v["num_temp_sensor_channels"]):
        raise ValueError("bytes per block")
    if (v["file_size"] != size or v["header_bytes"] < 4
            or v["header_bytes"] + v["num_data_blocks"] * v["bytes_per_block"] != size):
        raise ValueError("sizes")
    return RhdHeader(sample_rate=rate, **v)
