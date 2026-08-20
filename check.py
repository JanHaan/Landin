#!/usr/bin/env python3
"""
Mechanical checks over the tour and the prototypes.

Not a compiler and not a parser — a set of cheap invariants that caught
most of the defects found between 0.0.14 and 0.1.0, and that are tedious
to re-check by hand after every edit. Run it after touching any of
the language files; it resolves them next to itself, so it works from
anywhere.

    python3 check.py            # all files
    python3 check.py FILE...    # only these
"""
import collections
import io
import os
import re
import sys

FILES = ["tour.txt", "prototype-1-driver.txt", "prototype-2-parser.txt",
         "prototype-3-containers.txt", "prototype-4-app.txt"]

#  Every word the language reserves. Kept here rather than imported from
#  build_tour.py because the highlighter's set is about colour and this
#  one is about legality, and they have drifted apart before.
KEYWORDS = set("""
type struct variant concept is end if then elsif else while do for in loop
break continue when complete match defer undo begin unchecked return fail try
with from and or not mut public ptr addr sizeof alignof lenof inc dec atom
distinct range layout volatile big little escaping caller align link at of
fixed option extern import as any none noreturn zeroed true false sink inout
set register arena
""".split())

#  Spellings that a decision retired. Anything still using one is stale.
RETIRED = {
    "used_mut":        "0.1.0 collapsed the two accessors into one",
    "for inout ":      "0.1.0: the slice type says whether an element is writable",
    "fixed assert":    "0.0.14: it is compiler.assert, a builtin call",
    "arena_new":       "0.0.12: allocation is mem.new",
    "arena_slice":     "0.0.12: allocation is mem.new_slice",
    "sink_of":         "0.0.16: the diagnostics log is a concept",
    "diag.report":     "0.0.16: it is an entry, reached as d.note",
    "io.handle":       "0.0.16: it is a concept, any io.world",
    "sys/io":          "0.0.16: Io lives in core, which is the standard library",
}

BLOCK_ENDS = {"if", "while", "for", "loop", "match", "unchecked", "variant"}


def sections(lines):
    """Split a file into (kind, first_line, lines).

    Three kinds are read differently: 'code' is checked, 'findings' and
    'changelog' quote the wording a decision retired and are not.
    """
    kind, start, buf = "code", 1, []
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if s.startswith("WHAT WAS TRIED AND DROPPED"):
            yield kind, start, buf
            kind, start, buf = "changelog", n, []
        elif re.match(r"^\[[XYZW]\]", s) or s.startswith("WHAT THIS ONE FOUND") \
                or s.startswith("WHERE THE SPECIFICATION WAS SILENT"):
            yield kind, start, buf
            kind, start, buf = "findings", n, []
        buf.append(line)
    yield kind, start, buf


def module_banner(line):
    """A module header inside a prototype: names may repeat across them."""
    return re.match(r"^[a-z][a-z0-9_/]*(?:  —|\s*$)", line) and "/" in line


def looks_like_code(line):
    """Prose and code share these files, and no parser is available."""
    s = line.strip()
    if not s or s.startswith("--") or s.startswith("=") or s.startswith("["):
        return False
    if re.match(r"^[XYZW]\d", s):            # a findings entry
        return False
    if re.match(r"^[A-Z]", s) or s.endswith("."):   # a sentence
        return False
    #  A statement need not contain ':', '=' or '(' — 'inc n', 'break',
    #  'return' and friends do not, and skipping them was a hole.
    if re.match(r"^(inc|dec|break|continue|return|fail|try|defer|undo|_)\b", s):
        return True
    return bool(re.search(r"[:=(]|^end\b", s))


def check(path):
    text = io.open(path, encoding="utf-8").read()
    all_lines = text.split("\n")
    #  Only the code section is checked. Findings and the changelog quote
    #  the wording that decisions retired, on purpose.
    lines, offset = [], 0
    for kind, start, chunk in sections(all_lines):
        if kind == "code":
            lines = chunk
            offset = start - 1
            break
    out = []

    #  1. a reserved word standing where a name belongs
    for n, line in enumerate(lines, 1):
        if not looks_like_code(line):
            continue
        for m in re.finditer(
                r"(?:^|[(,]|\bmut\s+|\bpublic\s+)\s*([a-z_][a-z0-9_]*)\s*(?::=|:)", line):
            word = m.group(1)
            if word in KEYWORDS and word != "ptr":
                out.append((n, "%r is a keyword and cannot be a name" % word))

    #  2. 'when' rides only on an exit statement
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not looks_like_code(line) or " when " not in s:
            continue
        if not re.match(r"^(break|continue|return|fail)\b", s):
            out.append((n, "'when' outside an exit statement"))

    #  3. a convention marker at a call site, removed at 0.0.10
    for n, line in enumerate(lines, 1):
        if not looks_like_code(line):
            continue
        if re.search(r"[a-z_][a-z0-9_.]*\(\s*(?:inout|sink)\s+[a-z_]", line):
            out.append((n, "convention marker at a call site"))

    #  4. spellings a decision retired
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith(("--", "X", "Y", "Z", "W")):
            continue      # findings quote the wording that was wrong
        for dead, why in RETIRED.items():
            if dead in line:
                out.append((n, "%r is retired — %s" % (dead, why)))

    #  5. two declarations of one name in one module
    #  Names may repeat across the modules a prototype file contains.
    module = 0
    seen, where = collections.Counter(), collections.defaultdict(list)
    for n, line in enumerate(lines, 1):
        if module_banner(line):
            module += 1
        if line.startswith((" ", "\t", "-", "=")) or not line.strip():
            continue
        m = re.match(r"^(?:public\s+|mut\s+|extern\([a-z]+\)\s+|link\([^)]*\)\s+)*"
                     r"([a-z_][a-z0-9_]*)\s*:", line)
        if m:
            key = (module, m.group(1))
            seen[key] += 1
            where[key].append(n)
    for (mod, name), count in seen.items():
        if count > 1:
            out.append((where[(mod, name)][1], "%r declared %d times, also at %s"
                        % (name, count, where[(mod, name)][0])))

    #  6. 'end NAME' with no opener of that name anywhere in the file
    openers = set()
    for line in lines:
        s = line.strip()
        if s.startswith("--"):
            continue
        m = re.match(r"^(?:public\s+|mut\s+|extern\([a-z]+\)\s+|link\([^)]*\)\s+"
                     r"|\([^)]*\)\s+)*([a-z_][a-z0-9_]*)\s*:", s)
        if m:
            openers.add(m.group(1))
        m = re.match(r"^arena\s+([a-z_][a-z0-9_]*)\s+do", s)
        if m:
            openers.add(m.group(1))
        openers.update(re.findall(r"\b([a-z_][a-z0-9_]*)\s*\(", s))
        openers.update(re.findall(r"\.([a-z_][a-z0-9_]*)\s*\(", s))
    for n, line in enumerate(lines, 1):
        m = re.match(r"^end\s+([a-z_][a-z0-9_]*)\s*$", line.strip())
        if m and m.group(1) not in BLOCK_ENDS and m.group(1) not in openers:
            out.append((n, "'end %s' closes nothing of that name" % m.group(1)))

    return [(n + offset, why) for n, why in out]


def check_citations(paths):
    """Every [NNN] pointing at a construct the tour does not define."""
    tour = io.open("tour.txt", encoding="utf-8").read()
    defined = set(re.findall(r"^\s*(?:--\(|---|--) \[(\d{4})\]", tour, re.M))
    out = []
    for path in paths:
        text = io.open(path, encoding="utf-8").read()
        for m in re.finditer(r"(?<![\w])\[(\d{4})\](?![A-Za-z_0-9])", text):
            if m.group(1) not in defined:
                out.append((path, "[%s] is cited and not defined" % m.group(1)))
    return sorted(set(out))


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    if here:
        os.chdir(here)
    paths = argv[1:] or FILES
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        print("not found next to check.py: %s" % ", ".join(missing))
        return 2

    total = 0
    for path in paths:
        problems = check(path)
        total += len(problems)
        print("%-30s %s" % (path, "clean" if not problems else
                            "%d problem(s)" % len(problems)))
        for line, why in sorted(problems):
            print("    %5d  %s" % (line, why))

    if "tour.txt" in paths:
        for path, why in check_citations(paths):
            total += 1
            print("%-30s %s" % (path, why))

    print("\n%s" % ("all clean" if not total else "%d problem(s)" % total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
