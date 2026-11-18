#!/usr/bin/env python3
"""Check that the toolboxes that record through +labclient call it as it is.

    python tests/check_consumers.py CHECKOUT [CHECKOUT ...]
    python tests/check_consumers.py --self-test

Each CHECKOUT is the folder of a toolbox that uses the labclient package (in
CI: fresh clones of the lab's toolboxes). Every .m file under it is read, and
every reference to the package in its code is compared with the package as it
is in THIS repository:

  * `labclient.Name` must be a class or a function of the package (also where
    it is written as a whole string, as in exist("labclient.DB", "class"));
  * `labclient.Class.member` must be a member of that class that code outside
    the class can use on the class itself: a Static method or a Constant
    property, not private, protected or hidden behind another Access;
  * a `Name=Value` argument of such a call (or of a constructor, or of a
    package function) must be an option the method declares in its
    `arguments` block, and a call cannot pass more arguments than the method
    takes.

Nothing is run: this reads text. It exists because the package and the
toolboxes are separate repositories, so a member renamed here fails nowhere
until a lab computer has both. It is not a test of behavior
(tests/matlab/LabClientTests.m and BackendContractTests.m are).

What it cannot see, and so does not check:
  * a method called on an OBJECT the package returned (`b =
    labclient.DB.connect(); b.subjects(f)`): the object's class is not known
    from the text. What a backend's methods give is BackendContractTests' to
    hold;
  * options passed the old way, as `"Name", value` pairs, and the names in a
    struct handed to a method;
  * a class or member named in a string that is built at run time, and the
    names of events;
  * whether a value is of the type the method asks for.
A method that takes `varargin` has its arguments left unchecked.

Exit status: 0 when every reference fits, 1 when one does not (each is
listed with its file and line), 2 for a wrong command line or a checkout that
is not a folder. A checkout with no reference to the package at all is a
warning, not an error: nothing of it was checked.
"""
import argparse
import glob
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PACKAGE = "labclient"

FLOW = ("if", "for", "while", "switch", "try", "parfor", "spmd")     # each closed by an `end`
BLOCKS = ("properties", "methods", "events", "enumeration")          # the blocks of a classdef
# what may come right before a quote that is a transpose, not the start of a char vector
BEFORE_TRANSPOSE = re.compile(r"[\w)\]}.'\"]")


# ---- reading MATLAB text ----------------------------------------------------------------------

def read_statements(path):
    """The statements of a MATLAB file as (line, code, strings).

    Comments are dropped, a statement continued with `...` is one statement
    (its line is where it starts), and the CONTENT of every string and char
    vector is blanked in `code` (the quotes stay), so that nothing inside a
    string reads as code; `strings` has the contents.
    """
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    statements = []
    in_block_comment = False
    pending = None          # [line, code, strings] of a statement being continued
    for number, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if in_block_comment:
            if stripped == "%}":
                in_block_comment = False
            continue
        if stripped == "%{":
            in_block_comment = True
            continue
        code, strings, continued = _strip_line(raw)
        if pending is None:
            pending = [number, code, strings]
        else:
            pending[1] += " " + code
            pending[2] += strings
        if not continued:
            if pending[1].strip():
                statements.append(tuple(pending))
            pending = None
    if pending is not None and pending[1].strip():
        statements.append(tuple(pending))
    return statements


def _strip_line(raw):
    """(code, strings, continued) of one line: no comment, string contents blanked."""
    out = []
    strings = []
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c == '"' or (c == "'" and not _is_transpose(out)):
            quote = c
            j = i + 1
            text = []
            while j < n:
                if raw[j] == quote:
                    if j + 1 < n and raw[j + 1] == quote:      # a doubled quote inside the string
                        text.append(quote)
                        j += 2
                        continue
                    break
                text.append(raw[j])
                j += 1
            strings.append("".join(text))
            out.append(quote + " " * max(j - i - 1, 0) + quote)
            i = j + 1
            continue
        if c == "%":
            break
        if raw.startswith("...", i):
            return "".join(out), strings, True     # what follows `...` is a comment
        out.append(c)
        i += 1
    return "".join(out), strings, False


def _is_transpose(out):
    """True when a quote here follows a value (a transpose), given the code so far."""
    text = "".join(out)
    return bool(text) and bool(BEFORE_TRANSPOSE.match(text[-1]))


def _without_brackets(code):
    """CODE with the text inside (), [] and {} removed, so an `end` used as an index is not a keyword."""
    previous = None
    while previous != code:
        previous = code
        code = re.sub(r"\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}", " ", code)
    return code


def _keywords(code, depth):
    """(openers, ends) counted in one statement that starts at nesting DEPTH.

    `methods`, `properties`, `events` and `arguments` are also the names of
    functions and variables, so each opens a block only where it can: the
    first three as a whole statement directly inside a classdef, `arguments`
    as a whole statement.
    """
    flat = _without_brackets(code)
    text = flat.strip()
    opened = len(re.findall(r"(?<![\w.])(?:%s)(?![\w.])" % "|".join(FLOW), flat))
    if re.match(r"(?:classdef|function)\b", text):
        opened += 1
    elif depth == 1 and re.match(r"(?:%s)\s*$" % "|".join(BLOCKS), text):
        opened += 1
    elif re.match(r"arguments\s*$", text):
        opened += 1
    ended = len(re.findall(r"(?<![\w.])end(?![\w.])", flat))
    return opened, ended


# ---- what the package offers --------------------------------------------------------------------

def read_package(folder):
    """{name: entry} for every class and function file of the package folder.

    A function's entry is {"kind": "function", "signature": ...}; a class's is
    {"kind": "class", "members": {name: member}} where a member has kind
    (method | property | event), static, constant, access and, for a method,
    its signature. A signature is {"positional": [names], "options": set of
    Name=Value names, "open": True when anything may be passed}.
    """
    package = {}
    for path in sorted(glob.glob(os.path.join(folder, "*.m"))):
        name = os.path.splitext(os.path.basename(path))[0]
        statements = read_statements(path)
        if not statements:
            continue
        if re.match(r"\s*classdef\b", statements[0][1]):
            package[name] = {"kind": "class", "members": _class_members(statements), "file": path}
        else:
            signature = None
            for k, (_, code, _) in enumerate(statements):
                if re.match(r"\s*function\b", code):
                    signature = _signature(statements, k)
                    break
            package[name] = {"kind": "function", "signature": signature, "file": path}
    return package


def _class_members(statements):
    members = {}
    depth = 0               # 1 inside the classdef, 2 inside one of its blocks, 3 inside a method
    block = None            # (kind, attributes) of the classdef block we are in
    for k, (line, code, _) in enumerate(statements):
        text = code.strip()
        opened, ended = _keywords(code, depth)
        header = re.match(r"(%s)\b\s*(?:\((.*)\))?\s*$" % "|".join(BLOCKS), text)
        if depth == 1 and header:
            block = (header.group(1), header.group(2) or "")
        elif depth == 2 and block:
            kind, attributes = block
            if kind == "methods":
                found = re.match(r"function\b\s*(?:(?:\[[^\]]*\]|\w+)\s*=\s*)?([A-Za-z]\w*)", text)
                if found:
                    members[found.group(1)] = {
                        "kind": "method", "line": line,
                        "static": _has(attributes, "Static"),
                        "constant": False,
                        "access": _access(attributes, ("Access",)),
                        "signature": _signature(statements, k)}
            elif kind in ("properties", "events"):
                found = re.match(r"([A-Za-z]\w*)\b", text)
                if found and found.group(1) != "end":
                    members.setdefault(found.group(1), {
                        "kind": "property" if kind == "properties" else "event", "line": line,
                        "static": False,
                        "constant": _has(attributes, "Constant"),
                        "access": _access(attributes, ("Access", "GetAccess")),
                        "signature": None})
        depth += opened - ended
        if depth < 2:
            block = None    # the block's own `end` closed it
    return members


def _has(attributes, word):
    """True when the attribute WORD is set in a block's attribute list (`Static`, `Static = true`)."""
    for part in attributes.split(","):
        name, _, value = part.partition("=")
        if name.strip() == word and value.strip().lower() != "false":
            return True
    return False


def _access(attributes, names):
    """public, or what restricts reading/calling (the value of Access / GetAccess)."""
    for part in attributes.split(","):
        name, _, value = part.partition("=")
        if name.strip() in names:
            value = value.strip().strip("'\" ")
            if value and value != "public":
                return value
    return "public"


def _signature(statements, k):
    """The arguments of the function declared in statement K: positional names and Name=Value options."""
    code = statements[k][1]
    found = re.match(r"\s*function\b\s*(?:(?:\[[^\]]*\]|\w+)\s*=\s*)?[A-Za-z][\w.]*\s*(?:\((.*)\))?\s*$", code)
    if not found:
        return {"positional": [], "options": set(), "open": True}
    names = [a.strip() for a in (found.group(1) or "").split(",") if a.strip()]
    signature = {"positional": [], "options": set(), "open": False}
    option_structs = set()
    j = k + 1
    while j < len(statements) and re.match(r"\s*arguments\b", statements[j][1]):
        output = re.match(r"\s*arguments\s*\(([^)]*)\)", statements[j][1])
        j += 1
        is_input = not (output and "Output" in output.group(1))
        if output and "Repeating" in output.group(1):
            signature["open"] = True
        while j < len(statements) and statements[j][1].strip() != "end":
            if is_input:
                entry = re.match(r"\s*([A-Za-z]\w*)(?:\.([A-Za-z]\w*))?", statements[j][1])
                if entry and entry.group(2):
                    option_structs.add(entry.group(1))
                    signature["options"].add(entry.group(2))
            j += 1
        j += 1
    for name in names:
        if name == "varargin":
            signature["open"] = True
        elif name not in option_structs:
            signature["positional"].append(name)
    return signature


# ---- what a toolbox uses ------------------------------------------------------------------------

REFERENCE = re.compile(r"(?<![\w.])%s\.([A-Za-z]\w*)(?:\.([A-Za-z]\w*))?" % PACKAGE)
WHOLE_STRING = re.compile(r"^%s\.([A-Za-z]\w*)$" % PACKAGE)


def check_file(path, package):
    """(references, problems) of one .m file; a problem is (line, reference, what)."""
    references = []
    problems = []
    for line, code, strings in read_statements(path):
        for text in strings:
            found = WHOLE_STRING.match(text.strip())
            if found:
                references.append("%s.%s" % (PACKAGE, found.group(1)))
                if found.group(1) not in package:
                    problems.append((line, "%s.%s" % (PACKAGE, found.group(1)),
                                     "named in a string: the package has no class or function of that name"))
        for found in REFERENCE.finditer(code):
            cls, member = found.group(1), found.group(2)
            ref = "%s.%s" % (PACKAGE, cls) + ("." + member if member else "")
            references.append(ref)
            entry = package.get(cls)
            if entry is None:
                problems.append((line, ref, "the package has no class or function %s" % cls))
                continue
            arguments = _call_arguments(code, found.end())
            if entry["kind"] == "function":
                if member:
                    problems.append((line, ref, "%s is a function, it has no members" % cls))
                elif arguments is not None:
                    problems += _check_call(line, ref, entry["signature"], arguments)
                continue
            if not member:
                constructor = entry["members"].get(cls)
                if arguments is not None and constructor and constructor["access"] == "public":
                    problems += _check_call(line, ref, constructor["signature"], arguments)
                elif arguments is not None and constructor:
                    problems.append((line, ref, "the constructor is %s: the class is not made this way"
                                     % constructor["access"]))
                continue
            m = entry["members"].get(member)
            if m is None:
                problems.append((line, ref, "%s has no member %s" % (cls, member)))
            elif m["access"] != "public":
                problems.append((line, ref, "%s is %s (Access): not for code outside the class"
                                 % (member, m["access"])))
            elif m["kind"] == "method" and not m["static"]:
                problems.append((line, ref, "%s is not a Static method: it cannot be called on the class" % member))
            elif m["kind"] == "property" and not m["constant"]:
                problems.append((line, ref, "%s is not a Constant property: it cannot be read on the class" % member))
            elif m["kind"] == "event":
                problems.append((line, ref, "%s is an event, not something to call or read" % member))
            elif m["kind"] == "method" and arguments is not None:
                problems += _check_call(line, ref, m["signature"], arguments)
    return references, problems


def _call_arguments(code, start):
    """The arguments of the call whose `(` follows position START, or None when it is not a call."""
    i = start
    while i < len(code) and code[i] == " ":
        i += 1
    if i >= len(code) or code[i] != "(":
        return None
    depth = 0
    arguments = []
    current = []
    for j in range(i, len(code)):
        c = code[j]
        if c in "([{":
            depth += 1
            if depth == 1:
                continue
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                arguments.append("".join(current))
                return [a for a in arguments if a.strip()]
        elif c == "," and depth == 1:
            arguments.append("".join(current))
            current = []
            continue
        current.append(c)
    return None             # the call does not close in this statement: not something to judge


def _check_call(line, ref, signature, arguments):
    """Problems of one call: options the method does not declare, more arguments than it takes."""
    if signature is None or signature["open"]:
        return []
    problems = []
    positional = 0
    named = []
    for a in arguments:
        option = re.match(r"\s*([A-Za-z]\w*)\s*=(?!=)", a)
        if option:
            named.append(option.group(1))
        else:
            positional += 1
    for name in named:
        if name not in signature["options"]:
            if signature["options"]:
                known = "it declares " + ", ".join(sorted(signature["options"]))
            else:
                known = "it declares no Name=Value options"
            problems.append((line, ref, "no option %s= (%s)" % (name, known)))
    limit = len(signature["positional"])
    # "Name", value pairs given the old way count as positional here and cannot be told apart,
    # so the count is only judged for a method that has no options at all
    if not signature["options"] and positional > limit:
        problems.append((line, ref, "%d arguments passed, it takes %d" % (positional, limit)))
    return problems


def check_checkout(folder, package):
    """(files with references, references, problems) of every .m file under FOLDER."""
    files = 0
    references = []
    problems = []
    for root, dirs, names in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        for name in sorted(names):
            if not name.endswith(".m"):
                continue
            path = os.path.join(root, name)
            refs, probs = check_file(path, package)
            if refs:
                files += 1
            references += refs
            problems += [(os.path.relpath(path, folder), line, ref, what) for line, ref, what in probs]
    return files, references, problems


# ---- command line -----------------------------------------------------------------------------

def _warn(text):
    if os.environ.get("GITHUB_ACTIONS"):
        print("::warning::" + text)
    else:
        print("warning: " + text)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("checkouts", nargs="*", help="folders of the toolboxes that use the package")
    parser.add_argument("--package", default=os.path.join(REPO, "+" + PACKAGE),
                        help="the package folder (default: this repository's)")
    parser.add_argument("--self-test", action="store_true", help="check this script against small made-up files")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.checkouts:
        parser.print_usage(sys.stderr)
        return 2
    if not os.path.isdir(args.package):
        print("check_consumers: %s is not a folder" % args.package, file=sys.stderr)
        return 2
    package = read_package(args.package)
    failed = False
    for folder in args.checkouts:
        if not os.path.isdir(folder):
            print("check_consumers: %s is not a folder" % folder, file=sys.stderr)
            return 2
        name = os.path.basename(os.path.abspath(folder))
        files, references, problems = check_checkout(folder, package)
        print("%s: %d references to %d names of %s in %d files, %d problems"
              % (name, len(references), len(set(references)), PACKAGE, files, len(problems)))
        if not references:
            _warn("%s has no reference to %s in its code: nothing of it was checked" % (name, PACKAGE))
        for path, line, ref, what in problems:
            failed = True
            print("  %s:%d: %s: %s" % (path, line, ref, what))
    return 1 if failed else 0


# ---- the check, checked ------------------------------------------------------------------------

SELF_TEST_CLASS = """classdef Thing
    % labclient.Thing  made up, for check_consumers.py --self-test
    properties (Constant)
        Limit = 3   % a constant, with a comment that names labclient.Nothing
    end
    properties (SetAccess = private)
        State = "x"
    end
    properties (Access = private)
        Secret
    end
    events
        Changed
    end
    methods (Static)
        function r = make(name, opts)
            arguments
                name (1,1) string
                opts.Size (1,1) double = 1
                opts.Kind (1,1) string = ""
            end
            r = name + opts.Size + opts.Kind;
            if r == "end"; r = name(end); end
        end
        function r = plain(a, b)
            r = [a, b];
        end
        function r = anything(varargin)
            r = varargin;
        end
    end
    methods
        function obj = Thing(grid, opts)
            arguments
                grid
                opts.Row (1,1) double = 1
            end
            obj.State = string(grid) + opts.Row;
        end
        function r = show(obj)
            r = obj.State;
        end
    end
    methods (Static, Access = private)
        function r = inner()
            r = 1;
        end
    end
end
"""

SELF_TEST_FUNCTION = """function h = digest(file, opts)
%digest  made up, for check_consumers.py --self-test
arguments
    file (1,1) string
    opts.Text (1,1) logical = false
end
h = file + opts.Text;
end
"""

# each line of the made-up toolbox: (code, what the check must say about it, or None for nothing)
SELF_TEST_USES = [
    ('a = labclient.Thing.make("n", Size=2, ...\n        Kind="k");', None),
    ("b = labclient.Thing.Limit;", None),
    ("c = labclient.Thing(grid, Row=2);", None),
    ('d = labclient.digest("f", Text=true);', None),
    ("e = labclient.Thing.plain(1, 2);", None),
    ('f = labclient.Thing.anything(1, 2, 3, Whatever=4);', None),
    ('g = exist("labclient.Thing", "class") == 8;   % labclient.Missing in a comment is nothing', None),
    ("h = x' + labclient.Thing.Limit';", None),
    ("i = labclient.Thing.make(\"labclient.Thing.nope(Size=1)\");", None),
    ("j = labclient.Missing.make();", "no class or function Missing"),
    ("k = labclient.Thing.nope();", "has no member nope"),
    ("l = labclient.Thing.inner();", "inner is private"),
    ('m = labclient.Thing.make("n", Colour=1);', "no option Colour="),
    ("n = labclient.Thing.plain(1, 2, 3);", "3 arguments passed, it takes 2"),
    ("o = labclient.Thing.show();", "show is not a Static method"),
    ("p = labclient.Thing.State;", "State is not a Constant property"),
    ("q = labclient.Thing.Secret;", "Secret is private"),
    ('r = isa(x, "labclient.Gone");', "named in a string"),
    ("s = labclient.Thing(grid, Column=2);", "no option Column="),
    ('t = labclient.digest("f", Binary=true);', "no option Binary="),
    ("u = labclient.Thing.Changed;", "Changed is an event"),
]


def self_test():
    """Run the check on made-up files and compare what it says with what it must say."""
    failures = []
    with tempfile.TemporaryDirectory() as top:
        package_dir = os.path.join(top, "+" + PACKAGE)
        os.makedirs(package_dir)
        with open(os.path.join(package_dir, "Thing.m"), "w", encoding="utf-8") as fh:
            fh.write(SELF_TEST_CLASS)
        with open(os.path.join(package_dir, "digest.m"), "w", encoding="utf-8") as fh:
            fh.write(SELF_TEST_FUNCTION)
        package = read_package(package_dir)
        members = package["Thing"]["members"]
        for name in ("Limit", "State", "Secret", "Changed", "make", "plain", "anything", "Thing", "show", "inner"):
            if name not in members:
                failures.append("the class's member %s was not read" % name)
        toolbox = os.path.join(top, "toolbox")
        os.makedirs(toolbox)
        for k, (code, expected) in enumerate(SELF_TEST_USES):
            path = os.path.join(toolbox, "use%02d.m" % k)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("function use%02d()\n%s\nend\n" % (k, code))
            _, problems = check_file(path, package)
            said = "; ".join(what for _, _, what in problems)
            if expected is None and problems:
                failures.append("%s\n    should pass, but: %s" % (code, said))
            elif expected is not None and not any(expected in what for _, _, what in problems):
                failures.append("%s\n    should say \"%s\", but said: %s" % (code, expected, said or "nothing"))
            elif expected is not None and len(problems) != 1:
                failures.append("%s\n    should say one thing, but said: %s" % (code, said))
        block = os.path.join(toolbox, "blockcomment.m")
        with open(block, "w", encoding="utf-8") as fh:
            fh.write("function blockcomment()\n%{\nlabclient.Missing.make();\n%}\nx = 1;\nend\n")
        if check_file(block, package)[1]:
            failures.append("a reference inside a %{ %} comment was judged")
    for text in failures:
        print("self-test FAILED: " + text)
    if failures:
        return 1
    print("check_consumers self-test: %d made-up uses judged as they should be" % len(SELF_TEST_USES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
