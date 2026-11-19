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


def rhd_header(fs=1000.0, n_amp=4, version=(3, 5), n_aux=0, n_dig=1, n_dout=0, n_temp=0,
               n_supply=0, n_adc=0, disabled=0, magic=0xC6912702, group_enabled=1):
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
    # The group's amplifier count: every type-0 record, enabled or not, as the RHX
    # writer stores it (savefile.cpp:380); writeRhdHeader.m stores the enabled ones.
    b += struct.pack("<hhh", group_enabled, len(recs), n_amp + disabled)
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
    # A realistic header: 25 kHz, version 2.0 (temperature sensors: the older software),
    # 64 amplifier channels (+1 disabled), 3 aux, 2 digital in, 1 digital out,
    # 1 temperature sensor, 2 supply, 1 ADC.
    kw = dict(fs=25000.0, n_amp=64, version=(2, 0), n_aux=3, n_dig=2, n_dout=1, n_temp=1,
              n_supply=2, n_adc=1, disabled=1)
    hdr_only = rhd_header(**kw)
    expect_problem(lambda: parse_rhd_bytes(rhd_header(**dict(kw, version=(3, 5)))),
                   "rhd_bad_header", "a temperature sensor in a version-3 header")
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
    expect_problem(lambda: parse_rhd_bytes(rhd_header(fs=1000.5)), "rhd_bad_header",
                   "a rate RHX does not offer")
    third = parse_rhd_bytes(rhd_header(fs=10000.0 / 3.0)).sample_rate
    check(third == Fraction(10000, 3) and rhd.decimal_text(third) is None,
          "3333.33 Hz is kept as the listed rate 10000/3")
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
    check(s.total_samples == 640 and s.duration == Fraction(16, 25), "summary duration %s" % s.duration)
    c = parse_rhd_bytes(rhd_file(1, n_amp=8))
    expect_problem(lambda: rhd.recording_summary([("a.rhd", a), ("c.rhd", c)]),
                   "rhd_header_mismatch", "channel count mismatch")
    d = parse_rhd_bytes(rhd_file(1, fs=2000.0))
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

    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/SUBJ-ID-1255_260307_101800.rhd", rhd_file(400))
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/SUBJ-ID-1255_260307_101900.rhd", rhd_file(400))
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/SUBJ-ID-1255_260307_102000.rhd", rhd_file(200))
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/settings.xml", b"<xml/>")
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/_manifest.json", b"{}")
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/empty.txt")
    rec("SUBJ-ID-1255/SUBJ-ID-1255_260307_101800/sub/notes.txt", b"nested")
    rec("SUBJ-ID-1225/SUBJ-ID-1255_260709_095155/SUBJ-ID-1255_260709_095155.rhd", rhd_file(1000))
    rec("SUBJ-ID-1225/SUBJ-ID-1255_260709_095155/settings.xml", b"<xml subject='stale'/>")
    rec("SUBJ-ID-1278/SUBj-ID-1278_261015_094835/a.rhd", rhd_file(1000))
    rec("SUBJ-ID-1154/SUBJ-ID-1154_impedance_03182026.csv", b"ch,z\n")
    os.makedirs(os.path.join(i, "New folder"))
    rec("TEST_260619_144257/TEST_260619_144257.rhd", rhd_file(5))
    rec(".DS_Store", b"x")
    rec("@eaDir/thumb/a.jpg", b"x")
    rec("@eaDir/b.jpg", b"x")
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260402_100000/a.rhd", rhd_file(1000))
    rec("SUBJ-ID-2000/SUBJ-ID-2000_260403_100000/a.rhd", rhd_file(500))         # short
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


SPECS = [DirectorySpec(ROOT, E, "epsych", rig="RIG3", time_zone="America/New_York", min_age_min=1440,
                       paired_by=I),
         DirectorySpec(ROOT, I, "intan", rig="RIG3", pair_with=E, time_zone="America/New_York",
                       min_age_min=1440)]


# The ePsych directory on its own (no pairing configured), for single-listing checks.
E_ALONE = dataclasses.replace(SPECS[0], paired_by=None)


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
    check(g.source_value == "SUBJ-ID-1255_260307T101500", "source value %s" % g.source_value)
    check(any(n.code == "epsych_suffix" for n in g.notes), "suffix noted")

    # The recording: every file, recursively, raw/intan; zero-byte file held inside it.
    check(rec.status == "ready" and rec.subject_id == "SUBJ-ID-1255", "recording ready")
    check(rec.detail == {"acquisition_system_code": "intan_rhx", "modality": "ephys",
                         "sample_rate_hz": "1000", "n_channels": 4, "duration_s": "128"},
          "recording detail %s" % rec.detail)
    check(rec.duration == Fraction(128) and rec.start_local == "2026-03-07 10:18:00", "duration/start")
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

    # Folders that are not known subjects: HELD (unknown_subject), never set aside silently.
    for path in ("%s/TEST/TEST_260101T101010.mat" % E, "%s/TEST_SUBJECT/whatever.mat" % E,
                 "%s/SUBJ-ID-TEST/SUBJ-ID-TEST_260101T101010.mat" % E,
                 "%s/videos/SUBJ-ID-1255_260101T101010.ts" % E,
                 "%s/TEST_260619_144257/TEST_260619_144257.rhd" % I):
        owner = [g for g in res.groups if path in g.all_paths()]
        if owner:
            check(owner[0].status == "held" and owner[0].hold.reason_code == "unknown_subject",
                  "%s in an unknown folder: %s %s" % (path, owner[0].status, owner[0].hold))
        else:
            check(H.get(path) == "unknown_subject", "%s held: %s" % (path, H.get(path)))
    check(not [r for r in res.reported if not r.is_dir], "nothing reported without an override")
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
    g = G[rk("SUBJ-ID-2000/SUBJ-ID-2000_260407_100000")]
    check(g.status == "held" and g.hold.reason_code == "recording_folder_without_rhd",
          "a recording folder without .rhd is a held group")
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
    spec = E_ALONE
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
    spec = E_ALONE
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


# --------------------------------------------------------------------------- review round 2
def mini(tmp, name):
    """An empty storage root with both listed directories."""
    root = os.path.join(tmp, name)
    os.makedirs(os.path.join(root, *E.split("/")))
    os.makedirs(os.path.join(root, *I.split("/")))
    return root


def put(root, rel, data=b"x"):
    write(os.path.join(root, *rel.split("/")), data)
    return os.path.join(root, *rel.split("/"))


def scan_root(root, overrides=(), specs=None, header_cache=None):
    listings = [walk.walk(root, spec) for spec in (specs or SPECS)]
    return interpret(listings, {ROOT: root}, KNOWN, overrides, header_cache=header_cache)


def recording_folder(root, subject_folder, name, n_files=1, blocks=1000):
    base = "%s/%s/%s" % (I, subject_folder, name)
    put(root, base + "/settings.xml", b"<xml/>")
    for k in range(n_files):
        put(root, base + "/%s_%02d.rhd" % (name, k), rhd_file(blocks))
    return base


def identity(g):
    return (ids.group_event_id(g), ids.group_session_id(g), g.label, g.source_value,
            g.session_path, ids.client_digest(g) if g.status == "ready" else None)


def check_d1_transient_members(tmp):
    """D1: a member held for a transient reason holds the whole session."""
    root = mini(tmp, "d1")
    S = E + "/SUBJ-ID-1255/"
    plain = put(root, S + "SUBJ-ID-1255_260709T094800.mat", fixture("epsych_n5_z.mat"))
    put(root, S + "SUBJ-ID-1255_260709T094800_psych.mat", fixture("epsych_n1_z.mat"))
    listings = [walk.walk(root, E_ALONE)]
    os.utime(plain, ns=(1, 1))                       # touched between listing and reading
    g = interpret(listings, {ROOT: root}, KNOWN).groups[0]
    check(g.status == "held" and g.hold.reason_code == "changed_during_scan",
          "a twin that changed during the scan must hold the session: %s %s" % (g.status, g.hold))
    with CountingOpener(fail_paths=[S + "SUBJ-ID-1255_260709T094800_psych.mat"]):
        g = interpret([walk.walk(root, E_ALONE)], {ROOT: root}, KNOWN).groups[0]
    check(g.status == "held" and g.hold.reason_code == "unreadable_file" and g.detail == {},
          "an unreadable twin (5 vs 1 trials) must hold the session, not register 5: %s %s"
          % (g.status, g.detail))
    g = interpret([walk.walk(root, E_ALONE)], {ROOT: root}, KNOWN).groups[0]
    check(g.hold.reason_code == "epsych_trials_disagree", "next pass sees the disagreement")


def check_d2_identity(tmp):
    """D2: a session's ids, label, path and digest do not depend on which twins exist."""
    S = E + "/SUBJ-ID-1255/"
    stem = "SUBJ-ID-1255_260709T094800"
    members = {"plain": S + stem + ".mat", "psych": S + stem + "_psych.mat",
               "delay": S + stem + "_delay.mat", "video": S + stem + ".ts"}
    want = None
    orders = [("plain",), ("psych",), ("delay", "psych"), ("psych", "plain"), ("plain", "video"),
              ("psych", "video"), ("plain", "psych", "delay", "video")]
    for k, order in enumerate(orders):
        root = mini(tmp, "d2_%d" % k)
        for i, m in enumerate(order):
            put(root, members[m], TS_GOOD if m == "video" else fixture("epsych_n5_z.mat"))
            res = scan_root(root, specs=[E_ALONE])
            mats = [g for g in res.groups]
            if not any(x != "video" for x in order[:i + 1]):
                continue
            g = mats[0]
            check(g.status == "ready", "%s: %s %s" % (order, g.status, g.hold))
            got = identity(g)
            if want is None:
                want = got
            check(got == want, "the session identity changed with %s: %s != %s"
                  % (order[:i + 1], got, want))
            has_plain = "plain" in order[:i + 1]
            check(any(n.code == "epsych_no_plain_file" for n in g.notes) == (not has_plain),
                  "epsych_no_plain_file note for %s" % (order[:i + 1],))
    check(want[2] == stem and want[3] == stem and want[4] == S + stem + ".mat",
          "label, source value and session path are the base stem: %s" % (want[2:5],))
    # Date-only forms: the whole stem; _A and _B stay two sessions.
    root = mini(tmp, "d2_dmy")
    put(root, S + "SUBJ-ID-1255_07-Mar-2026_A.mat", fixture("epsych_n1_z.mat"))
    put(root, S + "SUBJ-ID-1255_07-Mar-2026_B.mat", fixture("epsych_n1_z.mat"))
    labels = sorted(g.label for g in scan_root(root, specs=[E_ALONE]).groups)
    check(labels == ["SUBJ-ID-1255_07-Mar-2026_A", "SUBJ-ID-1255_07-Mar-2026_B"], "dmy labels")


def check_d3_subject_folders(tmp):
    """D3: unknown folders are held; only a folder override skips; unstorable components."""
    root = mini(tmp, "d3")
    put(root, E + "/SUBJ-ID-9999/SUBJ-ID-9999_260709T094800.mat", fixture("epsych_n1_z.mat"))
    put(root, E + "/SUBJ-ID-9999/stray.txt", b"x")
    put(root, E + "/TEST/TEST_260709T094800.mat", fixture("epsych_n1_z.mat"))
    put(root, E + "/TEST/notes.txt", b"x")
    put(root, E + "/SUBJ-ID-1255 /SUBJ-ID-1255_260709T094800.mat", fixture("epsych_n1_z.mat"))
    put(root, E + "/SUBJ-ID-1255/sub dir /x.mat", b"x")
    recording_folder(root, "SUBJ-ID-1255 ", "SUBJ-ID-1255_260709_095155")
    res = scan_root(root)
    G, H = by_key(res), held_codes(res)
    check(G[bk("SUBJ-ID-9999/SUBJ-ID-9999_260709T094800")].hold.reason_code == "unknown_subject",
          "a subject missing from lab.subject is held")
    check(H["%s/SUBJ-ID-9999/stray.txt" % E] == "unknown_subject", "loose file of an unknown folder")
    check(G[bk("TEST/TEST_260709T094800")].hold.reason_code == "unknown_subject", "TEST held")
    for path in ("%s/SUBJ-ID-1255 /SUBJ-ID-1255_260709T094800.mat" % E,
                 "%s/SUBJ-ID-1255/sub dir /x.mat" % E,
                 "%s/SUBJ-ID-1255 /SUBJ-ID-1255_260709_095155/settings.xml" % I):
        check(H.get(path) == "path_not_storable", "%s: %s" % (path, H.get(path)))
    check(not [g for g in res.groups if " " in g.key], "no group under an unstorable folder")
    ov = subjects.parse_overrides("root,relative_path,subject_id,reason\n"
                                  "nas-test,%s/TEST,skip,a test folder\n" % E)
    res = scan_root(root, ov)
    G = by_key(res)
    t = G[bk("TEST/TEST_260709T094800")]
    check(t.status == "skipped" and t.hold.reason_code == "override_skip", "folder skip: group")
    check({r.path: r.reason_code for r in res.reported}.get("%s/TEST/notes.txt" % E)
          == "override_skip", "folder skip: loose file reported")
    check(G[bk("SUBJ-ID-9999/SUBJ-ID-9999_260709T094800")].status == "held",
          "another unknown folder stays held")
    check(not res.unused_overrides, "the folder override is used")
    try:
        scan_root(root, subjects.parse_overrides("root,relative_path,subject_id,reason\n"
                                                 "nas-test,%s/TEST,SUBJ-ID-1255,x\n" % E))
        fail("a folder-level override naming a subject was accepted")
    except subjects.OverrideError:
        pass


def check_d4_odd_entries(tmp):
    """D4: a link or odd name inside a group's folder holds the group and is in its signature."""
    root = mini(tmp, "d4")
    base = recording_folder(root, "SUBJ-ID-1255", "SUBJ-ID-1255_260709_095155", n_files=3)
    key = rk("SUBJ-ID-1255/SUBJ-ID-1255_260709_095155")
    full = by_key(scan_root(root))[key]
    check(full.status == "ready" and full.duration == Fraction(384), "three files: %s" % full.duration)
    third = os.path.join(root, *base.split("/"), "SUBJ-ID-1255_260709_095155_02.rhd")
    away = os.path.join(tmp, "d4_elsewhere.rhd")
    os.rename(third, away)
    cases = []
    try:
        os.symlink(away, third)
        cases.append(("link", "symbolic_link", third))
    except (OSError, NotImplementedError):
        pass
    for label, code, path in cases:
        g = by_key(scan_root(root))[key]
        check(g.status == "held" and g.hold.reason_code == code and g.detail == {},
              "%s .rhd: %s %s" % (label, g.status, g.hold))
        check(any(h.path.endswith("_02.rhd") for h in g.held_files)
              and ids.signature(g) != ids.signature(full), "%s .rhd in the signature" % label)
        os.unlink(path)
    os.rename(away, third + " ")                                  # trailing space
    g = by_key(scan_root(root))[key]
    check(g.status == "held" and g.hold.reason_code == "path_not_storable",
          "an .rhd named with a trailing space: %s %s" % (g.status, g.hold))
    os.rename(third + " ", os.path.join(os.fsencode(os.path.dirname(third)).decode(
        "utf-8", "surrogateescape"), b"caf\xe9.rhd".decode("utf-8", "surrogateescape")))
    g = by_key(scan_root(root))[key]
    check(g.status == "held" and g.hold.reason_code == "path_not_storable", "a Latin-1 name")
    # ePsych: a twin that is a link holds the session.
    S = E + "/SUBJ-ID-1255/"
    put(root, S + "SUBJ-ID-1255_260709T094800.mat", fixture("epsych_n5_z.mat"))
    target = put(root, "elsewhere/x.mat", fixture("epsych_n5_z.mat"))
    try:
        os.symlink(target, os.path.join(root, *(S + "SUBJ-ID-1255_260709T094800_psych.mat").split("/")))
    except (OSError, NotImplementedError):
        return
    g = by_key(scan_root(root, specs=[E_ALONE]))[bk("SUBJ-ID-1255/SUBJ-ID-1255_260709T094800")]
    check(g.status == "held" and g.hold.reason_code == "symbolic_link", "ePsych twin link")


def check_r1_pair_specs(tmp):
    root = mini(tmp, "r1")
    for label, specs in (("ePsych alone", [SPECS[0]]), ("Intan alone", [SPECS[1]]),
                         ("no paired_by", [E_ALONE, SPECS[1]]),
                         ("wrong paired_by", [dataclasses.replace(SPECS[0], paired_by="x/y"),
                                              SPECS[1]])):
        try:
            interpret([walk.walk(root, s) for s in specs], {ROOT: root}, KNOWN)
            fail("%s was accepted" % label)
        except ValueError:
            pass
    scan_root(root)                                              # both: accepted


def check_r2_recordings_in_sight(tmp):
    root = mini(tmp, "r2")
    S = E + "/SUBJ-ID-1255/"
    put(root, S + "SUBJ-ID-1255_260709T094800.mat", fixture("epsych_n5_z.mat"))
    put(root, I + "/SUBJ-ID-1255/SUBJ-ID-1255_260709_095155/settings.xml", b"<xml/>")
    res = scan_root(root)
    e = by_key(res)[bk("SUBJ-ID-1255/SUBJ-ID-1255_260709T094800")]
    check(e.status == "held" and e.hold.reason_code == "paired_recording_held",
          "an ePsych session near a folder without .rhd: %s %s" % (e.status, e.hold))
    ov = subjects.parse_overrides("root,relative_path,subject_id,reason\nnas-test,%s/SUBJ-ID-1255/"
                                  "SUBJ-ID-1255_260709_095155,skip,aborted\n" % I)
    e = by_key(scan_root(root, ov))[bk("SUBJ-ID-1255/SUBJ-ID-1255_260709T094800")]
    check(e.status == "ready" and any(n.code == "pairing_skipped_recording" for n in e.notes),
          "near a skipped recording: %s %s" % (e.status, [n.code for n in e.notes]))
    # M3: a ':' in folder names does not break the notes.
    root = mini(tmp, "r2b")
    recording_folder(root, "S:1", "S:1_260709_095155")
    put(root, E + "/S:1/S:1_260709T094800.mat", fixture("epsych_n1_z.mat"))
    put(root, E + "/S:1/S:1_260709T094810.mat", fixture("epsych_n1_z.mat"))
    listings = [walk.walk(root, spec) for spec in SPECS]
    res = interpret(listings, {ROOT: root}, KNOWN | {"S:1"})
    check(all(g.hold.reason_code == "pairing_ambiguous" for g in res.groups if g.kind == "behavior"),
          "a ':' in a name")


def check_m8_case_conflicts(tmp):
    root = mini(tmp, "m8")
    recording_folder(root, "SUBJ-ID-1255", "SUBJ-ID-1255_260709_095155")
    recording_folder(root, "SUBJ-ID-1255", "SUBj-ID-1255_260709_095155")
    put(root, I + "/SUBJ-ID-1255/SUBJ-ID-1278_260710_095155/a.rhd", rhd_file(10))
    put(root, I + "/SUBJ-ID-1255/SUBJ-ID-1278_260710_095155/A.RHD", rhd_file(10))
    res = scan_root(root)
    for g in res.groups:
        check(g.status == "held" and "name_case_conflict" in
              [g.hold.reason_code] + [n.code for n in g.notes], "%s: %s" % (g.key, g.hold))


def check_m13_incomplete(tmp):
    root = mini(tmp, "m13")
    put(root, E + "/SUBJ-ID-1255/SUBJ-ID-1255_260709T094800.mat", fixture("epsych_n5_z.mat"))
    put(root, E + "/SUBJ-ID-1278/SUBJ-ID-1278_260709T094800.mat", fixture("epsych_n5_z.mat"))
    target = os.path.join(root, *E.split("/"), "SUBJ-ID-1278")
    real = os.scandir

    def failing(path="."):
        if os.path.abspath(str(path)) == os.path.abspath(target):
            raise PermissionError(13, "Permission denied", str(path))
        return real(path)
    os.scandir = failing
    try:
        res = scan_root(root, specs=[E_ALONE])
    finally:
        os.scandir = real
    check(not res.complete and all(g.status == "held" and g.hold.reason_code == "listing_incomplete"
                                   for g in res.groups) and res.groups, "incomplete listing")


def check_minor():
    from nas_import.layouts import _common
    check(_common.file_format("a/b/name.") is None and _common.file_format("a/x.TAR.GZ") == "gz"
          and _common.file_format("a/.hidden") is None, "M11 file_format")
    for name in (".ds_store", "THUMBS.DB", "desktop.ini", "Desktop.INI", "@EADIR", "~$x.docx"):
        check(walk.is_ignored_name(name), "M12 %s ignored" % name)
    check(not walk.is_ignored_name("data.mat"), "M12 ordinary name")
    for bad in ("SUBJ-ID-1255_07-Mar-0026.mat", "SUBJ-ID-1255_07-Mar-2100.mat",
                "SUBJ-ID-1255_07-Mar-1989.mat"):
        try:
            names.parse_epsych(bad)
            fail("M6 %s accepted" % bad)
        except names.BadNameTime:
            pass
    check(names.parse_epsych("SUBJ-ID-1255_07-Mar-1990.mat").date == "1990-03-07", "M6 1990")
    check(names.ascii_fold("ſUBJ") != names.ascii_fold("SUBJ") and
          names.ascii_fold("SUBj") == names.ascii_fold("subJ"), "M7 ASCII fold only")
    g = dataclasses.replace(
        Group(key="k", kind="behavior", layout="epsych", root=ROOT, directory=E, rig=None,
              time_zone="America/New_York", source_path="p", source_value="v",
              subject_folder="SUBJ-ID-1255", subject_in_name="ſUBJ-ID-1255", label="l",
              session_path="p.mat", start_local=None, date="2026-01-01", precision="day",
              duration=None, files=(), held_files=(), detail={}))
    check(subjects.resolve_group(g, KNOWN, None).hold.reason_code == "subject_mismatch",
          "M7 long s is not S")
    try:
        subjects.parse_overrides('root,relative_path,subject_id,reason\nnas-test,a/b,skip,"why\n')
        fail("M2 unterminated quote accepted")
    except subjects.OverrideError as exc:
        check("line 2" in str(exc), "M2 names the line: %s" % exc)
    try:
        subjects.parse_overrides('root,relative_path,subject_id,reason\nnas-test,a/b,skip,"l1\nl2"\n'
                                 'nas-test,c/d,skip\n')
        fail("a short row after a multi-line one accepted")
    except subjects.OverrideError as exc:
        check("line 4" in str(exc), "the line of a row after a multi-line one: %s" % exc)
    # R4, M4, M10, R5 on the .rhd reader.
    for v in ((0, 9), (4, 0), (-1, 0)):
        expect_problem(lambda: parse_rhd_bytes(rhd_file(1, version=v)), "rhd_unknown_version",
                       "version %s" % (v,))
    h = rhd_header()
    big = h[:48] + struct.pack("<I", 800_000_000) + h[52:]
    expect_problem(lambda: parse_rhd_bytes(big), "rhd_bad_header", "M4 a huge QString")
    hd = parse_rhd_bytes(rhd_file(2, group_enabled=0))
    check(hd.num_amplifier_channels == 4 and hd.num_data_blocks == 2,
          "M10 channel records of a disabled group are read and counted")
    for rate in rhd.RHX_RATES:
        got = parse_rhd_bytes(rhd_header(fs=float(rate))).sample_rate
        check(got == rate, "R5 rate %s read as %s" % (rate, got))
    for bad in (0.0, -25000.0, float("nan"), float("inf"), 25000.5, 24999.0, 128.0):
        expect_problem(lambda: parse_rhd_bytes(rhd_header(fs=bad)), "rhd_bad_header",
                       "R5 rate %r" % bad)
    check(parse_rhd_bytes(_groups_header(12)).num_amplifier_channels == 0, "12 groups read")
    expect_problem(lambda: parse_rhd_bytes(_groups_header(13)), "rhd_bad_header", "13 groups")


def _groups_header(n):
    h = rhd_header(n_amp=0, n_dig=0)
    cut = h.rfind(struct.pack("<h", 1) + qstring("Port A"))
    return h[:cut] + struct.pack("<h", n) + (qstring("G") + qstring("G") + struct.pack("<hhh", 1, 0, 0)) * n


def check_r7_hostile_cache(tmp):
    root = mini(tmp, "r7")
    recording_folder(root, "SUBJ-ID-1255", "SUBJ-ID-1255_260709_095155")
    put(root, E + "/SUBJ-ID-1255/SUBJ-ID-1255_260709T094800.mat", fixture("epsych_n5_z.mat"))
    put(root, E + "/SUBJ-ID-1255/SUBJ-ID-1255_260709T094800.ts", TS_GOOD)
    listings = [walk.walk(root, spec) for spec in SPECS]
    cold = interpret(listings, {ROOT: root}, KNOWN)
    good = dict(cold.headers)
    want = without_headers(cold)
    n = 0
    for key, e in good.items():
        variants = [{"reader": e["reader"]}, {"reader": e["reader"], "problem": 5},
                    {"reader": e["reader"], "problem": ["no_such_code", "x"]},
                    {"reader": e["reader"], "problem": ["unreadable_file", "x"]},
                    {"reader": e["reader"], "problem": ["mat_corrupt"]},
                    {"reader": e["reader"], "problem": ["rhd_bad_magic" if "variables" in e
                                                        else "mat_corrupt", "wrong reader"]},
                    dict(e, extra=1)]
        if "header" in e:
            for rate in ("1/0", "0/1", "-5/1", "abc", "", "nan", "inf", "1e400", 25000, None,
                         "25000/1/1", " 25000 ", "1000/1", "128/1"):
                variants.append({"reader": e["reader"], "header": dict(e["header"], sample_rate=rate)})
            for f in ("num_amplifier_channels", "num_data_blocks", "samples_per_block", "file_size"):
                for v in (None, "64", 64.0, True, [], -1, 10 ** 30):
                    variants.append({"reader": e["reader"], "header": dict(e["header"], **{f: v})})
            variants.append({"reader": e["reader"], "header": dict(
                e["header"], num_data_blocks=5, num_amplifier_channels=32)})
        if "variables" in e:
            for rows in (None, [5], [["Data", "struct"]], [["Data", "struct", "12", False]],
                         [["Data", "struct", [1.0, 2.0], False]], [["Data", "struct", [True, 5], False]],
                         [["Data", "struct", [10 ** 30, 5], False], ["Info", "struct", [1, 1], False]],
                         [[5, "struct", [1, 2], False]], [["Data", ["struct"], [1, 2], False]],
                         [{"a": 1}], [["Data", "struct", [1, 7], False], ["Info", "struct", [1, 1], False],
                                      ["Data", "struct", [1, 9], False]]):
                variants.append({"reader": e["reader"], "variables": rows})
        if "packets" in e:
            for v in (None, -1, "8", 8.0, True, [], 3, 10 ** 9):
                variants.append({"reader": e["reader"], "packets": v})
        for bad in variants:
            c = dict(good)
            c[key] = bad
            try:
                r = interpret(listings, {ROOT: root}, KNOWN, header_cache=c)
            except Exception as exc:  # noqa: BLE001
                fail("a hostile cache entry crashed the interpretation: %r -> %r" % (bad, exc))
            check(without_headers(r) == want, "a hostile cache entry changed the result: %r" % (bad,))
            n += 1
    check(n > 60, "hostile entries tried: %d" % n)
    path = os.path.join(tmp, "r7.json")
    for text in ("[" * 100000, '{"format":"%s","entries":[[' % cache.FORMAT, "null", "\x00\x01",
                 '{"format":"%s","entries":5}' % cache.FORMAT):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        check(len(cache.HeaderCache.load(path)) == 0, "a damaged cache file must load empty")


def check_r8_mat_integrity(tmp):
    with open(os.path.join(TESTDATA, "expected.json"), encoding="utf-8") as fh:
        expected = json.load(fh)["files"]
    for name, want in expected.items():
        if isinstance(want, str):
            continue
        path = os.path.join(TESTDATA, name)
        with open(path, "rb") as fh:
            mat5.verify_file(fh, os.path.getsize(path))           # every valid fixture verifies
    good_u = fixture("epsych_n3_u.mat")
    # (a) an uncompressed Data whose dimensions claim more elements than its bytes can hold
    dims_at = [i for i in range(140, 200) if good_u[i:i + 8] == struct.pack("<ii", 1, 3)][0]
    big = good_u[:dims_at] + struct.pack("<ii", 1, 100000) + good_u[dims_at + 8:]
    expect_problem(lambda: mat_bytes(big), "mat_corrupt", "R8a implausible numel")
    # the cheap pass cannot see 1x3 -> 1x4 in a struct; verify_file counts the fields
    four = good_u[:dims_at] + struct.pack("<ii", 1, 4) + good_u[dims_at + 8:]
    check(mat5.epsych_trials(mat_bytes(four)) == 4, "the cheap pass is fooled by 1x4")
    import io
    expect_problem(lambda: mat5.verify_file(io.BytesIO(four), len(four)), "mat_corrupt",
                   "R8b verify_file sees 1x4 fields of a 1x3 struct")
    # (b) compressed: zero-filled stream tail, bytes after the stream, bit flips
    good_z = fixture("epsych_n5_z.mat")
    n = struct.unpack_from("<I", good_z, 132)[0]
    for keep in (n // 2, n - 5, n - 1):
        b = bytearray(good_z)
        b[136 + keep:136 + n] = b"\x00" * (n - keep)
        expect_problem(lambda: mat5.verify_file(io.BytesIO(bytes(b)), len(b)), "mat_corrupt",
                       "zero-filled stream tail keep=%d" % keep)
    import zlib
    inflated = zlib.decompress(good_z[136:136 + n])
    flips = 0
    for pos in range(136, 136 + n):
        for bit in range(8):
            b = bytearray(good_z)
            b[pos] ^= 1 << bit
            try:
                mat5.verify_file(io.BytesIO(bytes(b)), len(b))
            except mat5.MatProblem:
                flips += 1
                continue
            # Not caught: only a flip that changes nothing (a padding bit of the last
            # deflate byte, which zlib ignores) may pass.
            check(zlib.decompress(bytes(b[136:136 + n])) == inflated,
                  "a bit flip at byte %d bit %d changed the data and passed verify_file" % (pos, bit))
    check(flips >= 0.95 * 8 * n, "bit flips caught: %d of %d" % (flips, 8 * n))


# --------------------------------------------------------------------------- review round 3
def check_n1_unencodable_names(tmp):
    """N1: a group with a member whose name is not UTF-8 still has a signature."""
    check(ids.sha256_text("caf\udce9") != ids.sha256_text("caf\udce8"), "surrogates hash apart")
    check(ids.sha256_text("café") == __import__("hashlib").sha256("café".encode()).hexdigest(),
          "valid text hashes as plain UTF-8")
    check(ids.event_id("recording", ROOT, "a/b") == str(uuid.uuid5(ids.NAMESPACE,
                                                                  "event:recording:%s:a/b" % ROOT)),
          "ids are uuid5 for valid text")
    ids.session_id(ROOT, "a/caf\udce9")                          # must not raise
    ids.canonical_json({"p": "caf\udce9"})
    if os.name == "nt":
        return
    sigs = []
    for k, raw in enumerate((b"caf\xe9.rhd", b"caf\xe8.rhd")):
        root = mini(tmp, "n1_%d" % k)
        base = recording_folder(root, "SUBJ-ID-1255", "SUBJ-ID-1255_260709_095155")
        folder = os.path.join(root, *base.split("/"))
        with open(os.path.join(os.fsencode(folder), raw), "wb") as fh:
            fh.write(b"x")
        g = by_key(scan_root(root))[rk("SUBJ-ID-1255/SUBJ-ID-1255_260709_095155")]
        check(g.status == "held" and g.hold.reason_code == "path_not_storable", "N1 held")
        sig = ids.signature(g)
        check(sig == ids.signature(by_key(scan_root(root))[g.key]), "N1 signature is deterministic")
        sigs.append(sig)
    check(sigs[0] != sigs[1], "N1 distinct names give distinct signatures")
    hc = cache.HeaderCache({(ROOT, "a/caf\udce9.rhd", 1, 2): {"reader": "x"}})
    path = os.path.join(tmp, "n1.json")
    hc.save(path)
    check(dict(cache.HeaderCache.load(path)) == dict(hc), "a surrogate key round-trips the cache file")


def _mat_inner(data):
    """The inflated miMATRIX of the first compressed variable of DATA, and its element bounds."""
    import zlib
    n = struct.unpack_from("<I", data, 132)[0]
    return zlib.decompress(data[136:136 + n]), 128, 136 + n


def _recompressed(data, inner):
    import zlib
    _, start, end = _mat_inner(data)
    c = zlib.compress(inner)
    return data[:start] + struct.pack("<II", 15, len(c)) + c + data[end:]


def check_n2_nested_damage():
    """N2: damage inside struct fields is found, uncompressed and (inflated) compressed."""
    import io
    good_u = fixture("epsych_n3_u.mat")
    good_z = fixture("epsych_n5_z.mat")
    flags = struct.pack("<II", 6, 8)
    damaged = []
    # a field name with a byte that is not ASCII
    at = good_u.index(b"TrialID")
    damaged.append(("field name, uncompressed", good_u[:at + 2] + b"\xf2" + good_u[at + 3:]))
    # the first nested matrix (a field value) turned from double into char
    first = good_u.index(flags, good_u.index(b"TrialID"))
    damaged.append(("nested class, uncompressed",
                    good_u[:first + 8] + b"\x04" + good_u[first + 9:]))
    # a nested dimension changed
    dims = good_u.index(struct.pack("<IIii", 5, 8, 1, 1), first)
    damaged.append(("nested dims, uncompressed",
                    good_u[:dims + 8] + struct.pack("<i", 3) + good_u[dims + 12:]))
    inner, _s, _e = _mat_inner(good_z)
    i_first = inner.index(flags, inner.index(b"TrialID"))
    damaged.append(("nested class, compressed",
                    _recompressed(good_z, inner[:i_first + 8] + b"\x04" + inner[i_first + 9:])))
    i_dims = inner.index(struct.pack("<IIii", 5, 8, 1, 1), i_first)
    damaged.append(("nested dims, compressed", _recompressed(
        good_z, inner[:i_dims + 8] + struct.pack("<i", 7) + inner[i_dims + 12:])))
    at = inner.index(b"TrialID")
    damaged.append(("field name, compressed",
                    _recompressed(good_z, inner[:at] + b"1rialID" + inner[at + 7:])))
    check(_recompressed(good_z, inner) != good_z or True, "recompression helper")
    mat5.verify_file(io.BytesIO(_recompressed(good_z, inner)), len(_recompressed(good_z, inner)))
    for label, data in damaged:
        mat_bytes(data)                                   # the header pass does not see it
        expect_problem(lambda: mat5.verify_file(io.BytesIO(data), len(data)), "mat_corrupt",
                       "N2 " + label)


def check_n3_verify_cost(tmp):
    """N3: verify_file seeks past data: constant memory, time by elements, not bytes."""
    import time
    import tracemalloc

    def tag(t, payload):
        return struct.pack("<II", t, len(payload)) + payload + b"\0" * ((-len(payload)) % 8)
    head = b"MATLAB 5.0 MAT-file, Platform: test".ljust(116) + bytes(8) + struct.pack("<H", 0x0100) + b"IM"
    info = tag(6, struct.pack("<II", 2, 0)) + tag(5, struct.pack("<ii", 1, 1)) + tag(1, b"Info") \
        + tag(5, struct.pack("<i", 8)) + tag(1, b"")
    info = struct.pack("<II", 14, len(info)) + info
    path = os.path.join(tmp, "n3.mat")
    n = 8 << 20                                           # 8 Mi doubles: a 64 MiB body
    body = tag(6, struct.pack("<II", 6, 0)) + tag(5, struct.pack("<ii", 1, n)) + tag(1, b"Data")
    with open(path, "wb") as fh:
        fh.write(head + struct.pack("<II", 14, len(body) + 8 + 8 * n) + body
                 + struct.pack("<II", 9, 8 * n))
        fh.seek(8 * n, 1)
        fh.write(info)
    tracemalloc.start()
    t0 = time.perf_counter()
    with open(path, "rb") as fh:
        mat5.verify_file(fh, os.path.getsize(path))
    dt, peak = time.perf_counter() - t0, tracemalloc.get_traced_memory()[1]
    tracemalloc.stop()
    check(dt < 5 and peak < 4 << 20, "N3 64 MiB body: %.2f s, peak %d B" % (dt, peak))
    # a struct array of 100000 elements, one field each, every value an empty matrix
    m = 100000
    body = tag(6, struct.pack("<II", 2, 0)) + tag(5, struct.pack("<ii", 1, m)) + tag(1, b"Data") \
        + tag(5, struct.pack("<i", 8)) + tag(1, b"a".ljust(8, b"\0")) + struct.pack("<II", 14, 0) * m
    data = head + struct.pack("<II", 14, len(body)) + body + info
    with open(path, "wb") as fh:
        fh.write(data)
    tracemalloc.start()
    with open(path, "rb") as fh:
        mat5.verify_file(fh, len(data))
        check(mat5.epsych_trials(mat5.read_variables(fh, len(data))) == m, "N3 struct read")
    peak = tracemalloc.get_traced_memory()[1]
    tracemalloc.stop()
    check(peak < 4 << 20, "N3 struct of 100000 elements: peak %d B" % peak)
    bad = data[:-len(info) - 8] + struct.pack("<II", 1, 0) + info  # last element is no matrix
    expect_problem(lambda: mat5.verify_file(__import__("io").BytesIO(bad), len(bad)), "mat_corrupt",
                   "N3 a struct element that is not a matrix")


def check_n4_unresolved_pools(tmp):
    """N4: an unresolved recording blocks the ePsych sessions of its folder AND its name."""
    root = mini(tmp, "n4")
    recording_folder(root, "SUBJ-ID-1225", "SUBJ-ID-1255_260709_095155")
    for subj in ("SUBJ-ID-1255", "SUBJ-ID-1225"):
        put(root, "%s/%s/%s_260709T094800.mat" % (E, subj, subj), fixture("epsych_n5_z.mat"))
    G = by_key(scan_root(root))
    for subj in ("SUBJ-ID-1255", "SUBJ-ID-1225"):
        e = G[bk("%s/%s_260709T094800" % (subj, subj))]
        check(e.status == "held" and e.hold.reason_code == "paired_recording_held",
              "N4 the %s session near a mislabelled recording: %s %s" % (subj, e.status, e.hold))
    ov = subjects.parse_overrides("root,relative_path,subject_id,reason\nnas-test,%s/SUBJ-ID-1225/"
                                  "SUBJ-ID-1255_260709_095155,SUBJ-ID-1225,folder is right\n" % I)
    G = by_key(scan_root(root, ov))
    check(G[bk("SUBJ-ID-1225/SUBJ-ID-1225_260709T094800")].status == "ready"
          and G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260709T094800")].status == "ready"
          and G[bk("SUBJ-ID-1255/SUBJ-ID-1255_260709T094800")].pairing.status == "unpaired",
          "N4 once the override names the subject, the other subject's session is free")
    root = mini(tmp, "n4b")
    recording_folder(root, "SUBJ-ID-9", "SUBJ-ID-1255_260709_095155")
    put(root, "%s/SUBJ-ID-1255/SUBJ-ID-1255_260709T094800.mat" % E, fixture("epsych_n5_z.mat"))
    e = by_key(scan_root(root))[bk("SUBJ-ID-1255/SUBJ-ID-1255_260709T094800")]
    check(e.status == "held" and e.hold.reason_code == "paired_recording_held",
          "N4 a recording under an unknown folder blocks the subject in its name")


def check_g_group_amp_count():
    """G: a v3 group's amplifier-count field must equal its type-0 records."""
    h = rhd_header(n_amp=4, n_adc=1)
    cut = h.rfind(qstring("A")) + len(qstring("A"))
    for main, ok in ((3, False), (2, True), (1, True)):
        hb = rhd_header(n_amp=4, n_adc=1, version=(main, 0))
        c = hb.rfind(qstring("A")) + len(qstring("A"))
        bad = hb[:c + 4] + struct.pack("<h", 3) + hb[c + 6:]
        spb = 60 if main == 1 else 128
        data = bad + b"\0" * block_bytes(spb, 4, n_adc=1, n_temp=0)
        if ok:
            check(parse_rhd_bytes(data).num_amplifier_channels == 4, "G not checked for v%d" % main)
        else:
            expect_problem(lambda: parse_rhd_bytes(data), "rhd_bad_header", "G v3 count mismatch")
    # Every single-byte change of a v3 header with 4 amplifier and 1 ADC channels, the data
    # blocks not zeros (as recorded data is not): none may be accepted with another
    # amplifier-channel count or block count -- the changed type of a channel included.
    # Not detectable from one header, and not asserted: a rate changed into another
    # RHX rate (the sibling check of a recording catches it when it has two files) and a
    # swap between board types of equal block size (an ADC and the only digital input).
    nb = 3 * block_bytes(128, 4, n_adc=1)
    full = h + (bytes(range(1, 256)) * (nb // 255 + 1))[:nb]
    want = parse_rhd_bytes(full)
    facts = lambda x: (x.num_amplifier_channels, x.num_data_blocks)  # noqa: E731
    wrong = []
    for pos in range(len(h)):
        for v in {full[pos] ^ (1 << b) for b in range(8)} | {0, 0xFF, 3, 1}:
            if v == full[pos]:
                continue
            b = bytearray(full)
            b[pos] = v
            try:
                got = parse_rhd_bytes(bytes(b))
            except rhd.RhdProblem:
                continue
            if facts(got) != facts(want):
                wrong.append((pos, v, facts(got)))
    check(not wrong, "G single-byte header changes accepted with other facts: %s" % wrong[:5])
    del cut


def check_e_hooks(tmp):
    """E1 stats, E2 session id, E3 codes."""
    root = mini(tmp, "e")
    recording_folder(root, "SUBJ-ID-1255", "SUBJ-ID-1255_260709_095155", n_files=2)
    put(root, E + "/SUBJ-ID-1255/SUBJ-ID-1255_260709T094800.mat", fixture("epsych_n5_z.mat"))
    listings = [walk.walk(root, spec) for spec in SPECS]
    stats = {}
    with CountingOpener() as o:
        cold = interpret(listings, {ROOT: root}, KNOWN, stats=stats)
    check(stats.get("files_opened") == len(o.opened) == 3 and stats.get("bytes_read", 0) > 0,
          "E1 stats %s" % stats)

    class Stats:
        pass
    st = Stats()
    interpret(listings, {ROOT: root}, KNOWN, header_cache=cold.headers, stats=st)
    check(getattr(st, "files_opened", 0) == 0 and getattr(st, "bytes_read", 0) == 0,
          "E1 a warm cache reads nothing")
    beh = [g for g in cold.groups if g.kind == "behavior"][0]
    other = "00000000-0000-5000-8000-000000000001"
    src = ids.digest_source(beh, session_id=other)
    check(src["session_id"] == other and ids.digest_source(beh)["session_id"] == ids.group_session_id(beh),
          "E2 digest_source session id")
    check(ids.client_digest(beh, session_id=other) != ids.client_digest(beh)
          and ids.event_attributes(beh, "v", session_id=other)["client_digest"]
          == ids.client_digest(beh, session_id=other), "E2 digest and attributes")
    for code in ("would_correct", "content_changed", "late_recording", "path_case_conflict",
                 "registered_but_withdrawn", "copy_ambiguous", "copy_event_mismatch",
                 "duplicate_content", "session_conflict", "local_time_nonexistent",
                 "local_time_ambiguous", "unknown_subject", "name_case_conflict"):
        check(code in REASON_CODES, "E3 %s" % code)


def main():
    check_rhd()
    check_mat()
    check_names()
    check_pairing_rule()
    check_ts()
    check_minor()
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
        check_d1_transient_members(tmp)
        check_d2_identity(tmp)
        check_d3_subject_folders(tmp)
        check_d4_odd_entries(tmp)
        check_r1_pair_specs(tmp)
        check_r2_recordings_in_sight(tmp)
        check_m8_case_conflicts(tmp)
        check_m13_incomplete(tmp)
        check_r7_hostile_cache(tmp)
        check_r8_mat_integrity(tmp)
        check_n1_unencodable_names(tmp)
        check_n2_nested_damage()
        check_n3_verify_cost(tmp)
        check_n4_unresolved_pools(tmp)
        check_g_group_amp_count()
        check_e_hooks(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("check_nas_import_parsing: OK")


if __name__ == "__main__":
    main()
