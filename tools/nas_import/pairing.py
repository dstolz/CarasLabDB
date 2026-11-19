"""Pairing ePsych sessions with recordings: the rule of ``findCopySessions.m``.

Port of ephys_analysis ``pipeline/findCopySessions.m`` (``pairSessions``,
lines 466-533, and its callers, lines 253-310), with its default options
(lines 137-140): MaxLeadTime 10 min, MaxLagTime 2 min, AmbiguityMargin 30 s,
MinRecordingDuration 2 min.

* Times are the wall-clock times of the names, compared as unzoned times,
  as findCopySessions compares them; whole seconds.
* An ePsych session is a candidate for a recording of the same subject when
  ``-MaxLeadTime <= dt <= MaxLagTime``, dt = ePsych start - recording start,
  both ends inclusive (line 479: ``dt >= -opts.MaxLeadTime & dt <=
  opts.MaxLagTime``).
* A recording shorter than MinRecordingDuration takes no part (line 268:
  ``short = iDur < opts.MinRecordingDuration``, strict, so exactly 2 min
  pairs; an unknown duration -- a recording held for its headers -- is not
  short, "paired as usual").
* Candidates form connected sets (union-find, lines 484-495); within a set
  the candidate pairs are taken in order of |dt| (MATLAB ``sort`` is stable:
  ties keep candidate order, ePsych-major as ``ndgrid`` lists them, lines
  476-477, 500) and assigned greedily one to one. When, at an assignment,
  another candidate pair sharing the recording or the ePsych session, both
  of whose ends are still free, has ``|dt| - |dt of this pair| < margin``
  (line 510, strict: exactly 30 s further is not a rival), the whole set is
  ambiguous: nothing in it is paired (lines 518-528).
* Date-only ePsych sessions are never paired (they are not in
  findCopySessions' file pattern, line 198).

What the importer does with the result (``apply_pairing``):

* a paired ePsych group joins the recording's session (``session_path``,
  ``label``); if that recording is not ``ready`` the ePsych group is held
  (``paired_recording_held``);
* every ePsych group of an ambiguous set is held (``pairing_ambiguous``);
  its recordings stay as they are (a recording's own session does not
  depend on the pairing) with a note;
* the others keep their own session (unpaired) with a note.

Groups take part when their status is ``ready`` or ``held`` (a held group
still occupies its time, so it can make a set ambiguous or claim a file);
the subject is the resolved one, or the subject folder while unresolved.
"""

from __future__ import annotations

import dataclasses
from collections import defaultdict
from collections.abc import Sequence
from dataclasses import dataclass
from fractions import Fraction

from .model import DirectorySpec, Group, Hold, Note, Pairing
from .names import wall_seconds
from .rhd import decimal_text

MAX_LEAD_S = 600
MAX_LAG_S = 120
AMBIGUITY_MARGIN_S = 30
MIN_RECORDING_S = 120


@dataclass(frozen=True)
class Recording:
    key: str
    time: int                       # wall-clock seconds
    duration: Fraction | None       # None: unknown


@dataclass(frozen=True)
class Session:
    key: str
    time: int


@dataclass(frozen=True)
class PairResult:
    pair_of: dict                   # recording key -> ePsych key
    ambiguous_recordings: frozenset
    ambiguous_sessions: frozenset
    short: frozenset                # recording keys too short to pair
    candidates: dict                # key -> list of (other key, dt), for notes


def pair_subject(recordings: Sequence[Recording], sessions: Sequence[Session]) -> PairResult:
    """Pair one subject's recordings and ePsych sessions (findCopySessions' rule)."""
    recs = list(recordings)
    eps = list(sessions)
    short = frozenset(r.key for r in recs
                      if r.duration is not None and r.duration < MIN_RECORDING_S)
    pair_of: dict[str, str] = {}
    amb_r: set[str] = set()
    amb_e: set[str] = set()
    cands_note: dict[str, list] = defaultdict(list)
    # Candidate pairs, ePsych-major like MATLAB's ndgrid(1:nI, 1:nE)(:).
    C: list[tuple[int, int, int]] = []           # (i, j, dt)
    for j, e in enumerate(eps):
        for i, r in enumerate(recs):
            dt = e.time - r.time
            if -MAX_LEAD_S <= dt <= MAX_LAG_S and r.key not in short:
                C.append((i, j, dt))
                cands_note[r.key].append((e.key, dt))
                cands_note[e.key].append((r.key, dt))
    if not C:
        return PairResult(pair_of, frozenset(), frozenset(), short, dict(cands_note))

    n_i = len(recs)
    parent = list(range(n_i + len(eps)))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for i, j, _dt in C:
        a, b = find(i), find(n_i + j)
        if a != b:
            parent[max(a, b)] = min(a, b)
    sets: dict[int, list[int]] = defaultdict(list)
    for c, (i, _j, _dt) in enumerate(C):
        sets[find(i)].append(c)

    for members in sets.values():
        order = sorted(members, key=lambda c: abs(C[c][2]))      # stable, as MATLAB sort
        taken_i: set[int] = set()
        taken_j: set[int] = set()
        pairs = []
        tie = False
        for c in order:
            i, j, dt = C[c]
            if i in taken_i or j in taken_j:
                continue
            rivals = [r for r in order if r != c and (C[r][0] == i or C[r][1] == j)
                      and C[r][0] not in taken_i and C[r][1] not in taken_j]
            if any(abs(C[r][2]) - abs(dt) < AMBIGUITY_MARGIN_S for r in rivals):
                tie = True
                break
            taken_i.add(i)
            taken_j.add(j)
            pairs.append((i, j))
        if tie:
            amb_r.update(recs[C[c][0]].key for c in members)
            amb_e.update(eps[C[c][1]].key for c in members)
        else:
            for i, j in pairs:
                pair_of[recs[i].key] = eps[j].key
    return PairResult(pair_of, frozenset(amb_r), frozenset(amb_e), short, dict(cands_note))


def _pool_subject(g: Group) -> str:
    return g.subject_id if g.subject_id is not None else g.subject_folder


def _takes_part(g: Group) -> bool:
    return g.status in ("ready", "held")


def _cands(result: PairResult, key: str) -> str:
    return "; ".join("%s (%+d s)" % (k.rsplit(":", 1)[1].rsplit("/", 1)[1], dt)
                     for k, dt in sorted(result.candidates.get(key, [])))


def apply_pairing(groups: Sequence[Group], specs: Sequence[DirectorySpec]) -> tuple[Group, ...]:
    """Pair every recording directory with the ePsych directory its spec names.

    All recording directories naming the same (root, pair_with) are pooled,
    as findCopySessions pools its RecordingRoots. ValueError when
    ``pair_with`` names a directory that is not listed or not ``epsych``.
    """
    by_dir = {(s.root, s.path): s for s in specs}
    targets: dict[tuple[str, str], list[tuple[str, str]]] = defaultdict(list)
    for s in specs:
        if s.pair_with is None:
            continue
        other = by_dir.get((s.root, s.pair_with))
        if other is None:
            raise ValueError("%s:%s pairs with %s, which is not a listed directory"
                             % (s.root, s.path, s.pair_with))
        if other.layout != "epsych" or s.layout != "intan":
            raise ValueError("%s:%s (%s) pairs with %s (%s): only intan with epsych is defined"
                             % (s.root, s.path, s.layout, s.pair_with, other.layout))
        targets[(s.root, s.pair_with)].append((s.root, s.path))

    out = {g.key: g for g in groups}
    for (root, ep_dir), rec_dirs in targets.items():
        rec_groups = [g for g in groups if (g.root, g.directory) in rec_dirs
                      and g.kind == "recording" and _takes_part(g)]
        ep_groups = [g for g in groups if g.root == root and g.directory == ep_dir
                     and g.kind == "behavior" and _takes_part(g)]
        for g in ep_groups:
            if g.precision != "second":
                out[g.key] = dataclasses.replace(
                    g, pairing=Pairing("date_only", note="a date-only session is never paired"),
                    notes=g.notes + (Note("pairing_date_only", "a date-only session is never "
                                          "paired"),))
        by_subject_r: dict[str, list[Group]] = defaultdict(list)
        by_subject_e: dict[str, list[Group]] = defaultdict(list)
        for g in rec_groups:
            by_subject_r[_pool_subject(g)].append(g)
        for g in ep_groups:
            if g.precision == "second":
                by_subject_e[_pool_subject(g)].append(g)
        for subject in sorted(set(by_subject_r) | set(by_subject_e)):
            rs = sorted(by_subject_r[subject], key=lambda g: g.key)
            es = sorted(by_subject_e[subject], key=lambda g: g.key)
            result = pair_subject(
                [Recording(g.key, wall_seconds(g.start_local), g.duration) for g in rs],
                [Session(g.key, wall_seconds(g.start_local)) for g in es])
            rec_of = {v: k for k, v in result.pair_of.items()}
            r_by_key = {g.key: g for g in rs}
            for g in rs:
                out[g.key] = _recording_outcome(g, result, r_by_key)
            for g in es:
                out[g.key] = _session_outcome(g, result, rec_of, r_by_key, rs)
    return tuple(out[g.key] for g in groups)


def _recording_outcome(g: Group, result: PairResult, r_by_key) -> Group:
    if g.key in result.short:
        p = Pairing("short", note="recording of %s s, shorter than %d s; not paired"
                    % (decimal_text(g.duration) or str(g.duration), MIN_RECORDING_S))
        code = "pairing_short"
    elif g.key in result.ambiguous_recordings:
        p = Pairing("ambiguous", note="ambiguous: candidate ePsych sessions " + _cands(result, g.key))
        code = "pairing_ambiguous"
    elif g.key in result.pair_of:
        e = result.pair_of[g.key]
        dt = dict(result.candidates[g.key])[e]
        p = Pairing("paired", e, dt, "paired with %s (%+d s)" % (e, dt))
        code = "pairing_paired"
    else:
        p = Pairing("unpaired", note="no ePsych session within the pairing window")
        code = "pairing_unpaired"
    return dataclasses.replace(g, pairing=p, notes=g.notes + (Note(code, p.note),))


def _session_outcome(g: Group, result: PairResult, rec_of, r_by_key, rs) -> Group:
    if g.key in result.ambiguous_sessions:
        note = "ambiguous: candidate recordings " + _cands(result, g.key)
        g = dataclasses.replace(g, pairing=Pairing("ambiguous", note=note),
                                notes=g.notes + (Note("pairing_ambiguous", note),))
        return _hold(g, Hold("pairing_ambiguous", note))
    if g.key in rec_of:
        r = r_by_key[rec_of[g.key]]
        dt = dict(result.candidates[g.key])[r.key]
        note = "paired with %s (%+d s)" % (r.key, dt)
        g = dataclasses.replace(g, pairing=Pairing("paired", r.key, dt, note),
                                notes=g.notes + (Note("pairing_paired", note),))
        if r.status != "ready":
            return _hold(g, Hold("paired_recording_held", "it pairs with %s, which is %s (%s)"
                                 % (r.key, r.status, r.hold.reason_code if r.hold else "")))
        return dataclasses.replace(g, session_path=r.session_path, label=r.label)
    t = wall_seconds(g.start_local)
    near_short = any(r.key in result.short and -MAX_LEAD_S <= t - wall_seconds(r.start_local)
                     <= MAX_LAG_S for r in rs)
    note = ("no recording of at least %d s within the pairing window" % MIN_RECORDING_S
            if near_short else "no recording folder within the pairing window")
    return dataclasses.replace(g, pairing=Pairing("unpaired", note=note),
                               notes=g.notes + (Note("pairing_unpaired", note),))


def _hold(g: Group, hold: Hold) -> Group:
    if g.status == "held":
        return dataclasses.replace(g, notes=g.notes + (Note(hold.reason_code,
                                                            "also: " + hold.sentence),))
    return dataclasses.replace(g, status="held", hold=hold)
