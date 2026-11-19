#!/usr/bin/env python3
"""Database-free check of tools/nas_import (the NAS importer's parsing half).

    python tests/check_nas_import_parsing.py

Builds fixture trees in a temporary folder and checks the walker, the name
grammar, the MAT 5.0 reader (against files written by scipy, committed under
tests/testdata/nas_import with their generator), the Intan .rhd header reader
(against SYNTHETIC headers built here from the format as parseIntanHeader.m
reads it, in the structure of ephys_analysis' writeRhdHeader.m), the MPEG-TS
check, subjects and overrides, the pairing rule and its boundaries, ids,
digest and signature, and every anomaly of the RIG3 profile. Needs only the
standard library. Exits non-zero with a message on the first failure.
"""
import dataclasses
import json
import os
import shutil
import struct
import sys
import tempfile
import uuid
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))

from nas_import import cache, content, ids, mat5, names, pairing, rhd, subjects, walk  # noqa: E402
from nas_import.interpret import interpret  # noqa: E402
from nas_import.model import REASON_CODES, DirectorySpec, Group  # noqa: E402

TESTDATA = os.path.join(HERE, "testdata", "nas_import")
ROOT = "nas-test"


def fail(msg):
    sys.exit("check_nas_import_parsing: " + msg)


def check(cond, msg):
    if not cond:
        fail(msg)


def expect_problem(fn, code, what):
    try:
        fn()
    except content.ContentProblem as exc:
        check(exc.code == code, "%s: expected %s, got %s (%s)" % (what, code, exc.code, exc.sentence))
        return exc
    fail("%s: expected %s, got no problem" % (what, code))


def write(path, data=b""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


# --------------------------------------------------------------------------- RHD
def qstring(s):
    b = s.encode("utf-16-le")
    return struct.pack("<I", len(b)) + b


def channel(native, custom, order, signal_type, enabled=True):
    # writeRhdChannel.m: names, native/custom order, type, enabled, 6 int16, 2 single
    return (qstring(native) + qstring(custom) + struct.pack("<hhhh", order, 0, signal_type,
                                                              int(enabled))
            + struct.pack("<6h", 0, 0, 0, 0, 0, 0) + struct.pack("<ff", 0.0, 0.0))


def rhd_header(fs=128.0, n_amp=4, version=(3, 5), n_aux=0, n_dig=1, n_dout=0, n_temp=0,
               n_supply=0, n_adc=0, disabled=0, magic=0xC6912702):
    """An RHD2000 header laid out as writeRhdHeader.m writes it (one signal group)."""
    main, sec = version
    b = struct.pack("<Ihh", magic, main, sec)
    b += struct.pack("<f", fs)
    b += struct.pack("<h", 1) + struct.pack("<3f", 1, 1, 7500) + struct.pack("<3f", 1, 1, 7500)
    b += struct.pack("<h", 0) + struct.pack("<2f", 1000, 1000)
    b += qstring("") + qstring("note two") + qstring("")
    if (main == 1 and sec >= 1) or main > 1:
        b += struct.pack("<h", n_temp)
    if (main == 1 and sec >= 3) or main > 1:
        b += struct.pack("<h", 0)
    if main > 1:
        b += qstring("")
    recs = []
    for k in range(n_amp):
        recs.append(channel("A-%03d" % k, "amp%d" % k, k, 0))
    for k in range(disabled):
        recs.append(channel("A-9%02d" % k, "off%d" % k, 900 + k, 0, enabled=False))
    for k in range(n_aux):
        recs.append(channel("A-AUX%d" % k, "aux%d" % k, k, 1))
    for k in range(n_supply):
        recs.append(channel("A-VDD%d" % k, "vdd%d" % k, k, 2))
    for k in range(n_adc):
        recs.append(channel("ANALOG-IN-%d" % k, "adc%d" % k, k, 3))
    for k in range(n_dig):
        recs.append(channel("DIGITAL-IN-%02d" % k, "din%d" % k, k, 4))
    for k in range(n_dout):
        recs.append(channel("DIGITAL-OUT-%02d" % k, "dout%d" % k, k, 5))
    b += struct.pack("<h", 1) + qstring("Port A") + qstring("A")
    b += struct.pack("<hhh", 1, len(recs), n_amp)
    return b + b"".join(recs)


def block_bytes(spb, n_amp, n_aux=0, n_supply=0, n_adc=0, n_dig=1, n_dout=0, n_temp=0):
    # The data block as blockLayout.m describes it, in bytes.
    words = (2 * spb + spb * n_amp + spb // 4 * n_aux + n_supply + n_temp + spb * n_adc
             + spb * (n_dig > 0) + spb * (n_dout > 0))
    return 2 * words


def rhd_file(blocks, extra=0, **kw):
    spb = 60 if kw.get("version", (3, 5))[0] == 1 else 128
    keys = ("n_amp", "n_aux", "n_supply", "n_adc", "n_dig", "n_dout", "n_temp")
    defaults = {"n_amp": 4, "n_dig": 1}
    bk = {k: kw.get(k, defaults.get(k, 0)) for k in keys}
    return rhd_header(**kw) + b"\0" * (blocks * block_bytes(spb, **bk) + extra)


def parse_rhd_bytes(data):
    import io
    return rhd.read_header(io.BytesIO(data), len(data))


def check_rhd():
    # A realistic header: 25 kHz, version 3.5, 64 amplifier channels (+1 disabled),
    # 3 aux, 2 digital in, 1 digital out, 1 temperature sensor, 2 supply, 1 ADC.
    kw = dict(fs=25000.0, n_amp=64, version=(3, 5), n_aux=3, n_dig=2, n_dout=1, n_temp=1,
              n_supply=2, n_adc=1, disabled=1)
    hdr_only = rhd_header(**kw)
    bpb = (128 * 4 + 128 * 2 * 64 + 32 * 2 * 3 + 2 * 2 + 128 * 2 * 1 + 128 * 2 + 128 * 2 + 2 * 1)
    check(block_bytes(128, 64, 3, 2, 1, 2, 1, 1) == bpb, "test arithmetic of a block")
    h = parse_rhd_bytes(hdr_only + b"\0" * (bpb * 3))
    check(h.sample_rate == 25000 and rhd.decimal_text(h.sample_rate) == "25000", "sample rate")
    check(h.num_amplifier_channels == 64, "amplifier channels: %d" % h.num_amplifier_channels)
    check(h.num_aux_input_channels == 3 and h.num_board_dig_in_channels == 2, "aux / dig-in")
    check(h.num_board_dig_out_channels == 1 and h.num_temp_sensor_channels == 1, "dout / temp")
    check(h.header_bytes == len(hdr_only), "header bytes %d != %d" % (h.header_bytes, len(hdr_only)))
    check(h.bytes_per_block == bpb, "bytes per block %d != %d" % (h.bytes_per_block, bpb))
    check(h.samples_per_block == 128 and h.num_data_blocks == 3 and h.num_samples == 384, "blocks")
    # Version 1.0: 60 samples per block, no temperature / board mode / reference fields.
    h1 = parse_rhd_bytes(rhd_file(2, fs=20000.0, n_amp=2, version=(1, 0)))
    check(h1.samples_per_block == 60 and h1.num_samples == 120, "version 1.0 block size")
    check(h1.bytes_per_block == block_bytes(60, 2), "version 1.0 bytes per block")
    # A float32 rate that is not whole: exact decimal text.
    check(rhd.decimal_text(parse_rhd_bytes(rhd_header(fs=1000.5)).sample_rate) == "1000.5",
          "a fractional sample rate")
    expect_problem(lambda: parse_rhd_bytes(rhd_file(2, extra=7)), "rhd_partial_block",
                   "a partial block")
    expect_problem(lambda: parse_rhd_bytes(rhd_file(1, magic=0x12345678)), "rhd_bad_magic",
                   "bad magic")
    expect_problem(lambda: parse_rhd_bytes(rhd_header()[:40]), "rhd_truncated", "truncated header")
    expect_problem(lambda: parse_rhd_bytes(b""), "rhd_truncated", "zero bytes")
    expect_problem(lambda: parse_rhd_bytes(rhd_header(fs=0.0)), "rhd_bad_header", "zero rate")
    # Header only: a file with no data block is accepted (0 samples).
    check(parse_rhd_bytes(rhd_header()).num_data_blocks == 0, "a header-only file")
    # Summary: duration is the exact sum; disagreement holds.
    a = parse_rhd_bytes(rhd_file(3))
    b = parse_rhd_bytes(rhd_file(2))
    s = rhd.recording_summary([("b.rhd", b), ("a.rhd", a)])
    check(s.total_samples == 640 and s.duration == Fraction(5), "summary duration %s" % s.duration)
    c = parse_rhd_bytes(rhd_file(1, n_amp=8))
    expect_problem(lambda: rhd.recording_summary([("a.rhd", a), ("c.rhd", c)]),
                   "rhd_header_mismatch", "channel count mismatch")
    d = parse_rhd_bytes(rhd_file(1, fs=256.0))
    expect_problem(lambda: rhd.recording_summary([("a.rhd", a), ("d.rhd", d)]),
                   "rhd_header_mismatch", "sample rate mismatch")
    e = parse_rhd_bytes(rhd_file(1, n_amp=0))
    expect_problem(lambda: rhd.recording_summary([("e.rhd", e)]), "rhd_no_amplifier_channels",
                   "no amplifier channel")
    # Exact decimals.
    for value, text in ((Fraction(150), "150"), (Fraction(121, 2), "60.5"),
                        (Fraction(384, 25000), "0.01536"), (Fraction(1, 3), None),
                        (Fraction(-5, 4), "-1.25"), (Fraction(0), "0")):
        check(rhd.decimal_text(value) == text, "decimal_text(%s) = %r" % (value, rhd.decimal_text(value)))


# --------------------------------------------------------------------------- MAT
def mat_from(path):
    with open(path, "rb") as fh:
        return mat5.read_variables(fh, os.path.getsize(path))


def mat_bytes(data):
    import io
    return mat5.read_variables(io.BytesIO(data), len(data))


def check_mat():
    with open(os.path.join(TESTDATA, "expected.json"), encoding="utf-8") as fh:
        expected = json.load(fh)["files"]
    check(len(expected) >= 10, "expected.json lists the fixtures")
    for name, want in sorted(expected.items()):
        path = os.path.join(TESTDATA, name)
        if isinstance(want, str):
            expect_problem(lambda: mat_from(path), want, name)
            continue
        got = [[v.name, v.mclass, list(v.dims)] for v in mat_from(path)]
        check(got == want, "%s: read %s, scipy wrote %s" % (name, got, want))
    for name, n in (("epsych_n0_z.mat", 0), ("epsych_n1_z.mat", 1), ("epsych_n5_z.mat", 5),
                    ("epsych_n0_u.mat", 0), ("epsych_n3_u.mat", 3), ("epsych_2x3_z.mat", 6),
                    ("epsych_other_first_z.mat", 4), ("epsych_other_first_u.mat", 2)):
        got = mat5.epsych_trials(mat_from(os.path.join(TESTDATA, name)))
        check(got == n, "%s: %d trials, expected %d" % (name, got, n))
    check(all(v.compressed for v in mat_from(os.path.join(TESTDATA, "epsych_n5_z.mat"))),
          "compressed fixture read as compressed")
    check(not any(v.compressed for v in mat_from(os.path.join(TESTDATA, "epsych_n3_u.mat"))),
          "uncompressed fixture read as uncompressed")
    expect_problem(lambda: mat5.epsych_trials(mat_from(os.path.join(TESTDATA, "no_info_z.mat"))),
                   "mat_not_epsych", "a file lacking Info")
    expect_problem(lambda: mat5.epsych_trials(mat_from(os.path.join(TESTDATA, "no_variables_u.mat"))),
                   "mat_not_epsych", "a file without variables")

    with open(os.path.join(TESTDATA, "epsych_n5_z.mat"), "rb") as fh:
        good = fh.read()
    with open(os.path.join(TESTDATA, "epsych_n3_u.mat"), "rb") as fh:
        good_u = fh.read()
    expect_problem(lambda: mat_bytes(good[:300]), "mat_truncated", "a cut compressed file")
    expect_problem(lambda: mat_bytes(good_u[:600]), "mat_truncated", "a cut uncompressed file")
    expect_problem(lambda: mat_bytes(good + b"\0\0\0"), "mat_truncated", "stray trailing bytes")
    expect_problem(lambda: mat_bytes(good[:100]), "mat_truncated", "shorter than the header")
    expect_problem(lambda: mat_bytes(b"MATL"), "mat_truncated", "four bytes of a header")
    expect_problem(lambda: mat_bytes(b""), "mat_not_mat5", "zero bytes")
    expect_problem(lambda: mat_bytes(b"x" * 400), "mat_not_mat5", "not a MAT file")
    v73 = (b"MATLAB 7.3 MAT-file, Platform: GLNXA64, Created on: Mon Mar  2 10:00:00 2026 HDF5 schema 1.00 ."
           .ljust(116, b" ") + b"\0" * 8 + b"\x00\x02IM") + b"\0" * 512
    expect_problem(lambda: mat_bytes(v73), "mat_v73", "a v7.3 header")
    big = good[:124] + b"\x01\x00MI" + good[128:]
    expect_problem(lambda: mat_bytes(big), "mat_big_endian", "a big-endian header")
    # Damage the first compressed variable's zlib stream right after its tag.
    bad = bytearray(good)
    for k in range(136, 150):
        bad[k] ^= 0x5A
    expect_problem(lambda: mat_bytes(bytes(bad)), "mat_corrupt", "a damaged zlib stream")
    # A tiny but valid session (the ~400-byte files of the profile): 0 trials.
    check(len(good) < 1024 and os.path.getsize(os.path.join(TESTDATA, "epsych_n0_z.mat")) <= 400,
          "the n0 fixture is a tiny session")


# --------------------------------------------------------------------------- names
def check_names():
    p = names.parse_epsych("SUBJ-ID-1255_260307T101500.mat")
    check(p and p.start_local == "2026-03-07 10:15:00" and p.precision == "second"
          and p.suffix is None and p.base_stem == "SUBJ-ID-1255_260307T101500", "second form")
    p = names.parse_epsych("SUBJ-ID-1255_260307T101500_psych.mat")
    check(p and p.suffix == "psych" and p.base_stem == "SUBJ-ID-1255_260307T101500", "suffix")
    p = names.parse_epsych("SUBJ-ID-1255_07-Mar-2026_A.mat")
    check(p and p.date == "2026-03-07" and p.start_local is None and p.precision == "day"
          and p.base_stem == "SUBJ-ID-1255_07-Mar-2026_A", "dd-Mon-yyyy form")
    p = names.parse_epsych("SUBJ-ID-1255_07-Mar-2026.mat")
    check(p and p.base_stem == "SUBJ-ID-1255_07-Mar-2026", "dd-Mon-yyyy without A/B")
    p = names.parse_epsych("SUBJ-ID-1255_260306.mat")
    check(p and p.date == "2026-03-06" and p.precision == "day" and p.form == "ymd", "yyMMdd form")
    for bad in ("test.mat", "test3.mat", "SUBJ-ID-TEST.mat", "SUBJ-ID-TEST-2.mat",
                "SUBJ-ID-1255_7-Mar-2026.mat", "SUBJ-ID-1255_07-Mar-2026_C.mat",
                "SUBJ-ID-1255_07-Mar-2026_psych.mat", "SUBJ-ID-1255_260307T101500_a_b.mat",
                "SUBJ_ID_260307T101500.mat", "SUBJ-ID-1255_260307T101500.MAT",
                "SUBJ-ID-1255_260307t101500.mat", "SUBJ-ID-1255_2603071T01500.mat",
                "SUBJ-ID-1255_٣٢٠٣٠٧T101500.mat"):
        check(names.parse_epsych(bad) is None, "%s should not parse" % bad)
    for bad in ("SUBJ-ID-1255_260230T101500.mat", "SUBJ-ID-1255_260307T240000.mat",
                "SUBJ-ID-1255_260307T106000.mat", "SUBJ-ID-1255_261307T101500.mat",
                "SUBJ-ID-1255_260007T101500.mat", "SUBJ-ID-1255_31-Apr-2026.mat",
                "SUBJ-ID-1255_07-Foo-2026.mat", "SUBJ-ID-1255_260229.mat"):
        try:
            names.parse_epsych(bad)
        except names.BadNameTime:
            continue
        fail("%s should be an invalid date or time" % bad)
    check(names.parse_epsych("SUBJ-ID-1255_240229T000000.mat").date == "2024-02-29", "leap day")
    i = names.parse_intan_folder("SUBJ-ID-1255_260307_101800")
    check(i and i.subject == "SUBJ-ID-1255" and i.start_local == "2026-03-07 10:18:00", "intan")
    i = names.parse_intan_folder("SUBj-ID-1278_261015_094835")
    check(i and i.subject == "SUBj-ID-1278", "intan, subject spelled as written")
    for bad in ("New folder", "SUBJ-ID-1255_260307_101800_extra", "SUBJ-ID-1255_260307-101800",
                "SUBJ ID_260307_101800", "A_B_260307_101800", "SUBJ-ID-1154_impedance_03182026"):
        check(names.parse_intan_folder(bad) is None, "%s should not parse" % bad)
    try:
        names.parse_intan_folder("SUBJ-ID-1255_260307_101860")
        fail("second 60 accepted")
    except names.BadNameTime:
        pass
    check(names.wall_seconds("2026-03-07 10:18:00") - names.wall_seconds("2026-03-07 10:15:00")
          == 180, "wall seconds")
    check(names.wall_seconds("2026-03-08 00:00:10") - names.wall_seconds("2026-03-07 23:59:50")
          == 20, "wall seconds across midnight")


# --------------------------------------------------------------------------- pairing
def check_pairing_rule():
    R, S = pairing.Recording, pairing.Session

    def one(dt, duration=Fraction(600)):
        return pairing.pair_subject([R("r", 10_000, duration)], [S("e", 10_000 + dt)])
    check(one(-600).pair_of == {"r": "e"}, "dt = -10 min is inside (inclusive)")
    check(one(-601).pair_of == {}, "dt = -10 min - 1 s is outside")
    check(one(120).pair_of == {"r": "e"}, "dt = +2 min is inside (inclusive)")
    check(one(121).pair_of == {}, "dt = +2 min + 1 s is outside")
    check(one(-60, Fraction(120)).pair_of == {"r": "e"}, "a recording of exactly 2 min pairs")
    res = one(-60, Fraction(11999, 100))
    check(res.pair_of == {} and "r" in res.short, "a recording under 2 min is short")
    check(one(-60, None).pair_of == {"r": "e"}, "an unknown duration pairs as usual")
    # A rival exactly 30 s further is not ambiguous; 29 s further is.
    res = pairing.pair_subject([R("r", 0, None)], [S("e1", -60), S("e2", -90)])
    check(res.pair_of == {"r": "e1"} and not res.ambiguous_sessions, "a rival 30 s further")
    res = pairing.pair_subject([R("r", 0, None)], [S("e1", -60), S("e2", -89)])
    check(res.pair_of == {} and res.ambiguous_sessions == {"e1", "e2"}
          and res.ambiguous_recordings == {"r"}, "a rival 29 s further is ambiguous")
    # Global one-to-one: two recordings, two sessions, no conflict.
    res = pairing.pair_subject([R("r1", 0, None), R("r2", 3600, None)],
                               [S("e1", -120), S("e2", 3600 - 200)])
    check(res.pair_of == {"r1": "e1", "r2": "e2"}, "two independent pairs")
    # A short recording claims nothing and makes nothing ambiguous.
    res = pairing.pair_subject([R("long", 0, None), R("short", 20, Fraction(60))],
                               [S("e", -100)])
    check(res.pair_of == {"long": "e"} and not res.ambiguous_sessions, "short takes no part")
    # Once a recording is taken, its other candidate is no rival.
    res = pairing.pair_subject([R("r1", 0, None), R("r2", 400, None)],
                               [S("e1", -10), S("e2", 250)])
    check(res.pair_of == {"r1": "e1", "r2": "e2"}, "greedy assignment after a take: %s" % res.pair_of)


# --------------------------------------------------------------------------- fixture tree
TS_GOOD = b"".join(bytes([0x47]) + bytes(187) for _ in range(10))
TS_BAD = TS_GOOD[:188] + b"\x00" + TS_GOOD[189:]
KNOWN = {"SUBJ-ID-1225", "SUBJ-ID-1255", "SUBJ-ID-1278", "SUBJ-ID-1154", "SUBJ-ID-2000"}
E = "epsych_files/Data"
I = "intan_files/Data"  # noqa: E741


def fixture(name):
    with open(os.path.join(TESTDATA, name), "rb") as fh:
        return fh.read()


def build_tree(root):
    n5, n0, n1, n3 = (fixture("epsych_n5_z.mat"), fixture("epsych_n0_z.mat"),
                      fixture("epsych_n1_z.mat"), fixture("epsych_n3_u.mat"))
    e = os.path.join(root, *E.split("/"))
    i = os.path.join(root, *I.split("/"))

    def ep(rel, data=b""):
        write(os.path.join(e, *rel.split("/")), data)

    def rec(rel, data=b""):
        write(os.path.join(i, *rel.split("/")), data)
    s = "SUBJ-ID-1255/"
    ep(s + "SUBJ-ID-1255_260307T101500.mat", n5)
    ep(s + "SUBJ-ID-1255_260307T101500_psych.mat", n5)           # twin: same bytes
    ep(s + "SUBJ-ID-1255_260307T101500.ts", TS_GOOD)
    ep(s + "SUBJ-ID-1255_260307T101500-2.ts", TS_GOOD)
    ep(s + "SUBJ-ID-1255_260307T101500_conv.mp4", b"not checked")
    ep(s + "SUBJ-ID-1255_260308T090000.mat", n0)                 # tiny session, 0 trials
    ep(s + "SUBJ-ID-1255_260309T090000.ts", TS_GOOD)             # orphan video
    ep(s + "SUBJ-ID-1255_260310T090000.mat", n1)
    ep(s + "SUBJ-ID-1255_260310T090000.ts")                      # zero-byte video
    ep(s + "SUBJ-ID-1255_260310T090000-2.ts", TS_BAD)            # no sync byte
    ep(s + "SUBJ-ID-1255_260310T090000-2_conv.mp4", b"x")        # its source is held
    ep(s + "SUBJ-ID-1255_260311T090000.mat")                     # zero-byte session file
    ep(s + "SUBJ-ID-1255_260312T090000.mat", fixture("no_info_z.mat"))
    ep(s + "SUBJ-ID-1255_260313T250000.mat", n1)                 # invalid time
    ep(s + "SUBJ-ID-1255_260314T090000.mat", fixture("v4.mat"))  # not MAT 5.0
    ep(s + "SUBJ-ID-1255_260315T090000_conv.mp4", b"x")          # no .ts, but a .mat
    ep(s + "SUBJ-ID-1255_260315T090000.mat", n1)
    ep(s + "SUBJ-ID-1255_07-Mar-2026_A.mat", n3)
    ep(s + "SUBJ-ID-1255_07-Mar-2026_B.mat", n1)
    ep(s + "SUBJ-ID-1255_260306.mat", n1)
    for stray in ("test.mat", "test3.mat", "SUBJ-ID-TEST.mat", "SUBJ-ID-TEST-2.mat", "notes.txt"):
        ep(s + stray, n1)
    ep(s + ".DS_Store", b"x")
    ep(s + "~$lock.docx", b"x")
    ep("loose_in_data.mat", n1)                                  # directly in Data
    ep("SUBJ-ID-1255/deeper/SUBJ-ID-1255_260320T090000.mat", n1)  # epsych is flat
    ep("TEST/TEST_260101T101010.mat", n1)
    ep("TEST_SUBJECT/whatever.mat", b"")
    ep("SUBJ-ID-TEST/SUBJ-ID-TEST_260101T101010.mat", n1)
    ep("videos/SUBJ-ID-1255_260101T101010.ts", TS_GOOD)
    ep("SUBJ-ID-1225/SUBJ-ID-1225_260709T094900.mat", n5)        # pairs with the mislabelled folder
    ep("SUBJ-ID-1278/SUBJ-ID-1278_261015T094500.mat", n5)        # pairs with the case variant
    ep("SUBJ-ID-2000/SUBJ-ID-2000_260401T100000.mat", n5)
    ep("SUBJ-ID-2000/SUBJ-ID-2000_260401T100000_delay.mat", n1)  # twin, other trial count
    ep("SUBJ-ID-2000/SUBJ-ID-2000_260402T095800.mat", n5)        # ambiguous pair
    ep("SUBJ-ID-2000/SUBJ-ID-2000_260402T095810.mat", n5)
    ep("SUBJ-ID-2000/SUBJ-ID-2000_260403T095900.mat", n5)        # only a short recording near
    ep("SUBJ-ID-2000/subj-id-2000_260408T100000.mat", n5)        # same stamp, subject case differs
    ep("SUBJ-ID-2000/SUBJ-ID-2000_260408T100000.mat", n5)

    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/SUBJ-ID-1255_260307_101800.rhd", rhd_file(60))
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/SUBJ-ID-1255_260307_101900.rhd", rhd_file(60))
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/SUBJ-ID-1255_260307_102000.rhd", rhd_file(30))
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/settings.xml", b"<xml/>")
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/_manifest.json", b"{}")
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/empty.txt")
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/sub/notes.txt", b"nested")
    rec("SUBJ-ID-1225/SUBJ-ID-1255_260709_095155/SUBJ-ID-1255_260709_095155.rhd", rhd_file(150))
    rec("SUBJ-ID-1225/SUBJ-ID-1255_260709_095155/settings.xml", b"<xml subject='stale'/>")
    rec("SUBJ-ID-1278/SUBj-ID-1278_261015_094835/a.rhd", rhd_file(150))
    rec("SUBJ-ID-1154/SUBJ-ID-1154_impedance_03182026.csv", b"ch,z\n")
    os.makedirs(os.path.join(i, "New folder"))
    rec("TEST_260619_144257/TEST_260619_144257.rhd", rhd_file(5))
    rec(".DS_Store", b"x")
    rec("@eaDir/thumb/a.jpg", b"x")
    rec("@eaDir/b.jpg", b"x")
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260402_100000/a.rhd", rhd_file(150))
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260403_100000/a.rhd", rhd_file(60))          # short
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260404_100000/a.rhd", rhd_file(10, extra=5))  # partial block
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260405_100000/a.rhd", rhd_file(10))
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260405_100000/b.rhd", rhd_file(10, n_amp=8))  # mismatch
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260406_100000/a.rhd", rhd_file(10, magic=1))  # bad magic
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260407_100000/settings.xml", b"<xml/>")        # no .rhd
    rec("SUBJ-ID-2000/notarecording/x.txt", b"x")
    rec("SUBJ-ID-2000/SUBJ-ID-2000_261332_100000/a.rhd", rhd_file(1))            # invalid date
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260409_100000/a.rhd", rhd_file(10))
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260409_100000/sub/b.rhd", rhd_file(10))        # nested .rhd
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260410_100000/info.rhd", rhd_header())         # split format
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260410_100000/amplifier.dat", b"\0" * 16)
    rec("loose.txt", b"x")
    os.makedirs(os.path.join(root, "outside"))
    write(os.path.join(root, "outside", "target.mat"), n1)
    try:
        os.symlink(os.path.join(root, "outside", "target.mat"),
                   os.path.join(e, "SUBJ-ID-1255", "SUBJ-ID-1255_260316T090000.mat"))
        return True
    except (OSError, NotImplementedError):
        return False


SPECS = [DirectorySpec(ROOT, E, "epsych", rig="RIG3", time_zone="America/New_York", min_age_min=1440),
         DirectorySpec(ROOT, I, "intan", rig="RIG3", pair_with=E, time_zone="America/New_York",
                       min_age_min=1440)]


def scan(root, overrides=()):
    listings = [walk.walk(root, spec) for spec in SPECS]
    return listings, interpret(listings, {ROOT: root}, KNOWN, overrides)


def by_key(result):
    return {g.key: g for g in result.groups}


def held_codes(result):
    return {h.path: h.reason_code for h in result.held}


def rk(path):
    return "recording:%s:%s/%s" % (ROOT, I, path)


def bk(path):
    return "behavior:%s:%s/%s" % (ROOT, E, path)


def check_tree(root, symlinked):
    listings, res = scan(root)
    check(res.complete and all(listing.complete for listing in listings), "complete listing")
    G = by_key(res)
    H = held_codes(res)
    RP = {r.path: r.reason_code for r in res.reported}

    # Accounting against an independent count of the tree (os.walk, no links followed).
    on_disk = 0
    for spec in SPECS:
        for _d, _dirs, files in os.walk(os.path.join(root, *spec.path.split("/"))):
            on_disk += len(files)
    in_groups = sum(len(g.files) + len(g.held_files) for g in res.groups)
    ignored = sum(i.file_count for i in res.ignored)
    total = in_groups + len(res.held) + len([r for r in res.reported if not r.is_dir]) + ignored
    check(total == on_disk, "registered + held + reported + ignored = %d, files on disk %d"
          % (total, on_disk))
    check({i.path.rsplit("/", 1)[1] for i in res.ignored} == {".DS_Store", "~$lock.docx", "@eaDir"},
          "ignored entries: %s" % [i.path for i in res.ignored])
    check([i.file_count for i in res.ignored if i.path.endswith("@eaDir")] == [2],
          "files beneath @eaDir counted")

    # The twin session with videos, paired with its recording.
    g = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260307T101500")]
    check(g.status == "ready" and g.subject_id == "SUBJ-ID-1255", "twin session ready")
    check(g.detail == {"trials_completed": 5}, "twin trials %s" % g.detail)
    check(len(g.files) == 5 and not g.held_files, "twin files: %s" % [f.path for f in g.files])
    roles = {f.path.rsplit("/", 1)[1]: (f.role, f.format, f.attributes.get("kind")) for f in g.files}
    check(roles["SUBJ-ID-1255_260307T101500.mat"] == ("raw", "mat", "epsych"), "mat role")
    check(roles["SUBJ-ID-1255_260307T101500_psych.mat"] == ("raw", "mat", "epsych"), "twin role")
    check(roles["SUBJ-ID-1255_260307T101500-2.ts"] == ("video", "ts", "video"), "ts role")
    conv = [f for f in g.files if f.path.endswith("_conv.mp4")][0]
    check(conv.role == "video" and conv.attributes["kind"] == "video_converted"
          and conv.attributes["converted_from"] == "%s/SUBJ-ID-1255/SUBJ-ID-1255_260307T101500.ts" % E,
          "converted video attributes %s" % conv.attributes)
    check(all("source_mtime" in f.attributes for f in g.files), "source_mtime on every file")
    check(g.pairing.status == "paired" and g.pairing.delta_s == -180, "paired %s" % (g.pairing,))
    rec = G[rk("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800")]
    check(g.session_path == rec.session_path and g.label == rec.label, "joins the recording's session")
    check(ids.group_session_id(g) == ids.group_session_id(rec), "same session id")
    check(g.start_local == "2026-03-07 10:15:00" and g.precision == "second", "epsych start")
    check(g.source_value == "SUBJ-ID-1255_260307T101500.mat", "source value %s" % g.source_value)
    check(any(n.code == "epsych_suffix" for n in g.notes), "suffix noted")

    # The recording: every file, recursively, raw/intan; zero-byte file held inside it.
    check(rec.status == "ready" and rec.subject_id == "SUBJ-ID-1255", "recording ready")
    check(rec.detail == {"acquisition_system_code": "intan_rhx", "modality": "ephys",
                         "sample_rate_hz": "128", "n_channels": 4, "duration_s": "150"},
          "recording detail %s" % rec.detail)
    check(rec.duration == Fraction(150) and rec.start_local == "2026-03-07 10:18:00", "duration/start")
    check(len(rec.files) == 6, "recording files %s" % [f.path for f in rec.files])
    check(all(f.role == "raw" and f.attributes["kind"] == "raw" and f.attributes["reader"] == "intan"
              for f in rec.files), "recording artifact attributes")
    fmts = sorted(f.format for f in rec.files)
    check(fmts == ["json", "rhd", "rhd", "rhd", "txt", "xml"], "formats %s" % fmts)
    check([h.reason_code for h in rec.held_files] == ["zero_byte"], "zero-byte file held in group")
    check(rec.pairing.status == "paired", "recording paired")

    # Tiny session: registered with 0 trials, unpaired, own file-path session.
    g = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260308T090000")]
    check(g.status == "ready" and g.detail == {"trials_completed": 0}, "tiny session")
    check(g.session_path == "%s/SUBJ-ID-1255/SUBJ-ID-1255_260308T090000.mat" % E
          and g.label == "SUBJ-ID-1255_260308T090000", "unpaired session path/label")
    check(g.pairing.status == "unpaired", "tiny session unpaired")

    pre = "%s/SUBJ-ID-1255/" % E
    check(H[pre + "SUBJ-ID-1255_260309T090000.ts"] == "video_without_mat", "orphan video held")
    g = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260310T090000")]
    check(g.status == "ready", "session with bad videos still ready")
    hf = {h.path.rsplit("/", 1)[1]: h.reason_code for h in g.held_files}
    check(hf == {"SUBJ-ID-1255_260310T090000.ts": "zero_byte",
                 "SUBJ-ID-1255_260310T090000-2.ts": "video_not_mpeg_ts",
                 "SUBJ-ID-1255_260310T090000-2_conv.mp4": "converted_video_source_held"},
          "held files of the video session %s" % hf)
    g = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260311T090000")]
    check(g.status == "held" and g.hold.reason_code == "no_valid_epsych_file"
          and g.held_files[0].reason_code == "zero_byte", "zero-byte session file")
    g = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260312T090000")]
    check(g.status == "held" and g.held_files[0].reason_code == "mat_not_epsych", "no Info")
    g = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260314T090000")]
    check(g.held_files[0].reason_code == "mat_not_mat5", "v4 file held")
    g = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260315T090000")]
    check(g.status == "ready" and g.held_files[0].reason_code == "converted_video_without_source",
          "a _conv.mp4 without its .ts")
    check(H[pre + "SUBJ-ID-1255_260313T250000.mat"] == "invalid_name_time", "invalid time held")
    for stray in ("test.mat", "test3.mat", "SUBJ-ID-TEST.mat", "SUBJ-ID-TEST-2.mat", "notes.txt"):
        check(H[pre + stray] == "unrecognised_name", "stray %s held" % stray)
    check(H["%s/loose_in_data.mat" % E] == "not_in_subject_folder", "file directly in Data")
    check(H[pre + "deeper/SUBJ-ID-1255_260320T090000.mat"] == "unexpected_depth", "deeper file")
    if symlinked:
        check(H[pre + "SUBJ-ID-1255_260316T090000.mat"] == "symbolic_link", "a symlink is held")

    # Date-only sessions: their own sessions, 12:00, never paired.
    for stem, n in (("SUBJ-ID-1255_07-Mar-2026_A", 3), ("SUBJ-ID-1255_07-Mar-2026_B", 1),
                    ("SUBJ-ID-1255_260306", 1)):
        g = G[bk("SUBJ-ID-1255/" + stem)]
        check(g.status == "ready" and g.precision == "day" and g.start_local is None
              and g.detail == {"trials_completed": n}, "date-only %s" % stem)
        check(g.pairing.status == "date_only" and g.occurred_local.endswith(" 12:00:00"),
              "date-only %s not paired" % stem)
        attrs = ids.event_attributes(g, "abc123")
        check(attrs["occurred_precision"] == "day"
              and attrs["occurred_at_source"] == "ePsych file name (date only)", "date-only attrs")

    # Test folders: reported, not registered, not held.
    for path in ("%s/TEST/TEST_260101T101010.mat" % E, "%s/TEST_SUBJECT/whatever.mat" % E,
                 "%s/SUBJ-ID-TEST/SUBJ-ID-TEST_260101T101010.mat" % E,
                 "%s/videos/SUBJ-ID-1255_260101T101010.ts" % E,
                 "%s/TEST_260619_144257/TEST_260619_144257.rhd" % I):
        owner = [g for g in res.groups if path in g.all_paths()]
        if owner:
            check(owner[0].status == "reported" and owner[0].hold.reason_code == "not_a_subject_folder",
                  "%s in a test folder: %s" % (path, owner[0].status))
        else:
            check(RP.get(path) == "not_a_subject_folder", "%s reported: %s" % (path, RP.get(path)))
    check(RP.get("%s/New folder" % I) == "empty_folder", "New folder reported as empty")

    # Mislabelled folder: held; its ePsych partner held too.
    g = G[rk("SUBJ-ID-1225/SUBJ-ID-1255_260709_095155")]
    check(g.status == "held" and g.hold.reason_code == "subject_mismatch", "mislabelled folder held")
    e = G[bk("SUBJ-ID-1225/SUBJ-ID-1225_260709T094900")]
    check(e.status == "held" and e.hold.reason_code == "paired_recording_held",
          "partner of the mislabelled folder: %s %s" % (e.status, e.hold))
    # Case variant: accepted and noted.
    g = G[rk("SUBJ-ID-1278/SUBj-ID-1278_261015_094835")]
    check(g.status == "ready" and g.subject_id == "SUBJ-ID-1278"
          and any(n.code == "subject_name_case_variant" for n in g.notes), "case variant")
    check(G[bk("SUBJ-ID-1278/SUBJ-ID-1278_261015T094500")].session_path == g.session_path,
          "case-variant recording pairs")
    check(H["%s/SUBJ-ID-1154/SUBJ-ID-1154_impedance_03182026.csv" % I] == "not_in_recording_folder",
          "impedance csv held")
    check(H["%s/loose.txt" % I] == "not_in_subject_folder", "loose file in Data")

    # Trials disagree; ambiguous pairing; short recording; duplicate subject spelling.
    check(G[bk("SUBJ-ID-2000/SUBJ-ID-2000_260401T100000")].hold.reason_code == "epsych_trials_disagree",
          "twin trial counts disagree")
    for stem in ("SUBJ-ID-2000_260402T095800", "SUBJ-ID-2000_260402T095810"):
        g = G[bk("SUBJ-ID-2000/" + stem)]
        check(g.status == "held" and g.hold.reason_code == "pairing_ambiguous", "%s ambiguous" % stem)
    g = G[rk("SUBJ-ID-2000/SUBJ-ID-2000_260402_100000")]
    check(g.status == "ready" and g.pairing.status == "ambiguous", "ambiguous recording stays ready")
    g = G[rk("SUBJ-ID-2000/SUBJ-ID-2000_260403_100000")]
    check(g.status == "ready" and g.pairing.status == "short", "short recording")
    g = G[bk("SUBJ-ID-2000/SUBJ-ID-2000_260403T095900")]
    check(g.status == "ready" and g.pairing.status == "unpaired"
          and "at least 120 s" in g.pairing.note, "near a short recording: %s" % g.pairing.note)
    for stem in ("subj-id-2000_260408T100000", "SUBJ-ID-2000_260408T100000"):
        check(G[bk("SUBJ-ID-2000/" + stem)].hold.reason_code == "epsych_duplicate_session",
              "duplicate spelling %s" % stem)
    for folder, code in (("SUBJ-ID-2000_260404_100000", "rhd_partial_block"),
                         ("SUBJ-ID-2000_260405_100000", "rhd_header_mismatch"),
                         ("SUBJ-ID-2000_260406_100000", "rhd_bad_magic"),
                         ("SUBJ-ID-2000_260409_100000", "rhd_in_subfolder"),
                         ("SUBJ-ID-2000_260410_100000", "intan_split_format")):
        g = G[rk("SUBJ-ID-2000/" + folder)]
        check(g.status == "held" and g.hold.reason_code == code,
              "%s: %s %s" % (folder, g.status, g.hold))
    pre2 = "%s/SUBJ-ID-2000/" % I
    check(H[pre2 + "SUBJ-ID-2000_260407_100000/settings.xml"] == "recording_folder_without_rhd",
          "folder without .rhd")
    check(H[pre2 + "notarecording/x.txt"] == "unrecognised_folder", "unrecognised folder")
    check(H[pre2 + "SUBJ-ID-2000_261332_100000/a.rhd"] == "invalid_name_time", "invalid folder date")

    for h in res.held:
        check(h.reason_code in REASON_CODES and h.sentence, "held item without code/sentence")
    for g in res.groups:
        if g.hold is not None:
            check(g.hold.reason_code in REASON_CODES, "group hold code")
    return listings, res


def check_overrides(root):
    good = ("﻿root,relative_path,subject_id,reason\n"
            "nas-test,intan_files/Data/SUBJ-ID-1225/SUBJ-ID-1255_260709_095155,SUBJ-ID-1225,"
            "\"folder and timing say 1225, name is a typo\"\n"
            "nas-test,epsych_files/Data/SUBJ-ID-1255/SUBJ-ID-1255_260308T090000.mat,skip,a test run\n"
            "nas-test,intan_files/Data/SUBJ-ID-2000/SUBJ-ID-2000_260403_100000,SUBJ-ID-9999,typo\n"
            "nas-test,intan_files/Data/no/such/folder,SUBJ-ID-1255,unused\n")
    ov = subjects.parse_overrides(good)
    check(len(ov) == 4 and ov[1].skip and ov[1].subject_id is None and ov[0].line == 2,
          "parsed overrides %s" % (ov,))
    for bad, why in (("root,path,subject_id,reason\n", "header"),
                     ("root,relative_path,subject_id,reason\nnas-test,a/b,S\n", "3 fields"),
                     ("root,relative_path,subject_id,reason\nnas-test,a/b,S,\n", "empty reason"),
                     ("root,relative_path,subject_id,reason\nnas-test,a/b, S,r\n", "space"),
                     ("root,relative_path,subject_id,reason\nnas-test,../b,S,r\n", "dot-dot"),
                     ("root,relative_path,subject_id,reason\nnas-test,a\\b,S,r\n", "backslash"),
                     ("root,relative_path,subject_id,reason\nnas-test,a/b,S,r\nnas-test,a/b,T,r\n",
                      "duplicate"), ("", "empty file")):
        try:
            subjects.parse_overrides(bad)
        except subjects.OverrideError:
            continue
        fail("a malformed overrides file was accepted (%s)" % why)

    _listings, res = scan(root, ov)
    G = by_key(res)
    g = G[rk("SUBJ-ID-1225/SUBJ-ID-1255_260709_095155")]
    check(g.status == "ready" and g.subject_id == "SUBJ-ID-1225" and g.override is not None,
          "the override names the subject")
    attrs = ids.event_attributes(g, "abc")
    check(attrs["import"]["override"] == {"subject_id": "SUBJ-ID-1225",
                                          "reason": "folder and timing say 1225, name is a typo"},
          "override stored on the event %s" % attrs["import"])
    e = G[bk("SUBJ-ID-1225/SUBJ-ID-1225_260709T094900")]
    check(e.status == "ready" and e.session_path == g.session_path, "partner joins after override")
    s = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260308T090000")]
    check(s.status == "skipped" and s.hold.reason_code == "override_skip", "skip override")
    u = G[rk("SUBJ-ID-2000/SUBJ-ID-2000_260403_100000")]
    check(u.status == "held" and u.hold.reason_code == "override_unknown_subject",
          "override naming an unknown subject")
    check([o.line for o in res.unused_overrides] == [5], "unused override reported")
    two = ("root,relative_path,subject_id,reason\n"
           "nas-test,intan_files/Data/SUBJ-ID-1225/SUBJ-ID-1255_260709_095155,SUBJ-ID-1225,r\n"
           "nas-test,intan_files/Data/SUBJ-ID-1225/SUBJ-ID-1255_260709_095155/settings.xml,"
           "SUBJ-ID-1225,r\n")
    try:
        scan(root, subjects.parse_overrides(two))
        fail("two overrides of one group were accepted")
    except subjects.OverrideError:
        pass


def check_ids_and_stability(root, first):
    _l, again = scan(root)
    check(again == first, "two scans of an unchanged tree differ")
    check([ids.signature(g) for g in again.groups] == [ids.signature(g) for g in first.groups],
          "signatures differ between identical scans")
    G = by_key(first)
    rec = G[rk("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800")]
    path = "%s/SUBJ-ID-1255/SUBJ-ID-1255_260307_101800" % I
    check(ids.NAMESPACE == uuid.UUID("8061b6cb-00dc-44fb-b6a9-c3f8ac5ab649"), "namespace changed")
    check(ids.group_event_id(rec) == str(uuid.uuid5(ids.NAMESPACE, "event:recording:%s:%s"
                                                     % (ROOT, path))), "event id")
    check(ids.group_session_id(rec) == str(uuid.uuid5(ids.NAMESPACE, "session:%s:%s"
                                                       % (ROOT, path))), "session id")
    beh = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260307T101500")]
    check(ids.group_event_id(beh) == str(uuid.uuid5(ids.NAMESPACE, "event:behavior:%s:%s/%s"
          % (ROOT, E, "SUBJ-ID-1255/SUBJ-ID-1255_260307T101500"))), "behavior event id")
    src = ids.digest_source(rec)
    check(set(src) == {"digest_format", "event_type", "event_id", "subject_id", "session_id",
                       "occurred_at_local", "time_zone", "occurred_precision", "detail", "import"},
          "digest source keys %s" % sorted(src))
    check(ids.client_digest(rec) == ids.sha256_text(json.dumps(src, sort_keys=True,
                                                               separators=(",", ":"))),
          "digest is SHA-256 of canonical JSON")
    a1, a2 = ids.event_attributes(rec, "v1"), ids.event_attributes(rec, "v2-dirty")
    check(a1["client_digest"] == a2["client_digest"], "the tool's version changes the digest")
    check(a1["captured_by_tool"] == "import_nas_files" and a1["occurred_at_source"]
          == "recording folder name" and a1["code_version"] == "v1" and
          a1["import"] == {"tool": "import_nas_files", "layout": "intan", "root": ROOT, "path": path,
                           "source_value": "SUBJ-ID-1255_260307_101800"}, "attributes %s" % a1)
    try:
        ids.canonical_json({"x": 1.5})
        fail("a float passed canonical_json")
    except TypeError:
        pass
    check(ids.mtime_text(0) == "1970-01-01T00:00:00.000000000Z", "mtime_text(0)")
    check(ids.mtime_text(1_700_000_000_123_456_789) == "2023-11-14T22:13:20.123456789Z",
          "mtime_text keeps nanoseconds")

    # A file added to an Intan folder: signature changes, key and digest do not.
    folder = os.path.join(root, *path.split("/"))
    write(os.path.join(folder, "added.txt"), b"later")
    _l, res = scan(root)
    rec2 = by_key(res)[rec.key]
    check(rec2.key == rec.key and ids.signature(rec2) != ids.signature(rec),
          "an added file must change the signature but not the key")
    check(ids.client_digest(rec2) == ids.client_digest(rec), "an added non-.rhd file changed the digest")
    # A touched file (same bytes, new mtime) changes the signature.
    xml = os.path.join(folder, "settings.xml")
    st = os.stat(xml)
    os.utime(xml, ns=(st.st_atime_ns, st.st_mtime_ns + 1))
    _l, res = scan(root)
    check(ids.signature(by_key(res)[rec.key]) != ids.signature(rec2), "touch changes the signature")
    # A twin added to an ePsych session keeps its key and event id.
    epath = os.path.join(root, *E.split("/"), "SUBJ-ID-1255")
    shutil.copyfile(os.path.join(epath, "SUBJ-ID-1255_260308T090000.mat"),
                    os.path.join(epath, "SUBJ-ID-1255_260308T090000_rand.mat"))
    _l, res = scan(root)
    tiny_old = G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260308T090000")]
    tiny = by_key(res)[tiny_old.key]
    check(len(tiny.files) == 2 and ids.group_event_id(tiny) == ids.group_event_id(tiny_old)
          and ids.signature(tiny) != ids.signature(tiny_old), "a twin added later")
    # The pairing changes the session, hence the digest.
    lone = dataclasses.replace(beh, session_path="elsewhere.mat")
    check(ids.client_digest(lone) != ids.client_digest(beh), "the session is in the digest")


def check_walker(root):
    spec = SPECS[0]
    # Spelling, missing, unclean paths, outside the root.
    for bad_path, exc in (("epsych_files/data", walk.SpellingMismatch),
                          ("epsych_files/Nope", walk.DirectoryMissing)):
        try:
            walk.walk(root, dataclasses.replace(spec, path=bad_path))
            fail("%s was not refused" % bad_path)
        except exc:
            pass
    for bad_path in ("../x", "/abs", "a//b", "a/", "a\\b", " a"):
        try:
            walk.walk(root, dataclasses.replace(spec, path=bad_path))
            fail("unclean path %r accepted" % bad_path)
        except ValueError:
            pass
    try:
        os.symlink(os.path.join(root, "outside"), os.path.join(root, "linked"))
        try:
            walk.walk(root, dataclasses.replace(spec, path="linked"))
            fail("a directory reached through a link was listed")
        except walk.OutsideRoot:
            pass
    except (OSError, NotImplementedError):
        pass
    # A folder that cannot be listed: the listing says so and is incomplete.
    target = os.path.join(root, *E.split("/"), "SUBJ-ID-2000")
    real = os.scandir

    def failing(path="."):
        if os.path.abspath(str(path)) == os.path.abspath(target):
            raise PermissionError(13, "Permission denied", str(path))
        return real(path)
    os.scandir = failing
    try:
        listing = walk.walk(root, spec)
    finally:
        os.scandir = real
    check(not listing.complete and [u.path for u in listing.unreadable] == ["%s/SUBJ-ID-2000" % E]
          and listing.unreadable[0].is_dir, "an unreadable folder: %s" % (listing.unreadable,))
    check(not any(f.path.startswith("%s/SUBJ-ID-2000/" % E) for f in listing.files),
          "files listed from an unreadable folder")
    res = interpret([listing], {ROOT: root}, KNOWN)
    check(not res.complete and res.unreadable, "interpretation of an incomplete listing")
    # A file that cannot be stat'ed is unreadable too.
    real_lstat = walk._lstat

    def failing_lstat(entry):
        if entry.name == "SUBJ-ID-1255_260306.mat":
            raise PermissionError(13, "Permission denied", entry.path)
        return real_lstat(entry)
    walk._lstat = failing_lstat
    try:
        listing = walk.walk(root, spec)
    finally:
        walk._lstat = real_lstat
    check(not listing.complete and [u.path for u in listing.unreadable]
          == ["%s/SUBJ-ID-1255/SUBJ-ID-1255_260306.mat" % E] and not listing.unreadable[0].is_dir,
          "an unstat-able file: %s" % (listing.unreadable,))
    # mtime_ns is the integer st_mtime_ns.
    listing = walk.walk(root, spec)
    f = listing.files[0]
    st = os.stat(os.path.join(root, *f.path.split("/")))
    check(isinstance(f.mtime_ns, int) and f.mtime_ns == st.st_mtime_ns and f.size == st.st_size,
          "size and mtime_ns as listed")


def check_changed_during_scan(root):
    spec = SPECS[0]
    listing = walk.walk(root, spec)
    target = [f for f in listing.files if f.path.endswith("SUBJ-ID-1255_260306.mat")][0]
    with open(os.path.join(root, *target.path.split("/")), "ab") as fh:
        fh.write(b"\0" * 8)
    res = interpret([listing], {ROOT: root}, KNOWN)
    g = by_key(res)[bk("SUBJ-ID-1255/SUBJ-ID-1255_260306")]
    check(g.status == "held" and g.held_files[0].reason_code == "changed_during_scan",
          "a file that grew after the listing: %s" % (g.held_files,))


def check_ts():
    import io
    check(content.check_mpeg_ts(io.BytesIO(TS_GOOD), len(TS_GOOD)) == 8, "MPEG-TS packets checked")
    expect_problem(lambda: content.check_mpeg_ts(io.BytesIO(TS_BAD), len(TS_BAD)),
                   "video_not_mpeg_ts", "missing sync byte")
    expect_problem(lambda: content.check_mpeg_ts(io.BytesIO(b"\x47" * 100), 100),
                   "video_not_mpeg_ts", "shorter than a packet")


class CountingOpener:
    """Stands in for content.open_listed, counting the files opened."""

    def __init__(self, fail_paths=()):
        self.real = content.open_listed
        self.opened = []
        self.fail_paths = set(fail_paths)

    def __call__(self, root_path, listed):
        self.opened.append(listed.path)
        if listed.path in self.fail_paths:
            raise content.ContentProblem("unreadable_file", "made unreadable by the test")
        return self.real(root_path, listed)

    def __enter__(self):
        content.open_listed = self
        return self

    def __exit__(self, *exc):
        content.open_listed = self.real


def without_headers(res):
    return dataclasses.replace(res, headers={})


def check_cache(tmp):
    root = os.path.join(tmp, "cache_root")
    build_tree(root)
    listings = [walk.walk(root, spec) for spec in SPECS]
    with CountingOpener() as cold_open:
        cold = interpret(listings, {ROOT: root}, KNOWN)
    check(cold_open.opened and len(cold.headers) == len(set(cold_open.opened)),
          "every fresh read gives one header entry")
    for key, entry in cold.headers.items():
        check(isinstance(key, tuple) and len(key) == 4 and entry["reader"] in
              (mat5.READER, rhd.READER, content.TS_READER), "header entry shape %r" % (key,))
        ids.canonical_json(entry)                      # JSON-ready, no float
    problems = {k[1].split("/", 2)[2]: e["problem"][0] for k, e in cold.headers.items()
                if "problem" in e}
    check(problems.get("SUBJ-ID-1255/SUBJ-ID-1255_260314T090000.mat") == "mat_not_mat5"
          and problems.get("SUBJ-ID-1255/SUBJ-ID-1255_260310T090000-2.ts") == "video_not_mpeg_ts"
          and problems.get("SUBJ-ID-2000/SUBJ-ID-2000_260406_100000/a.rhd") == "rhd_bad_magic"
          and problems.get("SUBJ-ID-2000/SUBJ-ID-2000_260404_100000/a.rhd") == "rhd_partial_block",
          "deterministic problems are cached: %s" % problems)

    # (e) save and load round-trip; missing and garbage files load empty.
    path = os.path.join(tmp, "headers.json")
    hc = cache.HeaderCache(cold.headers)
    hc.save(path)
    loaded = cache.HeaderCache.load(path)
    check(dict(loaded) == dict(hc) and len(loaded) == len(cold.headers), "save/load round-trip")
    check([n for n in os.listdir(tmp) if n.startswith(".header-cache-")] == [], "no temp file left")
    check(len(cache.HeaderCache.load(os.path.join(tmp, "missing.json"))) == 0, "missing cache")
    for garbage in (b"not json", b'{"format": "other", "entries": []}', b"[1, 2]",
                    b'{"format": "%s", "entries": [[1, 2]]}' % cache.FORMAT.encode(), b"\xff\xfe"):
        write(os.path.join(tmp, "garbage.json"), garbage)
        check(len(cache.HeaderCache.load(os.path.join(tmp, "garbage.json"))) == 0,
              "a garbage cache file must load empty: %r" % garbage)
    some = list(cold.headers)[:3]
    check(set(hc.restricted_to(some + [(ROOT, "nope", 1, 1)])) == set(some), "restricted_to")

    # (a) + (b) a warm cache (as loaded from JSON) gives the same result and opens nothing.
    with CountingOpener() as warm_open:
        warm = interpret(listings, {ROOT: root}, KNOWN, header_cache=loaded)
    check(warm_open.opened == [], "a warm cache still opened %s" % warm_open.opened[:3])
    check(warm.headers == {}, "a warm pass has no fresh headers")
    check(without_headers(warm) == without_headers(cold), "warm and cold interpretations differ")
    for a, b in zip(warm.groups, cold.groups):
        check(a.key == b.key and ids.signature(a) == ids.signature(b), "key/signature %s" % a.key)
        if a.status == "ready":
            check(ids.client_digest(a) == ids.client_digest(b), "digest %s" % a.key)
    check(warm.held == cold.held, "held items differ with a warm cache")
    # A partial cache (restricted to some keys) reads only the others.
    half = hc.restricted_to(list(cold.headers)[::2])
    with CountingOpener() as half_open:
        part = interpret(listings, {ROOT: root}, KNOWN, header_cache=half)
    check(len(half_open.opened) == len(cold.headers) - len(half)
          and without_headers(part) == without_headers(cold), "a partial cache")

    # (c) a stale reader tag, another size or another mtime_ns is a miss.
    key = [k for k in cold.headers if k[1].endswith("SUBJ-ID-1255_260307T101500.mat")][0]
    stale = dict(hc)
    stale[key] = dict(stale[key], reader="mat5/0")
    for label, changed in (("stale tag", stale),
                           ("size", {**{k: v for k, v in hc.items() if k != key},
                                     (key[0], key[1], key[2] + 1, key[3]): hc[key]}),
                           ("mtime", {**{k: v for k, v in hc.items() if k != key},
                                      (key[0], key[1], key[2], key[3] + 1): hc[key]})):
        with CountingOpener() as o:
            res = interpret(listings, {ROOT: root}, KNOWN, header_cache=changed)
        check(o.opened == [key[1]] and list(res.headers) == [key], "%s must be a miss: %s"
              % (label, o.opened))
        check(without_headers(res) == without_headers(cold), "%s: result differs" % label)
    # A malformed entry with the current tag is read again, not trusted.
    bad = dict(hc)
    bad[key] = {"reader": mat5.READER, "variables": "nonsense"}
    with CountingOpener() as o:
        res = interpret(listings, {ROOT: root}, KNOWN, header_cache=bad)
    check(o.opened == [key[1]] and without_headers(res) == without_headers(cold), "malformed entry")

    # (d) transient outcomes never become entries.
    unreadable = [k[1] for k in cold.headers if k[1].endswith("SUBJ-ID-1255_260308T090000.mat")][0]
    with CountingOpener(fail_paths=[unreadable]):
        res = interpret(listings, {ROOT: root}, KNOWN)
    check(all(k[1] != unreadable for k in res.headers), "unreadable_file was cached")
    g = by_key(res)[bk("SUBJ-ID-1255/SUBJ-ID-1255_260308T090000")]
    check(g.held_files and g.held_files[0].reason_code == "unreadable_file", "unreadable held")
    grown = [f for f in listings[0].files if f.path.endswith("SUBJ-ID-1255_260306.mat")][0]
    with open(os.path.join(root, *grown.path.split("/")), "ab") as fh:
        fh.write(b"\0" * 8)
    res = interpret(listings, {ROOT: root}, KNOWN)
    check(all(k[1] != grown.path for k in res.headers), "changed_during_scan was cached")
    for entry in res.headers.values():
        check("problem" not in entry or entry["problem"][0] not in content.TRANSIENT,
              "a transient problem in headers")
    # A cached transient problem (never written by the tool) is not trusted either.
    poisoned = {cache.file_key(ROOT, grown): {"reader": mat5.READER,
                                              "problem": ["unreadable_file", "x"]}}
    with CountingOpener() as o:
        interpret(listings, {ROOT: root}, KNOWN, header_cache=poisoned)
    check(grown.path in o.opened, "a cached transient problem was trusted")


def main():
    check_rhd()
    check_mat()
    check_names()
    check_pairing_rule()
    check_ts()
    check(isinstance(Group, type), "model import")
    tmp = tempfile.mkdtemp(prefix="nas_import_")
    try:
        root = os.path.join(tmp, "root")
        symlinked = build_tree(root)
        _listings, first = check_tree(root, symlinked)
        check_overrides(root)
        check_walker(root)
        check_ids_and_stability(root, first)
        check_changed_during_scan(root)
        check_cache(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("check_nas_import_parsing: OK")


if __name__ == "__main__":
    main()
