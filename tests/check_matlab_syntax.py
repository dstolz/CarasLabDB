#!/usr/bin/env python3
"""Syntax-check every MATLAB file in the repository with GNU Octave.

    python tests/check_matlab_syntax.py          # needs octave-cli on PATH

CI has no MATLAB, and Octave cannot run this code: it has no string type,
datetime, table, Database Toolbox, uifigure components or matlab.unittest.
What Octave can do is parse, so this is a syntax check and nothing more: it
catches an unbalanced parenthesis, a malformed statement or a stray token in
any file at the repository root or under @CarasLabDB/, @CarasLabDBApp/,
tests/matlab/ and examples/.
It does not check that the code works. design_docs/matlab-first-run-checklist.md
is the list of things that must be checked in MATLAB itself.

Octave's parser rejects four things that are valid MATLAB, so the files are
copied to a temporary folder and rewritten there, line for line, before they
are parsed (the repository is not touched, and line numbers are kept):

  * `arguments` blocks are blanked out. Their contents are therefore NOT
    checked.
  * A typed property declaration (`Name (1,1) string = "x"`) is reduced to
    `Name = "x"`.
  * Backslashes inside double-quoted literals are doubled, because Octave
    reads escape sequences there and would take `"\"` for an unterminated
    string.
  * A `Name=Value` call argument is rewritten as `"Name", Value`, which
    Octave cannot parse inside an anonymous function.

Known blind spots: a missing `end` inside a classdef file is not reliably
reported (Octave reads the keywords that follow as ordinary calls), and
anything inside an `arguments` block.

Exit status: 0 when every file parses, 1 on a syntax error, 2 when Octave is
not installed.
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PATTERNS = ("*.m", "@CarasLabDB/*.m", "@CarasLabDBApp/*.m", "tests/*.m", "tests/matlab/*.m",
            "tests/matlab/*/*.m", "examples/*.m")

ARGUMENTS = re.compile(r"^\s*arguments\s*(\([A-Za-z, ]*\))?\s*(%.*)?$")
BLOCK_END = re.compile(r"^\s*end\s*(%.*)?$")
PROPERTIES = re.compile(r"^\s*properties\b")
TYPED_PROPERTY = re.compile(
    r"^(\s*)([A-Za-z]\w*)\s+(\([^)]*\)\s*)?([A-Za-z][\w.]*)?\s*(\{[^}]*\}\s*)?(=.*)?$")
NAME_VALUE = re.compile(r"([A-Z][A-Za-z0-9]*)=(?!=)")
# A quote directly after one of these is a transpose, not the start of a literal.
BEFORE_TRANSPOSE = re.compile(r"[\w\)\]\}\.'\"]")


def rewrite_line(line, depth, last_sig):
    """One line rewritten for Octave's parser.

    DEPTH is the bracket depth and LAST_SIG the last significant character,
    both carried over a `...` continuation. Returns (text, depth, last_sig,
    continues)."""
    out = []
    i, n, prev = 0, len(line), ""
    while i < n:
        c = line[i]
        if c == '"':                                  # string literal
            j = i + 1
            buf = ['"']
            while j < n:
                if line[j] == '"':
                    if j + 1 < n and line[j + 1] == '"':
                        buf.append('""')
                        j += 2
                        continue
                    break
                buf.append("\\\\" if line[j] == "\\" else line[j])
                j += 1
            buf.append('"')
            out.append("".join(buf))
            i = j + 1
            prev = last_sig = '"'
            continue
        if c == "'" and not BEFORE_TRANSPOSE.match(prev or " "):   # char literal
            j = i + 1
            while j < n:
                if line[j] == "'":
                    if j + 1 < n and line[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            out.append(line[i:j + 1])
            i = j + 1
            prev = last_sig = "'"
            continue
        if c == "%":                                  # comment to end of line
            out.append(line[i:])
            break
        if line.startswith("...", i):                 # continuation
            out.append(line[i:])
            return "".join(out), depth, last_sig, True
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if depth > 0 and c.isalpha() and last_sig in ("(", ","):
            m = NAME_VALUE.match(line, i)
            if m:
                out.append('"%s", ' % m.group(1))
                i = m.end()
                prev = last_sig = ","
                continue
        out.append(c)
        if not c.isspace():
            prev = last_sig = c
        i += 1
    return "".join(out), depth, last_sig, False


def rewrite_file(text):
    lines = text.split("\n")
    out = []
    i = 0
    in_properties = False
    depth, last_sig = 0, ""
    while i < len(lines):
        line = lines[i]
        if ARGUMENTS.match(line):
            j = i + 1
            while j < len(lines) and not BLOCK_END.match(lines[j]):
                j += 1
            out.extend([""] * (j - i + 1))            # keep line numbers
            i = j + 1
            continue
        if PROPERTIES.match(line):
            in_properties = True
            out.append(line)
            i += 1
            continue
        if in_properties:
            if BLOCK_END.match(line):
                in_properties = False
                out.append(line)
                i += 1
                continue
            m = TYPED_PROPERTY.match(line.split("%")[0].rstrip())
            if m and (m.group(3) or m.group(4) or m.group(5)):
                default, _, _, _ = rewrite_line(m.group(6) or "", 0, "")
                out.append("%s%s %s" % (m.group(1), m.group(2), default))
                i += 1
                continue
        fixed, depth, last_sig, continues = rewrite_line(line, depth, last_sig)
        if not continues:
            depth, last_sig = 0, ""
        out.append(fixed)
        i += 1
    return "\n".join(out)


def main():
    octave = shutil.which("octave-cli") or shutil.which("octave")
    if octave is None:
        print("check_matlab_syntax: octave-cli is not installed", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as tmp:
        count = 0
        for pattern in PATTERNS:
            for path in glob.glob(os.path.join(REPO, pattern)):
                target = os.path.join(tmp, os.path.relpath(path, REPO))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
                with open(target, "w", encoding="utf-8") as fh:
                    fh.write(rewrite_file(text))
                count += 1
        if count == 0:
            print("check_matlab_syntax: no MATLAB files found", file=sys.stderr)
            return 1
        env = dict(os.environ)
        env.pop("JAVA_TOOL_OPTIONS", None)            # keeps the JVM banner out of the output
        cmd = [octave, "--quiet", "--no-gui", "--path", os.path.join(HERE, "octave"),
               "--eval", "check_syntax('%s')" % tmp.replace("'", "''")]
        # Run inside the copy: Octave looks for @-folders in the current
        # directory first, and from the repository root it would load the
        # original class files instead of the rewritten ones.
        return subprocess.run(cmd, env=env, cwd=tmp).returncode


if __name__ == "__main__":
    sys.exit(main())
