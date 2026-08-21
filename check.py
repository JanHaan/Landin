#!/usr/bin/env python3
"""
Mechanical checks over the tour, roadmap, and prototypes.

Not a compiler, parser, or roadmap executor — a set of cheap invariants
that caught most of the defects found between 0.0.14 and 0.1.0, and that
are tedious to re-check by hand after every edit. It resolves files next
to itself, so it works from anywhere.

    python3 check.py            # all files
    python3 check.py FILE...    # only these
"""
import collections
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

LANGUAGE_FILES = ["tour.txt", "prototype-1-driver.txt",
                  "prototype-2-parser.txt", "prototype-3-containers.txt",
                  "prototype-4-app.txt"]
ROADMAP = "ROADMAP.md"
FILES = LANGUAGE_FILES + [ROADMAP]
LIVE_DOCS = FILES + ["AGENTS.md", "README.md", "handoff.md",
                     "docs/environments.md",
                     "docs/agents/issue-tracker.md",
                     "docs/agents/triage-labels.md",
                     "docs/agents/domain.md",
                     "compiler/ada/README.md",
                     "compiler/ada/TOOLCHAIN.md",
                     "compiler/tests/README.md",
                     "compiler/tests/harness-cases/README.md",
                     "docs/site/README.md"]

#  Every word the language reserves. Kept here rather than imported from
#  docs/site/render_html.py because the highlighter's set is about colour
#  and this one is about legality, and they have drifted apart before.
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
GRAMMAR_BANNER = "THE GRAMMAR OF THE ENABLED KERNEL"
ROADMAP_PHASE = re.compile(r"^## (R[0-7]) — \S.*$")
ROADMAP_WORK = re.compile(r"^### (R[0-7]\.([1-9]\d*)) — (\S.*)$")
ROADMAP_GATE = re.compile(r"^### (R[0-7]) gate$")
ROADMAP_STATUS = re.compile(r"^Status: (planned|active|blocked|complete)$")
ROADMAP_DEPENDS = re.compile(
    r"^Depends on: (none|R[0-7]\.[1-9]\d*(?:, R[0-7]\.[1-9]\d*)*)$")
ROADMAP_REFERENCE = re.compile(r"R[0-7]\.[1-9]\d*")
ROADMAP_REFERENCE_CANDIDATE = re.compile(
    r"(?<![A-Za-z0-9_.])(R\d+\.\d+)(?![A-Za-z0-9_.])")
MIGRATION_HEADING = "## Inherited review register and migration parity"
MIGRATION_ROW = re.compile(
    r"^\| ([A-Z]\d+) — ([^|]+) \| ([^|]+) \| ([^|]+) \|$")
LEGACY_IDS = (["A%d" % n for n in range(1, 9)] +
              ["B%d" % n for n in range(1, 7)] +
              ["C%d" % n for n in range(1, 7)] +
              ["D%d" % n for n in range(1, 7)] +
              ["E%d" % n for n in range(1, 4)] +
              ["F%d" % n for n in range(1, 4)])
LEGACY_REQUIRED_ANCHORS = {
    "A1": ("H§P0.1", "`R` bottom line"),
    "A2": ("[0510]", "Z8", "R§2", "H§4"),
    "A3": ("no tracked citation",),
    "A4": ("R§6",),
    "A5": ("[0310]", "[0430]", "[0470]", "[0770]", "[0910]",
           "[1120]", "[1720]", "R§4", "H§5"),
    "A6": ("[0550]", "[1280]"),
    "A7": ("[1310]", "R§12"),
    "A8": ("R§P1.5",),
    "B1": ("R§5",),
    "B2": ("R§9", "R§10"),
    "B3": ("R§12",),
    "B4": ("R§13",),
    "B5": ("no tracked citation",),
    "B6": ("[1480]",),
    "C1": ("[0910]", "R§3", "H§3"),
    "C2": ("no tracked citation",),
    "C3": ("[1680]",),
    "C4": ("no trigger or citation",),
    "C5": ("[0620]",),
    "C6": ("[1120]", "[1720]", "H§5"),
    "D1": ("[0610]",),
    "D2": ("[1280]", "R§11"),
    "D3": ("[1540]",),
    "D4": ("[0790]", "[0900]"),
    "D5": ("HANDOFF.md", "[1550]"),
    "D6": ("[1470]",),
    "E1": ("Y4", "Z15"),
    "E2": ("[1260]", "W4"),
    "E3": ("no independent citation",),
    "F1": ("R§P0.8", "definition of success"),
    "F2": ("no citation",),
    "F3": ("[1310]",),
}
MIGRATION_OWNER_NAMES = (
    "Scale and self-hosting", "Companion tool and ecosystem",
    "Broader standard library", "Competitive optimization",
    "Language evolution", "Release readiness", "Roadmap-wide process",
)
PROTOTYPE_FINDINGS = {
    "X": "prototype-1-driver.txt",
    "Y": "prototype-2-parser.txt",
    "Z": "prototype-3-containers.txt",
    "W": "prototype-4-app.txt",
}
STALE_BACKLOG_ALLOWLIST = {
    ("prototype-3-containers.txt",
     "--- other thing, and they are parked with a condition in BACKLOG.md."),
    ("prototype-4-app.txt",
     "--- other thing, and they are parked with a condition in BACKLOG.md. And"),
}


def sections(lines):
    """Split a file into (kind, first_line, lines).

    Four kinds are read differently. 'code' is checked. 'findings' and
    'changelog' quote the wording a decision retired, on purpose. 'grammar'
    is notation rather than Landin: a production reads 'type ::= ...', which
    the keyword rule would otherwise report as a keyword standing where a
    name belongs, and a nonterminal may share a name with a function the
    tour declares elsewhere.
    """
    kind, start, buf = "code", 1, []
    ruled = False
    for n, line in enumerate(lines, 1):
        s = line.strip()
        banner = ruled and re.match(r"^[A-Z][A-Z ,'-]+$", s)
        if s.startswith("WHAT WAS TRIED AND DROPPED"):
            yield kind, start, buf
            kind, start, buf = "changelog", n, []
        elif s.startswith(GRAMMAR_BANNER):
            yield kind, start, buf
            kind, start, buf = "grammar", n, []
        elif banner and kind == "grammar":
            yield kind, start, buf
            kind, start, buf = "code", n, []
        elif re.match(r"^\[[XYZW]\]", s) or s.startswith("WHAT THIS ONE FOUND") \
                or s.startswith("WHERE THE SPECIFICATION WAS SILENT"):
            yield kind, start, buf
            kind, start, buf = "findings", n, []
        ruled = bool(re.match(r"^-{60,}$", s))
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
    chunks = [(start - 1, chunk) for kind, start, chunk in sections(all_lines)
              if kind == "code"]
    out = []
    for offset, lines in chunks:
        out += check_code(lines, offset)
    return sorted(set(out))


def check_code(lines, offset):
    """The six cheap rules, over one stretch of code."""
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


# --------------------------------------------------------------------------
#  the grammar
#
#  tour.txt's grammar section is normative, and two rounds of reading it by
#  hand found sixty-eight defects between them: a grammar argued over is a
#  grammar that keeps being wrong in a new place.  So it is checked instead.
#
#  What is checked: every rule is defined and reachable, the notation uses
#  only forms the notation paragraph describes, and -- the part that earns
#  its keep -- every program a positive fixture carries is recognised by the
#  productions, and every syntax negative is not.  The first draft claimed a
#  token layer that made `mut x: u8` underivable; this catches that in a
#  second rather than in a review.
# --------------------------------------------------------------------------

#  Rules the tokeniser owns.  The recogniser treats each as one token and
#  does not expand it, because they read bytes rather than tokens.
LEXICAL_RULES = {"space", "line_end", "comment", "line_comment",
                 "doc_comment", "block_comment", "block_item", "identifier",
                 "keyword", "literal", "integer", "decimal", "hex", "octal",
                 "binary", "lower", "digit", "hex_digit", "octal_digit",
                 "binary_digit"}

#  Rule names the recogniser matches against a token kind rather than a
#  spelling.
TOKEN_KIND_RULES = {"identifier": "name", "integer": "integer",
                    "literal": "literal"}

PRODUCTION = re.compile(r"^([a-z_]+)\s+::=\s*(.*)$")
NOTATION_WORD = re.compile(
    r'\s*("(?:[^"\\]|\\.)*"'
    r'|any byte(?: that begins neither "[^"]*" nor "[^"]*")?'
    r'(?: except [a-z_]+)?'
    r'|\.\.\.'
    r'|[a-z_]+'
    r'|[()|?*+])'
)


def grammar_section(text):
    """The lines of the grammar section, or None when there is not one."""
    lines = text.split("\n")
    for n, line in enumerate(lines):
        if line.strip() == GRAMMAR_BANNER:
            for m in range(n + 2, len(lines)):
                if re.match(r"^-{60,}$", lines[m]) and m + 1 < len(lines) \
                        and re.match(r"^[A-Z][A-Z ,'-]+$", lines[m + 1].strip()):
                    return n, lines[n:m]
            return n, lines[n:]
    return None, None


def grammar_rules(section):
    """Rule name -> right-hand side, joining continuation lines."""
    rules, order, problems = {}, [], []
    current = None
    for n, line in enumerate(section, 1):
        found = PRODUCTION.match(line)
        if found:
            name, rest = found.group(1), found.group(2)
            if name in rules:
                problems.append((n, "grammar rule %r is defined twice" % name))
            rules[name] = rest
            order.append((name, n))
            current = name
        elif current and re.match(r"^\s{2,}\S", line) \
                and "::=" not in line and not line.lstrip().startswith("--"):
            rules[current] += " " + line.strip()
        else:
            current = None
    return rules, order, problems


def unescape(text):
    """A terminal spells bytes, so '\\t' in one is a tab."""
    for written, byte in (("\\t", "\t"), ("\\n", "\n"), ("\\r", "\r"),
                          ('\\"', '"'), ("\\\\", "\\")):
        text = text.replace(written, byte)
    return text


class Notation:
    """One right-hand side, read into alternatives of items."""

    def __init__(self, name, text):
        self.name = name
        self.words = []
        rest = text
        while rest.strip():
            found = NOTATION_WORD.match(rest)
            if not found:
                raise ValueError("cannot read %r" % rest.strip()[:40])
            self.words.append(found.group(1))
            rest = rest[found.end():]
        self.at = 0

    def parse(self):
        node = self.alternation()
        if self.at != len(self.words):
            raise ValueError("trailing %r"
                             % " ".join(self.words[self.at:])[:40])
        return node

    def alternation(self):
        arms = [self.sequence()]
        while self.at < len(self.words) and self.words[self.at] == "|":
            self.at += 1
            arms.append(self.sequence())
        return ("alt", arms) if len(arms) > 1 else arms[0]

    def sequence(self):
        items = []
        while self.at < len(self.words) \
                and self.words[self.at] not in ("|", ")"):
            items.append(self.item())
        if not items:
            raise ValueError("an empty alternative")
        return ("seq", items)

    def item(self):
        word = self.words[self.at]
        if word == "(":
            self.at += 1
            atom = self.alternation()
            if self.at >= len(self.words) or self.words[self.at] != ")":
                raise ValueError("an unclosed group")
            self.at += 1
        elif word.startswith('"'):
            self.at += 1
            atom = ("lit", unescape(word[1:-1]))
            #  '"a" ... "z"' is a byte range, which the lexical layer reads.
            if self.at + 1 < len(self.words) and self.words[self.at] == "...":
                upper = self.words[self.at + 1]
                self.at += 2
                atom = ("range", word[1:-1], upper[1:-1])
        elif word.startswith("any byte"):
            self.at += 1
            atom = ("byte", None)
        else:
            self.at += 1
            atom = ("rule", word)

        while self.at < len(self.words) and self.words[self.at] in "?*+":
            atom = (self.words[self.at], atom)
            self.at += 1
        return atom


def grammar_uses(node, into):
    kind = node[0]
    if kind == "rule":
        into.add(node[1])
    elif kind in ("alt", "seq"):
        for child in node[1]:
            grammar_uses(child, into)
    elif kind in ("?", "*", "+"):
        grammar_uses(node[1], into)


def grammar_signs(trees):
    """Every sign the productions spell."""
    signs = set()

    def walk(node):
        kind = node[0]
        #  A sign is punctuation.  A word, a name with digits in it like
        #  u32, and an escape the lexical layer spells are all not.
        if kind == "lit" and not re.match(r"^[\\A-Za-z0-9_]", node[1]):
            signs.add(node[1])
        elif kind in ("alt", "seq"):
            for child in node[1]:
                walk(child)
        elif kind in ("?", "*", "+"):
            walk(node[1])

    for tree in trees.values():
        walk(tree)
    return signs


def lexical_matches(trees, rule, text):
    """Does one lexical rule derive exactly these bytes?

    Without this the checker would take identifier on trust, and a rule
    that admits a lone '_' as a name would pass while the prose said
    otherwise -- which is what happened.
    """
    seen = {}

    def item(node, at):
        key = (id(node), at)
        if key in seen:
            return seen[key]
        seen[key] = ()
        kind = node[0]

        if kind == "lit":
            ends = ((at + len(node[1]),)
                    if text.startswith(node[1], at) else ())
        elif kind == "range":
            ends = ((at + 1,) if at < len(text)
                    and node[1] <= text[at] <= node[2] else ())
        elif kind == "byte":
            ends = (at + 1,) if at < len(text) else ()
        elif kind == "rule":
            ends = item(trees[node[1]], at) if node[1] in trees else ()
        elif kind == "alt":
            ends = tuple(sorted({e for arm in node[1] for e in item(arm, at)}))
        elif kind == "seq":
            reached = {at}
            for child in node[1]:
                following = set()
                for position in reached:
                    following |= set(item(child, position))
                reached = following
                if not reached:
                    break
            ends = tuple(sorted(reached))
        elif kind == "?":
            ends = tuple(sorted({at} | set(item(node[1], at))))
        elif kind in ("*", "+"):
            reached = set() if kind == "+" else {at}
            frontier = {at}
            while frontier:
                following = set()
                for position in frontier:
                    for end in item(node[1], position):
                        if end not in reached and end != position:
                            following.add(end)
                reached |= following
                frontier = following
            ends = tuple(sorted(reached))
        else:
            ends = ()

        seen[key] = ends
        return ends

    return rule in trees and len(text) in item(trees[rule], 0)


def landin_tokens(source, signs, trees=None):
    """(kind, spelling) per token, or (None, complaint).

    Written from the lexical rules rather than generated from them.  A
    tokeniser generated from the grammar could not catch a grammar whose
    lexical rules do not produce the tokens its upper rules need, which is
    the defect this whole exercise exists to catch.
    """
    out, i, n = [], 0, len(source)
    ordered = sorted(signs, key=len, reverse=True)

    while i < n:
        char = source[i]

        #  Whitespace is whatever the space rule spells, so dropping a
        #  byte from that rule is a change a fixture can notice.
        if char in " \t\r\n":
            if trees and not lexical_matches(trees, "space", char) \
                    and not lexical_matches(trees, "line_end", char):
                return None, "no rule spells the whitespace byte %r" % char
            i += 1
            continue

        if source.startswith("--(", i):
            depth, i = 1, i + 3
            while i < n and depth:
                if source.startswith("--(", i):
                    depth, i = depth + 1, i + 3
                elif source.startswith(")--", i):
                    depth, i = depth - 1, i + 3
                else:
                    i += 1
            if depth:
                return None, "a block comment is never closed"
            continue

        if source.startswith("--", i):
            while i < n and source[i] not in "\r\n":
                i += 1
            continue

        if char.isdigit():
            start = i
            while i < n and (source[i].isalnum() or source[i] == "_"):
                i += 1
            run = source[start:i]
            if trees and not lexical_matches(trees, "integer", run):
                return None, "%r is not an integer the rules spell" % run
            out.append(("integer", run))
            continue

        if char.islower() or char == "_":
            start = i
            while i < n and (source[i].islower() or source[i].isdigit()
                             or source[i] == "_"):
                i += 1
            run = source[start:i]
            #  The discard of [1020] is its own token: the identifier rule
            #  deliberately refuses a lone '_', so nothing else would take
            #  it.
            if run == "_":
                out.append(("sign", "_"))
                continue
            if trees and not lexical_matches(trees, "keyword", run) \
                    and not lexical_matches(trees, "identifier", run):
                return None, "%r is neither a keyword nor a name" % run
            out.append(("word", run))
            continue

        for sign in ordered:
            if source.startswith(sign, i):
                out.append(("sign", sign))
                i += len(sign)
                break
        else:
            return None, "no rule spells %r" % char

    return out, None


def grammar_recognises(rules, trees, tokens, start="program"):
    """Does the grammar derive exactly this token list?"""
    reserved = set(re.findall(r'"([a-z]+)"', rules.get("keyword", "")))
    seen = {}

    def item(node, at):
        key = (id(node), at)
        if key in seen:
            return seen[key]
        seen[key] = ()
        kind = node[0]

        if kind == "lit":
            ends = ()
            if at < len(tokens) and tokens[at][1] == node[1]:
                ends = (at + 1,)
        elif kind == "byte":
            ends = (at + 1,) if at < len(tokens) else ()
        elif kind == "rule":
            name = node[1]
            if name in TOKEN_KIND_RULES:
                ends = ()
                if at < len(tokens):
                    token_kind, text = tokens[at]
                    wanted = TOKEN_KIND_RULES[name]
                    if wanted == "name":
                        ends = ((at + 1,) if token_kind == "word"
                                and text not in reserved else ())
                    elif wanted == "integer":
                        ends = (at + 1,) if token_kind == "integer" else ()
                    else:
                        ends = ((at + 1,)
                                if token_kind == "integer"
                                or text in ("true", "false") else ())
            elif name in LEXICAL_RULES:
                ends = (at + 1,) if at < len(tokens) else ()
            elif name in trees:
                ends = item(trees[name], at)
            else:
                ends = ()
        elif kind == "alt":
            ends = tuple(sorted({e for arm in node[1] for e in item(arm, at)}))
        elif kind == "seq":
            reached = {at}
            for child in node[1]:
                following = set()
                for position in reached:
                    following |= set(item(child, position))
                reached = following
                if not reached:
                    break
            ends = tuple(sorted(reached))
        elif kind == "?":
            ends = tuple(sorted({at} | set(item(node[1], at))))
        elif kind in ("*", "+"):
            reached = set() if kind == "+" else {at}
            frontier = {at}
            while frontier:
                following = set()
                for position in frontier:
                    for end in item(node[1], position):
                        if end not in reached and end != position:
                            following.add(end)
                reached |= following
                frontier = following
            ends = tuple(sorted(reached))
        else:
            ends = ()

        seen[key] = ends
        return ends

    return len(tokens) in item(trees[start], 0)


def read_grammar(path):
    """(rules, trees, problems) for one tour file."""
    text = io.open(path, encoding="utf-8").read()
    offset, section = grammar_section(text)
    if section is None:
        return {}, {}, []

    rules, order, raw = grammar_rules(section)
    out = [(n + offset, why) for n, why in raw]

    trees = {}
    for name, line in order:
        try:
            trees[name] = Notation(name, rules[name]).parse()
        except ValueError as complaint:
            out.append((line + offset, "grammar notation: %s" % complaint))

    used = set()
    for tree in trees.values():
        grammar_uses(tree, used)
    for name in sorted(used - set(trees) - LEXICAL_RULES):
        out.append((offset + 1,
                    "grammar rule %r is used and not defined" % name))

    #  Stated in the prose of [1760] and easy to lose from the rule.
    if "identifier" in trees:
        if lexical_matches(trees, "identifier", "_"):
            out.append((offset + 1, "the identifier rule admits a lone '_', "
                                    "which is the discard of [1020]"))
        if not lexical_matches(trees, "identifier", "a_name1"):
            out.append((offset + 1,
                        "the identifier rule refuses an ordinary name"))

    if "program" not in trees:
        out.append((offset + 1, "the grammar has no 'program' rule"))
    else:
        reachable = set()
        frontier = {"program"} | (LEXICAL_RULES & set(trees))
        while frontier:
            name = frontier.pop()
            if name in reachable or name not in trees:
                continue
            reachable.add(name)
            names = set()
            grammar_uses(trees[name], names)
            frontier |= names - reachable
        for name in sorted(set(trees) - reachable):
            out.append((offset + 1, "grammar rule %r is unreachable" % name))

    return rules, trees, sorted(set(out))


def check_roadmap(path):
    """Cheap structural and referential checks over ROADMAP.md."""
    lines = io.open(path, encoding="utf-8").read().splitlines()
    out = []
    phases = collections.defaultdict(list)
    gates = collections.defaultdict(list)
    works = collections.defaultdict(list)
    work_titles = collections.defaultdict(list)
    current_phase = None

    for n, line in enumerate(lines, 1):
        phase = ROADMAP_PHASE.match(line)
        work = ROADMAP_WORK.match(line)
        gate = ROADMAP_GATE.match(line)
        if line.startswith("## "):
            current_phase = phase.group(1) if phase else None
        if phase:
            phases[current_phase].append(n)
        elif line.startswith("## R") and re.match(r"^## R\d+\b", line):
            out.append((n, "malformed roadmap phase heading"))
        if gate:
            gate_phase = gate.group(1)
            gates[gate_phase].append(n)
            if current_phase != gate_phase:
                out.append((n, "%s gate is under phase %s"
                            % (gate_phase, current_phase)))
        if work:
            work_id, suffix, title = work.groups()
            works[work_id].append(n)
            work_titles[title].append(n)
            if int(suffix) % 10:
                out.append((n, "%s is not spaced in an increment of ten" % work_id))
            if current_phase != work_id.split(".")[0]:
                out.append((n, "%s is under phase %s" % (work_id, current_phase)))
        elif re.match(r"^### R\d+\.", line):
            out.append((n, "malformed roadmap work heading"))

    expected_phases = ["R%d" % n for n in range(8)]
    actual_phases = [ROADMAP_PHASE.match(line).group(1) for line in lines
                     if ROADMAP_PHASE.match(line)]
    for phase in expected_phases:
        if not phases[phase]:
            out.append((1, "%s phase is missing" % phase))
        elif len(phases[phase]) > 1:
            out.append((phases[phase][1], "%s phase is duplicated, first at %d"
                        % (phase, phases[phase][0])))
        if not gates[phase]:
            out.append((phases[phase][0] if phases[phase] else 1,
                        "%s gate is missing" % phase))
        elif len(gates[phase]) > 1:
            out.append((gates[phase][1], "%s gate is duplicated, first at %d"
                        % (phase, gates[phase][0])))
        if gates[phase]:
            later_work = [locations[0] for work_id, locations in works.items()
                          if work_id.startswith(phase + ".")
                          and locations[0] > gates[phase][0]]
            if later_work:
                out.append((min(later_work), "%s work appears after its gate" % phase))
    if actual_phases != expected_phases:
        out.append((1, "roadmap phases are not exactly R0 through R7 in order"))

    for work_id, locations in works.items():
        if len(locations) > 1:
            out.append((locations[1], "%s is duplicated, first at %d"
                        % (work_id, locations[0])))
    for title, locations in work_titles.items():
        if len(locations) > 1:
            out.append((locations[1], "roadmap work title is duplicated, first at %d"
                        % locations[0]))

    work_lines = sorted((locations[0], work_id)
                        for work_id, locations in works.items() if locations)
    dependencies = {}
    for index, (start, work_id) in enumerate(work_lines):
        end = len(lines) + 1
        for n in range(start + 1, len(lines) + 1):
            if lines[n - 1].startswith(("## ", "### ")):
                end = n
                break
        chunk = lines[start:end - 1]
        statuses = [(start + offset, line) for offset, line in enumerate(chunk, 1)
                    if line.startswith("Status:")]
        depends = [(start + offset, line) for offset, line in enumerate(chunk, 1)
                   if line.startswith("Depends on:")]
        if len(statuses) != 1:
            out.append((start, "%s has %d Status lines" % (work_id, len(statuses))))
        elif not ROADMAP_STATUS.match(statuses[0][1]):
            out.append((statuses[0][0], "%s has an invalid status" % work_id))
        if len(depends) != 1:
            out.append((start, "%s has %d Depends on lines" % (work_id, len(depends))))
            continue
        match = ROADMAP_DEPENDS.match(depends[0][1])
        if not match:
            out.append((depends[0][0], "%s has malformed dependencies" % work_id))
            continue
        names = [] if match.group(1) == "none" else match.group(1).split(", ")
        dependencies[work_id] = names
        if len(names) != len(set(names)):
            out.append((depends[0][0], "%s repeats a dependency" % work_id))
        for name in names:
            if name == work_id:
                out.append((depends[0][0], "%s depends on itself" % work_id))
            elif name not in works:
                out.append((depends[0][0], "%s depends on unknown %s"
                            % (work_id, name)))

    #  References in prose and matrices should be well formed and resolve too.
    text = "\n".join(lines)
    for match in ROADMAP_REFERENCE_CANDIDATE.finditer(text):
        work_id = match.group(1)
        line = text.count("\n", 0, match.start()) + 1
        if not ROADMAP_REFERENCE.fullmatch(work_id):
            out.append((line, "%s is a malformed roadmap reference" % work_id))
        elif work_id not in works:
            out.append((line, "%s is referenced and not defined" % work_id))

    #  A small DFS catches cycles without pretending to schedule work.
    state = {}
    def visit(work_id, path_to_here):
        state[work_id] = 1
        for name in dependencies.get(work_id, []):
            if name not in works:
                continue
            if state.get(name) == 1:
                out.append((works[work_id][0], "roadmap dependency cycle: %s"
                            % " -> ".join(path_to_here + [work_id, name])))
            elif not state.get(name):
                visit(name, path_to_here + [work_id])
        state[work_id] = 2
    for work_id in works:
        if not state.get(work_id):
            visit(work_id, [])

    #  The migration appendix must preserve all 32 legacy rows exactly once.
    legacy = collections.defaultdict(list)
    actual_ids = []
    appendix = [n for n, line in enumerate(lines, 1)
                if line == MIGRATION_HEADING]
    if not appendix:
        out.append((1, "migration appendix is missing"))
    elif len(appendix) > 1:
        out.append((appendix[1], "migration appendix is duplicated"))
    else:
        start = appendix[0]
        end = len(lines) + 1
        for n in range(start + 1, len(lines) + 1):
            if lines[n - 1].startswith("## "):
                end = n
                break
        for n in range(start + 1, end):
            line = lines[n - 1]
            candidate = re.match(r"^\| ([A-Z]\d+)\b", line)
            if not candidate:
                continue
            legacy_id = candidate.group(1)
            actual_ids.append(legacy_id)
            legacy[legacy_id].append(n)
            row = MIGRATION_ROW.fullmatch(line)
            if not row:
                out.append((n, "malformed legacy migration row %s" % legacy_id))
                continue
            missing_anchors = [
                anchor for anchor in LEGACY_REQUIRED_ANCHORS.get(legacy_id, ())
                if anchor not in line
            ]
            if missing_anchors:
                out.append((n, "%s migration row omits required anchors: %s"
                            % (legacy_id, ", ".join(missing_anchors))))
            owner = row.group(4)
            owner_work = any(
                ROADMAP_REFERENCE.fullmatch(match.group(1))
                and match.group(1) in works
                for match in ROADMAP_REFERENCE_CANDIDATE.finditer(owner)
            )
            owner_successor = any(name in owner for name in MIGRATION_OWNER_NAMES)
            if not owner_work and not owner_successor:
                out.append((n, "%s migration row has no valid roadmap owner"
                            % legacy_id))

    expected = collections.Counter(LEGACY_IDS)
    actual = collections.Counter(actual_ids)
    if len(actual_ids) != len(LEGACY_IDS):
        out.append((appendix[0] if appendix else 1,
                    "migration appendix has %d rows, expected %d"
                    % (len(actual_ids), len(LEGACY_IDS))))
    if actual != expected:
        out.append((appendix[0] if appendix else 1,
                    "migration appendix does not contain exactly A1 through F3"))
    for legacy_id in LEGACY_IDS:
        if not legacy[legacy_id]:
            out.append((appendix[0] if appendix else 1,
                        "legacy migration row %s is missing" % legacy_id))
        elif len(legacy[legacy_id]) > 1:
            out.append((legacy[legacy_id][1],
                        "legacy migration row %s is duplicated" % legacy_id))
    extra = sorted(set(legacy) - set(LEGACY_IDS))
    for legacy_id in extra:
        out.append((legacy[legacy_id][0], "unexpected legacy migration row %s"
                    % legacy_id))

    return sorted(set(out))


def construct_definitions(path):
    text = io.open(path, encoding="utf-8").read()
    definitions = collections.defaultdict(list)
    for n, line in enumerate(text.splitlines(), 1):
        match = re.match(r"^\s*(?:--\(|---|--) \[(\d{4})\]", line)
        if match:
            definitions[match.group(1)].append((path, n))
    return definitions


def finding_definitions(paths):
    definitions = collections.defaultdict(list)
    for prefix, path in paths.items():
        text = io.open(path, encoding="utf-8").read()
        for n, line in enumerate(text.splitlines(), 1):
            match = re.match(r"^(%s\d+)\s" % prefix, line)
            if match:
                definitions[match.group(1)].append((path, n))
    return definitions


def check_citations(paths):
    """Every construct/finding citation resolves within the selected scope."""
    citation_paths = [path for path in paths
                      if os.path.basename(path) in LANGUAGE_FILES + [ROADMAP]]
    if not citation_paths:
        return []

    selected = {}
    for path in citation_paths:
        selected.setdefault(os.path.basename(path), path)
    tour_path = selected.get("tour.txt", os.path.join(ROOT, "tour.txt"))
    constructs = construct_definitions(tour_path)

    needs_findings = ROADMAP in selected
    if needs_findings:
        prototype_paths = {
            prefix: selected.get(filename, os.path.join(ROOT, filename))
            for prefix, filename in PROTOTYPE_FINDINGS.items()
        }
        findings = finding_definitions(prototype_paths)
    else:
        findings = {}

    out = []
    for construct, locations in constructs.items():
        if len(locations) > 1:
            path, line = locations[1]
            first_path, first_line = locations[0]
            out.append((path, line, "[%s] is defined twice, first at %s:%d"
                        % (construct, first_path, first_line)))
    for finding, locations in findings.items():
        if len(locations) > 1:
            path, line = locations[1]
            out.append((path, line, "%s is defined twice, first at %s:%d"
                        % (finding, locations[0][0], locations[0][1])))

    for path in citation_paths:
        text = io.open(path, encoding="utf-8").read()
        for match in re.finditer(r"(?<![\w])\[(\d{4})\](?![A-Za-z_0-9])", text):
            if match.group(1) not in constructs:
                line = text.count("\n", 0, match.start()) + 1
                out.append((path, line, "[%s] is cited and not defined"
                            % match.group(1)))
        if os.path.basename(path) == ROADMAP:
            for match in re.finditer(r"(?<![\w])\[(\d+)\](?![A-Za-z_0-9])", text):
                if len(match.group(1)) != 4:
                    line = text.count("\n", 0, match.start()) + 1
                    out.append((path, line, "[%s] is not a four-digit construct citation"
                                % match.group(1)))
            for match in re.finditer(
                    r"(?<![A-Za-z0-9_])([XYZW]\d+)(?![A-Za-z0-9_])", text):
                if match.group(1) not in findings:
                    line = text.count("\n", 0, match.start()) + 1
                    out.append((path, line, "%s is cited and not defined"
                                % match.group(1)))
    return sorted(set(out))


def check_pinned_toolchain(full_run):
    """Every file that installs or records the toolchain must name one.

    The recipe pins it, compiler/ada/TOOLCHAIN.md records it for a reader,
    and environments/pins.sh is the one place a value is written; the nix
    shell and the CI manifest read that file rather than repeating it. Every
    file naming a compiler version is another chance to be wrong, and the one
    that drifts is the one nobody reads.
    """
    if not full_run:
        return []

    recipe = os.path.join(ROOT, "environments/linux-amd64/Containerfile")
    record = os.path.join(ROOT, "compiler/ada/TOOLCHAIN.md")
    pins = os.path.join(ROOT, "environments/pins.sh")

    if not os.path.exists(recipe) or not os.path.exists(record):
        return []

    out = []
    recipe_text = io.open(recipe, encoding="utf-8").read()
    record_text = io.open(record, encoding="utf-8").read()
    pins_text = (io.open(pins, encoding="utf-8").read()
                 if os.path.exists(pins) else "")

    wanted = {
        "GNAT_VERSION": r"ARG GNAT_VERSION=(\S+)",
        "GPRBUILD_VERSION": r"ARG GPRBUILD_VERSION=(\S+)",
        "GNAT_SHA256": r"ARG GNAT_SHA256=(\S+)",
        "GPRBUILD_SHA256": r"ARG GPRBUILD_SHA256=(\S+)",
    }

    for name, pattern in wanted.items():
        found = re.search(pattern, recipe_text)
        if not found:
            out.append((recipe, 1, "%s is not pinned in the recipe" % name))
            continue
        value = found.group(1)
        if value not in record_text:
            out.append((recipe, 1,
                        "%s %s is not recorded in compiler/ada/TOOLCHAIN.md"
                        % (name, value)))
        if pins_text and value not in pins_text:
            out.append((recipe, 1,
                        "%s %s is not pinned in environments/pins.sh"
                        % (name, value)))

    #  The nix shell and the CI manifest each install the toolchain
    #  themselves, so each is a further place a version could be written.
    #  Both are held to reading the pins rather than naming one: a build that
    #  fetches a different compiler than the recipe does is not a slower
    #  build, it is a different compiler.
    for relative in ("flake.nix", ".build.yml"):
        path = os.path.join(ROOT, relative)
        if not os.path.exists(path):
            continue
        text = io.open(path, encoding="utf-8").read()
        if "environments/pins.sh" not in text:
            out.append((path, 1, "%s does not read environments/pins.sh"
                                 % relative))
        for name, pattern in wanted.items():
            found = re.search(pattern, recipe_text)
            if found and found.group(1) in text:
                out.append((path, 1,
                            "%s names %s literally instead of reading it "
                            "from environments/pins.sh" % (relative, name)))

    return out


def check_grammar_corpus(full_run):
    """The grammar derives every positive fixture and no negative one.

    This is the check that earns the rest of the grammar machinery: a
    production that cannot derive real source, or a construct the kernel
    should refuse and does not, fails here in a second rather than in a
    review.  R1.40's parser has to agree with the same corpus, and a
    disagreement between the two is a defect in one of them.
    """
    if not full_run:
        return []

    tour = os.path.join(ROOT, "tour.txt")
    if not os.path.exists(tour):
        return []

    rules, trees, problems = read_grammar(tour)
    out = [("tour.txt", n, why) for n, why in problems]
    if not trees or "program" not in trees:
        return out

    signs = grammar_signs(trees)
    fixtures = os.path.join(ROOT, "compiler/tests/fixtures")

    for kind, must_derive in (("positive", True), ("negative", False)):
        directory = os.path.join(fixtures, kind)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            case = os.path.join(directory, name)
            if not os.path.isdir(case):
                continue
            for source in sorted(f for f in os.listdir(case)
                                 if f.endswith(".ldn")):
                path = os.path.join(case, source)
                where = "compiler/tests/fixtures/%s/%s/%s" % (kind, name,
                                                             source)
                text = io.open(path, encoding="utf-8").read()
                tokens, complaint = landin_tokens(text, signs, trees)
                derives = (tokens is not None
                           and grammar_recognises(rules, trees, tokens))

                if must_derive and not derives:
                    out.append((where, 1,
                                "the grammar does not derive this: %s"
                                % (complaint or "no derivation")))
                elif not must_derive and derives:
                    out.append((where, 1,
                                "the grammar derives this, and a negative "
                                "fixture must not be derivable"))

    #  R1.10 asks for every production traced to its constructs.  The
    #  fixtures carry the citations, so the trace is checkable: a construct
    #  in the grammar that no fixture names is a rule nothing pins.
    cited = set()
    for kind in ("positive", "negative"):
        directory = os.path.join(fixtures, kind)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            meta = os.path.join(directory, name, "fixture.meta")
            if os.path.exists(meta):
                cited |= set(re.findall(
                    r"\[(\d{4})\]",
                    io.open(meta, encoding="utf-8").read()))

    section_text = "\n".join(grammar_section(
        io.open(tour, encoding="utf-8").read())[1] or [])
    for construct in sorted(set(re.findall(r"^-- \[(\d{4})\]",
                                           section_text, re.M))):
        if construct not in cited:
            out.append(("tour.txt", 1,
                        "grammar construct [%s] is named by no fixture"
                        % construct))

    return out


def check_stale_backlog(paths, full_run):
    """No live document points at the retired work authority."""
    out = []
    if full_run and os.path.exists("BACKLOG.md"):
        out.append(("BACKLOG.md", 1, "retired work-authority file still exists"))
    for path in paths:
        if not os.path.exists(path):
            continue
        relative = os.path.normpath(
            os.path.relpath(os.path.abspath(path), ROOT))
        text = io.open(path, encoding="utf-8").read()
        for n, line in enumerate(text.splitlines(), 1):
            if (relative, line) in STALE_BACKLOG_ALLOWLIST:
                continue
            if re.search(r"BACKLOG\.md", line, re.I):
                out.append((path, n, "stale BACKLOG.md authority reference"))
    return out


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    if here:
        os.chdir(here)
    full_run = len(argv) == 1
    paths = FILES if full_run else argv[1:]
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        print("not found next to check.py: %s" % ", ".join(missing))
        return 2

    total = 0
    for path in paths:
        base = os.path.basename(path)
        if base == ROADMAP:
            problems = check_roadmap(path)
        elif base in LANGUAGE_FILES:
            problems = check(path)
        else:
            problems = check(path)
        total += len(problems)
        print("%-30s %s" % (path, "clean" if not problems else
                            "%d problem(s)" % len(problems)))
        for line, why in sorted(problems):
            print("    %5d  %s" % (line, why))

    citation_paths = [p for p in paths
                      if os.path.basename(p) in LANGUAGE_FILES + [ROADMAP]]
    extra = check_citations(citation_paths)
    stale_paths = LIVE_DOCS if full_run else paths
    extra += check_stale_backlog(stale_paths, full_run)
    extra += check_pinned_toolchain(full_run)
    extra += check_grammar_corpus(full_run)
    for path, line, why in sorted(set(extra)):
        total += 1
        print("%-30s %5d  %s" % (path, line, why))

    print("\n%s" % ("all clean" if not total else "%d problem(s)" % total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
