#!/usr/bin/env python3
"""Write the MAT fixtures of tests/check_nas_import_parsing.py with scipy.

An independent writer for tools/nas_import/mat5.py: the files are made by
scipy.io.savemat, not by anything in this repository, and expected.json
records what scipy was asked to write (names, classes, dimensions), not
what the reader reads. scipy is needed only to regenerate them:

    python -m venv /tmp/matvenv && /tmp/matvenv/bin/pip install scipy
    /tmp/matvenv/bin/python tests/testdata/nas_import/make_mat_fixtures.py

The check itself needs no scipy. Re-running changes the files' bytes (the
header text holds the creation time) but not expected.json.
"""
import json
import os

import numpy as np
import scipy
from scipy.io import savemat

HERE = os.path.dirname(os.path.abspath(__file__))


def trials(shape):
    """An ePsych-like Data struct array of SHAPE (one element per trial)."""
    dt = [("TrialID", "O"), ("ResponseCode", "O"), ("ComputerTimestamp", "O")]
    data = np.zeros(shape, dtype=dt)
    for k, idx in enumerate(np.ndindex(*shape)):
        data[idx]["TrialID"] = np.array([[k + 1]], dtype=float)
        data[idx]["ResponseCode"] = np.array([[k * 3 % 7]], dtype=np.uint16)
        data[idx]["ComputerTimestamp"] = np.array([[738000.5 + k]], dtype=float)
    return data


def info():
    dt = [("Subject", "O"), ("StartTime", "O"), ("FormatVersion", "O")]
    s = np.zeros((1, 1), dtype=dt)
    s[0, 0]["Subject"] = "SUBJ-ID-1255"
    s[0, 0]["StartTime"] = np.array([[739000.25]])
    s[0, 0]["FormatVersion"] = np.array([[2.0]])
    return s


FIXTURES = {
    # name: (variables in order, compressed); each variable (name, value, class, dims)
    "epsych_n0_z.mat": ([("Data", trials((1, 0)), "struct", [1, 0]), ("Info", info(), "struct", [1, 1])], True),
    "epsych_n1_z.mat": ([("Data", trials((1, 1)), "struct", [1, 1]), ("Info", info(), "struct", [1, 1])], True),
    "epsych_n5_z.mat": ([("Data", trials((1, 5)), "struct", [1, 5]), ("Info", info(), "struct", [1, 1])], True),
    "epsych_n0_u.mat": ([("Data", trials((1, 0)), "struct", [1, 0]), ("Info", info(), "struct", [1, 1])], False),
    "epsych_n3_u.mat": ([("Data", trials((1, 3)), "struct", [1, 3]), ("Info", info(), "struct", [1, 1])], False),
    "epsych_2x3_z.mat": ([("Data", trials((2, 3)), "struct", [2, 3]), ("Info", info(), "struct", [1, 1])], True),
    "epsych_other_first_z.mat": ([("Aardvark", np.arange(12.0).reshape(3, 4), "double", [3, 4]),
                                  ("note", "a char row", "char", [1, 10]),
                                  ("Data", trials((1, 4)), "struct", [1, 4]),
                                  ("Info", info(), "struct", [1, 1])], True),
    "epsych_other_first_u.mat": ([("Aardvark", np.arange(12.0).reshape(3, 4), "double", [3, 4]),
                                  ("Data", trials((1, 2)), "struct", [1, 2]),
                                  ("Info", info(), "struct", [1, 1])], False),
    "no_info_z.mat": ([("Data", trials((1, 2)), "struct", [1, 2])], True),
    "no_variables_u.mat": ([], False),
}


def main():
    expected = {"writer": "scipy.io.savemat (scipy %s)" % scipy.__version__, "files": {}}
    for name, (variables, compressed) in FIXTURES.items():
        mdict = {v[0]: v[1] for v in variables}
        savemat(os.path.join(HERE, name), mdict, do_compression=compressed, format="5",
                oned_as="row")
        expected["files"][name] = [[v[0], v[2], v[3]] for v in variables]
    # A MAT v4 file (no MAT 5.0 header): the reader must say so.
    savemat(os.path.join(HERE, "v4.mat"), {"Data": np.arange(3.0)}, format="4")
    expected["files"]["v4.mat"] = "mat_not_mat5"
    with open(os.path.join(HERE, "expected.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(expected, fh, indent=1, sort_keys=True)
        fh.write("\n")


if __name__ == "__main__":
    main()
