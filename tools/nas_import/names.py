"""The name grammar of ePsych session files and Intan recording folders.

Ported from ephys_analysis ``pipeline/findCopySessions.m`` and
``parseNameTokens.m`` / ``@EphysDataset/nameIdentity.m``, and extended to
the formats the plan lists:

* ePsych, to the second: ``<SUBJ>_<yyMMdd>T<HHmmss>[_<suffix>].mat``
  (findCopySessions line 198 knows only the form without a suffix);
* ePsych, date only: ``<SUBJ>_<dd-Mon-yyyy>[_A|_B].mat`` and
  ``<SUBJ>_<yyMMdd>.mat`` (not read by findCopySessions at all);
* Intan folder: ``<SUBJ>_<yyMMdd>_<HHmmss>`` (EphysDataset.DefaultNamePattern
  ``{SubjectID}_{Date:yyMMdd}_{Time:HHmmss}``).

``<SUBJ>`` is any run of characters without ``_`` or white space
(nameIdentity refuses a subject holding either). A suffix is one run of ASCII
letters and digits. Digits are ASCII only (``[0-9]``; MATLAB's ``\\d``).
Month abbreviations are English, ``Jan`` .. ``Dec`` exactly.

Validity of a date and time follows ``nameTime`` (findCopySessions lines
546-559): two-digit years are 2000 + yy, month 1-12, a day that exists in
that month, hour 0-23, minute and second 0-59. A four-digit year (the
``dd-Mon-yyyy`` form) must lie in 1990-2099.

A subject id that itself contains ``_`` cannot be named this way (the name
would not parse; such files are held ``unrecognised_name``): documented,
not handled.

Case: :func:`ascii_fold` is the one comparison "equal but for case" used
everywhere (subjects, twins, names in one folder). It folds the ASCII
letters A-Z only, so ``\u017f`` (long s) is not ``S``.

Every parser returns None when the name does not have the form, and raises
:class:`BadNameTime` when it has the form but an invalid date or time.
"""

from __future__ import annotations

import calendar
import datetime
import re
from dataclasses import dataclass

_SUBJ = r"(?P<subj>[^_\s]+)"
EPSYCH_SECOND = re.compile(_SUBJ + r"_(?P<d>[0-9]{6})T(?P<t>[0-9]{6})(?:_(?P<suffix>[A-Za-z0-9]+))?\.mat\Z")
EPSYCH_DMY = re.compile(_SUBJ + r"_(?P<day>[0-9]{2})-(?P<mon>[A-Z][a-z]{2})-(?P<year>[0-9]{4})"
                        r"(?:_(?P<ab>[AB]))?\.mat\Z")
EPSYCH_YMD = re.compile(_SUBJ + r"_(?P<d>[0-9]{6})\.mat\Z")
INTAN_FOLDER = re.compile(_SUBJ + r"_(?P<d>[0-9]{6})_(?P<t>[0-9]{6})\Z")

_MONTHS_EN = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
MONTHS = {m: i + 1 for i, m in enumerate(_MONTHS_EN)}


YEAR_MIN, YEAR_MAX = 1990, 2099
_FOLD = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def ascii_fold(text: str) -> str:
    """TEXT with the ASCII letters A-Z lowered and nothing else changed."""
    return text.translate(_FOLD)


class BadNameTime(ValueError):
    """The name has the form but holds an invalid date or time."""


@dataclass(frozen=True)
class EpsychName:
    """A parsed ePsych session file name.

    stamp       the date/time text as written (``260307T101500``,
                ``07-Mar-2026_A``, ``260307``): with the subject, the base stem
    suffix      the twin suffix (``psych``), or None
    """
    subject: str
    stamp: str
    suffix: str | None
    date: str                  # YYYY-MM-DD
    start_local: str | None    # YYYY-MM-DD HH:MM:SS, None when date only
    precision: str             # second | day
    form: str                  # second | dmy | ymd

    @property
    def base_stem(self) -> str:
        return self.subject + "_" + self.stamp


@dataclass(frozen=True)
class IntanName:
    subject: str
    date: str
    start_local: str


def _check_date(year: int, month: int, day: int) -> str:
    if not 1 <= month <= 12 or not 1 <= day <= calendar.monthrange(year, month)[1]:
        raise BadNameTime("%04d-%02d-%02d is not a date" % (year, month, day))
    return "%04d-%02d-%02d" % (year, month, day)


def _yymmdd(text: str) -> str:
    return _check_date(2000 + int(text[0:2]), int(text[2:4]), int(text[4:6]))


def _hhmmss(text: str) -> str:
    h, m, s = int(text[0:2]), int(text[2:4]), int(text[4:6])
    if h > 23 or m > 59 or s > 59:
        raise BadNameTime("%s is not a time of day" % text)
    return "%02d:%02d:%02d" % (h, m, s)


def parse_epsych(name: str) -> EpsychName | None:
    """Parse an ePsych .mat file name; None if it has none of the three forms."""
    m = EPSYCH_SECOND.match(name)
    if m:
        date = _yymmdd(m["d"])
        start = date + " " + _hhmmss(m["t"])
        return EpsychName(m["subj"], m["d"] + "T" + m["t"], m["suffix"], date, start, "second",
                          "second")
    m = EPSYCH_DMY.match(name)
    if m:
        if m["mon"] not in MONTHS:
            raise BadNameTime("%s is not a month" % m["mon"])
        if not YEAR_MIN <= int(m["year"]) <= YEAR_MAX:
            raise BadNameTime("the year %s is outside %d-%d" % (m["year"], YEAR_MIN, YEAR_MAX))
        date = _check_date(int(m["year"]), MONTHS[m["mon"]], int(m["day"]))
        stamp = "%s-%s-%s" % (m["day"], m["mon"], m["year"])
        if m["ab"]:
            stamp += "_" + m["ab"]
        return EpsychName(m["subj"], stamp, None, date, None, "day", "dmy")
    m = EPSYCH_YMD.match(name)
    if m:
        return EpsychName(m["subj"], m["d"], None, _yymmdd(m["d"]), None, "day", "ymd")
    return None


def parse_intan_folder(name: str) -> IntanName | None:
    """Parse an Intan recording folder name; None if it does not have the form."""
    m = INTAN_FOLDER.match(name)
    if not m:
        return None
    date = _yymmdd(m["d"])
    return IntanName(m["subj"], date, date + " " + _hhmmss(m["t"]))


def wall_seconds(local: str) -> int:
    """Whole seconds of a ``YYYY-MM-DD HH:MM:SS`` wall-clock text on a naive time line.

    Used only to compare two wall-clock times of one lab, as findCopySessions
    compares unzoned datetimes.
    """
    d = datetime.date(int(local[0:4]), int(local[5:7]), int(local[8:10]))
    return d.toordinal() * 86400 + int(local[11:13]) * 3600 + int(local[14:16]) * 60 + int(local[17:19])
