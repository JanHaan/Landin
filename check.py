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

#  The normative document, named once.  Every check that reads it goes
#  through this, so a rename is one edit rather than nine -- and so that a
#  check cannot quietly look for a file that is no longer there.
#  The two normative documents.  SPEC holds the grammar of the enabled
#  kernel and the rules the tour left unsaid; TOUR explains the language.
#  A construct is defined in exactly one of them.
SPEC_NAME = "spec.md"
TOUR_NAME = "tour.md"

def absent(paths):
    """A file a check needs and cannot find, reported rather than skipped.

    Every check that reads a document used to return no faults when the
    document was not there.  That is the worst possible answer: renaming
    tour.md made four checks vacuous and the run still said `all clean`,
    which was proved by appending a bogus production and seeing it pass.
    A check that cannot do its job says so.
    """
    return [(os.path.relpath(f, ROOT), 1,
             "this file is needed by a check and is not here")
            for f in paths if not os.path.exists(f)]


LANGUAGE_FILES = [SPEC_NAME, TOUR_NAME, "prototype-1-driver.md",
                  "prototype-2-parser.md",
                  "prototype-3-containers.md",
                  "prototype-4-app.md"]
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
    "X": "prototype-1-driver.md",
    "Y": "prototype-2-parser.md",
    "Z": "prototype-3-containers.md",
    "W": "prototype-4-app.md",
}
#  Names that are deliberately not files here: an example in prose, a
#  path inside a container, or a file a reader is told to create.
NAMED_FILE_ALLOWLIST = frozenset((
    "BACKLOG.md",              # the retired work authority, named to refuse it
    "CONTEXT.md",              # a file docs/agents/domain.md tells you to write
    "unit/stray.txt",          # a harness case named relative to its own tree
    #  Names docs/agents/domain.md uses as examples of what to write.
    "CONTEXT-MAP.md",
    "map.md",
    "0001-event-sourced-orders.md",
    "0002-postgres-for-write-model.md",
    #  The external design archive, named to contrast it with the current
    #  handoff.md in the same sentence.  AGENTS.md already says the tracked
    #  repository does not depend on that archive.
    "HANDOFF.md",
    #  Written into docs/site/site/ by render_html.py and never committed,
    #  so they are in the built site and not in the repository.  A local
    #  run finds them anyway, because a previous render left them on disk;
    #  the clean gate is what noticed they are not tracked.
    "robots.txt",
    "sitemap.xml",
    "og.png",
    "icon-mono.svg",
    "apple-touch-icon.png",
))

STALE_BACKLOG_ALLOWLIST = {
    ("prototype-3-containers.md",
     "other thing, and they are parked with a condition in BACKLOG.md."),
    ("prototype-4-app.md",
     "other thing, and they are parked with a condition in BACKLOG.md. And"),
}


def sections(lines):
    """Split a file into (kind, first_line, lines), by fence rather than
    by guess.

    A fenced block says what it is, so nothing has to be inferred.  The
    tag is the kind: `landin` is checked, `landin-grammar` is notation
    rather than Landin, and prose is not code at all.  In the .txt form
    this was four heuristics over a document where a production and a
    paragraph both began at column 0; measured against the tour's prose
    with its comment prefix stripped, the code heuristic accepted 114
    lines of English.
    """
    kind, start, buf = "prose", 1, []
    findings = False
    for n, line in enumerate(lines, 1):
        s = line.strip()
        fence = re.match(r"^```(\S*)\s*$", s)

        if s.startswith("## WHAT THIS ONE FOUND") \
                or s.startswith("## WHERE THE SPECIFICATION WAS SILENT") \
                or s.startswith("## WHAT WAS TRIED AND DROPPED"):
            yield kind, start, buf
            kind, start, buf, findings = "findings", n, [], True
            buf.append(line)
            continue

        if fence:
            tag = fence.group(1)
            if kind in ("prose", "findings"):
                yield kind, start, buf
                kind, start, buf = (tag or "text"), n, []
            else:
                yield kind, start, buf
                kind, start, buf = ("findings" if findings else "prose"), n, []
            continue

        buf.append(line)

    yield kind, start, buf


def module_banner(line):
    """A module header inside a prototype: names may repeat across them."""
    return re.match(r"^[a-z][a-z0-9_/]*(?:  —|\s*$)", line) and "/" in line


def looks_like_code(line):
    """Kept only for the harness-case reader, which is not a document.

    A fenced block says what it is, so nothing in a document needs this.
    """
    s = line.strip()
    return bool(s) and not s.startswith("--")


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
#  spec.md's grammar section is normative, and two rounds of reading it by
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

#  Byte classes, spelled out.  Python's own predicates are about Unicode:
#  'e' with an accent is lower case to str.islower and an Eastern Arabic
#  numeral is a digit to str.isdigit, so a scanner built on them swallows a
#  byte [1750] does not allow outside a comment and then blames the name it
#  landed in.  A span that names the wrong bytes is worse than no span.
LETTERS = frozenset("abcdefghijklmnopqrstuvwxyz")
UPPER = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
DIGITS = frozenset("0123456789")
NOTATION_WORD = re.compile(
    r'\s*("(?:[^"\\]|\\.)*"'
    r'|any byte(?: that begins neither "[^"]*" nor "[^"]*")?'
    r'(?: except [a-z_]+)?'
    r'|\.\.\.'
    r'|[a-z_]+'
    r'|[()|?*+])'
)


def grammar_section(text):
    """Every `landin-grammar` fence, and where the first one starts.

    In the .txt form this found a banner and read to the next one, which
    meant the section's prose and its productions shared a region and were
    told apart by looking for `::=`.  A tagged fence says which is which.
    """
    lines = text.splitlines()
    out, offset, inside = [], None, False
    for n, line in enumerate(lines, 1):
        fence = re.match(r"^```(\S*)\s*$", line.strip())
        if fence:
            if inside:
                inside = False
            elif fence.group(1) == "landin-grammar":
                inside = True
                if offset is None:
                    offset = n
            continue
        if inside:
            out.append(line)
    if offset is None:
        return None, None
    return offset, out


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

        if char in DIGITS:
            start = i
            while i < n and (source[i] in DIGITS or source[i] in LETTERS
                             or source[i] in UPPER or source[i] == "_"):
                i += 1
            run = source[start:i]
            if trees and not lexical_matches(trees, "integer", run):
                return None, "%r is not an integer the rules spell" % run
            out.append(("integer", run))
            continue

        if char in LETTERS or char == "_":
            start = i
            while i < n and (source[i] in LETTERS or source[i] in DIGITS
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

    #  A line that spells `::=` is a production and has to parse as one.
    #  PRODUCTION only matches a lower-case name, so `GARBAGE ::= nonsense`
    #  added to the grammar was silently ignored and the run said `all
    #  clean` -- proved by doing it.  This is deliberately narrow: in this
    #  section prose sits at column 0 too, and nothing but `::=`
    #  distinguishes the two, which is one of the reasons the documents are
    #  moving to a form where a rule and a paragraph are different things.
    for n, line in enumerate(section, 1):
        if "::=" in line and not PRODUCTION.match(line):
            out.append((n + offset,
                        "this spells ::= and is not a production: %r"
                        % line.strip()[:44]))

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


def construct_ids():
    """Every construct id either document defines.

    A construct lives in exactly one of them and a consumer does not care
    which, so this is the answer every "does [NNNN] exist" question wants.
    Reading one document was right when there was one; it is now a way to
    report a live citation as undefined.
    """
    out = set()
    for name in (SPEC_NAME, TOUR_NAME):
        path = os.path.join(ROOT, name)
        if os.path.exists(path):
            out |= set(re.findall(r"^### \[(\d{4})\] ",
                                  io.open(path, encoding="utf-8").read(),
                                  re.M))
    return out


def construct_definitions(path):
    text = io.open(path, encoding="utf-8").read()
    definitions = collections.defaultdict(list)
    for n, line in enumerate(text.splitlines(), 1):
        match = re.match(r"^### \[(\d{4})\] ", line)
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
    tour_path = selected.get(TOUR_NAME, os.path.join(ROOT, TOUR_NAME))
    spec_path = selected.get(SPEC_NAME, os.path.join(ROOT, SPEC_NAME))

    #  A construct is defined in exactly one of the two documents, and a
    #  citation resolves in either.  Merging the two dictionaries is also
    #  what makes "defined twice" catch an id defined in both, which is
    #  the invariant the split newly needs and nothing else states.
    constructs = construct_definitions(tour_path)
    for construct, locations in construct_definitions(spec_path).items():
        constructs.setdefault(construct, []).extend(locations)

    out_prototype = []
    needs_findings = ROADMAP in selected
    if needs_findings:
        prototype_paths = {
            prefix: selected.get(filename, os.path.join(ROOT, filename))
            for prefix, filename in PROTOTYPE_FINDINGS.items()
        }
        findings = finding_definitions(prototype_paths)
    else:
        findings = {}

    #  A construct is defined in spec.md or tour.md and nowhere else.  A
    #  prototype cites them, and a citation is inline: one that reaches
    #  column 0 behind a '### ' has stopped being a citation and become a
    #  second definition of an id that already has one.  Five of those sat
    #  in the prototypes unnoticed, because the two documents were the
    #  only places this ever read.
    for path in citation_paths:
        if os.path.basename(path) not in PROTOTYPE_FINDINGS.values():
            continue
        text = io.open(path, encoding="utf-8").read()
        for n, line in enumerate(text.splitlines(), 1):
            match = re.match(r"^### \[(\d{4})\]", line)
            if match:
                constructs.setdefault(match.group(1), []).append((path, n))
                out_prototype.append(
                    (path, n, "[%s] is defined here; a construct belongs to "
                              "%s or %s and a prototype only cites one"
                     % (match.group(1), TOUR_NAME, SPEC_NAME)))

    out = list(out_prototype)
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
    shell and the CI manifests read that file rather than repeating it. Every
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

    #  A further manifest need not install the toolchain at all --
    #  .builds/nix.yml leaves that to the flake, which is why it is not held
    #  to reading the pins -- but it is still a file where a version could be
    #  written by hand, and that half of the rule holds everywhere.
    builds = os.path.join(ROOT, ".builds")
    for name_yml in sorted(os.listdir(builds) if os.path.isdir(builds) else []):
        if not name_yml.endswith(".yml"):
            continue
        path = os.path.join(builds, name_yml)
        relative = os.path.join(".builds", name_yml)
        text = io.open(path, encoding="utf-8").read()
        for name, pattern in wanted.items():
            found = re.search(pattern, recipe_text)
            if found and found.group(1) in text:
                out.append((path, 1,
                            "%s names %s literally instead of reading it "
                            "from environments/pins.sh" % (relative, name)))

    return out


def token_dump():
    """The corpus, tokenised, as text both implementations can compare.

    A line is `first last spelling`, which is the whole of what a
    tokeniser agreement needs: the same boundaries over the same bytes.
    Kinds are deliberately not in it -- the two implementations have
    different kind vocabularies, and a boundary difference is what a
    disagreement actually looks like.
    """
    #  The grammar moved to spec.md when the documents split, and this
    #  kept reading tour.md, which has no `landin-grammar` fence left in
    #  it: read_grammar returned nothing, this returned None, and the
    #  token dump has not been compared with anything since.
    rules, trees, problems = read_grammar(os.path.join(ROOT, SPEC_NAME))
    if problems or "program" not in trees:
        return None

    signs = grammar_signs(trees)
    fixtures = os.path.join(ROOT, "compiler/tests/fixtures")
    lines = ["#  Generated by check.py.  Do not edit; regenerate with",
             "#  python3 check.py --tokens.  The Ada harness reads this and",
             "#  compares it with what Landin.Tokens.Lexer produced."]

    for kind in ("positive", "negative"):
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
                text = io.open(path, "rb").read().decode("latin-1")
                tokens, complaint = landin_tokens(text, signs, trees)
                where = "%s/%s/%s" % (kind, name, source)

                if tokens is None:
                    lines.append("file %s refused %s" % (where, complaint))
                    continue

                lines.append("file %s tokens %d" % (where, len(tokens)))
                at = 0
                for token_kind, spelling in tokens:
                    at = text.index(spelling, at)
                    lines.append("  %d %d %s"
                                 % (at, at + len(spelling), spelling))
                    at += len(spelling)

    return "\n".join(lines) + "\n"


def frontend_codes():
    """The code strings the scan and the parse can raise.

    Read from Landin.Diagnostics.Lexical and Landin.Diagnostics.Syntactic,
    the only two packages that turn a scanner fault or a parse failure into
    a code, and never from the number: the catalogue's own header forbids
    reading a stage off a code, because "a code is a name, not an address",
    and L0010 is the standing proof, raised by the scanner today and by the
    parser since R1.40.
    """
    rows = catalogue_rows()
    if rows is None:
        return set()
    by_name = {row["name"]: row["code"] for row in rows}

    out = set()
    for path in ("compiler/ada/src/diagnostics"
                 "/landin-diagnostics-lexical.adb",
                 "compiler/ada/src/diagnostics"
                 "/landin-diagnostics-syntactic.ads"):
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            #  Empty rather than partial.  A smaller set here silently
            #  reclassifies fixtures, and check_grammar_corpus reads this
            #  set to decide whether the grammar must derive a negative
            #  program: half an answer is worse than none, and none makes
            #  it fail closed.
            return set()
        found = re.search(r"function Code_For[^;]*?is \(case .*?\);",
                          io.open(full, encoding="utf-8").read(), re.S)
        if not found:
            continue
        for name in re.findall(r"(?:Rows|Catalogue)\.([A-Za-z0-9_]+)",
                               found.group(0)):
            if name in by_name:
                out.add(by_name[name])
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

    tour = os.path.join(ROOT, SPEC_NAME)
    missing = absent((tour,))
    if missing:
        return missing

    rules, trees, problems = read_grammar(tour)
    out = [(SPEC_NAME, n, why) for n, why in problems]
    if not trees or "program" not in trees:
        return out

    signs = grammar_signs(trees)
    fixtures = os.path.join(ROOT, "compiler/tests/fixtures")

    #  The corpus is read as bytes, and this is what says so.  Python's
    #  text mode turns CR LF and a lone CR into LF, and a reader that did
    #  that could not test the terminator rule [1750] states however many
    #  fixtures were written for it.
    witness = os.path.join(fixtures, "positive/line-ends-crlf/program.ldn")
    if os.path.exists(witness):
        if "\r" not in io.open(witness, "rb").read().decode("latin-1"):
            out.append(("compiler/tests/fixtures/positive/line-ends-crlf"
                        "/program.ldn", 1,
                        "this fixture must carry a CR byte, and the corpus "
                        "must be read as bytes to see it"))

    #  Which codes the scan and the parse can raise.  Empty means the two
    #  packages could not be read, and then nothing is reclassified below:
    #  failing closed keeps a corpus check from getting quietly weaker --
    #  and saying so keeps it from being quiet about that too.
    frontend = frontend_codes()
    out.extend(absent(
      (os.path.join(ROOT, "compiler/ada/src/diagnostics"
                          "/landin-diagnostics-lexical.adb"),
       os.path.join(ROOT, "compiler/ada/src/diagnostics"
                          "/landin-diagnostics-syntactic.ads"))))


    #  A runtime fixture's program is legal source that the compiler is
    #  expected to accept, compile and run, so the grammar must derive it
    #  exactly as it derives a positive one.  Its own directory rather
    #  than positive/, because what it pins is what the program *does*
    #  when it runs and not merely that it was accepted.
    for kind, default_derive in (("positive", True),
                                 ("runtime", True),
                                 ("negative", False)):
        directory = os.path.join(fixtures, kind)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            case = os.path.join(directory, name)
            if not os.path.isdir(case):
                continue

            #  A negative fixture's `codes:` says which stage refused it,
            #  and that decides whether the grammar must derive it.  The
            #  frontend refuses what the grammar cannot derive; a later
            #  stage refuses source that parsed, so the grammar must derive
            #  that exactly as it derives a positive fixture.  Reading it
            #  out of `codes:` rather than a second key leaves the two
            #  nothing to disagree about.
            must_derive = default_derive
            meta = os.path.join(case, "fixture.meta")
            if kind == "negative" and frontend and os.path.exists(meta):
                named = re.search(
                    r"^codes: (.+)$",
                    io.open(meta, encoding="utf-8").read(), re.M)
                if named:
                    first = named.group(1).split(",", 1)[0].strip()
                    if first and first not in frontend:
                        must_derive = True

            for source in sorted(f for f in os.listdir(case)
                                 if f.endswith(".ldn")):
                path = os.path.join(case, source)
                where = "compiler/tests/fixtures/%s/%s/%s" % (kind, name,
                                                             source)
                #  Bytes, not text: Python's text mode turns CR LF and a
                #  lone CR into LF, so a reader that used it could never
                #  test the terminator rule [1750] stated, and its offsets
                #  would be character offsets rather than byte offsets.
                text = io.open(path, "rb").read().decode("latin-1")
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

                #  A fixture may pin the complaint as well as the refusal.
                #  Refusing for the wrong reason means the wrong span, and
                #  a span that names the wrong bytes is the defect.
                meta = os.path.join(case, "fixture.meta")
                if os.path.exists(meta):
                    wanted = re.search(
                        r"^lex: (.+)$",
                        io.open(meta, encoding="utf-8").read(), re.M)
                    if wanted:
                        expected = wanted.group(1).encode().decode(
                            "unicode_escape")
                        if complaint != expected:
                            out.append((where, 1,
                                        "the scanner says %r and the "
                                        "fixture expects %r"
                                        % (complaint, expected)))

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
            out.append((SPEC_NAME, 1,
                        "grammar construct [%s] is named by no fixture"
                        % construct))

    #  The recorded token dump the Ada harness reads has to be what this
    #  tokeniser produces now.  A stale dump is two implementations
    #  agreeing with a third thing that no longer exists.
    recorded = os.path.join(ROOT, "compiler/tests/lexical.tokens")
    fresh = token_dump()
    if fresh is not None:
        if not os.path.exists(recorded):
            out.append(("compiler/tests/lexical.tokens", 1,
                        "the token dump is missing; regenerate it with "
                        "python3 check.py --tokens"))
        elif io.open(recorded, encoding="utf-8").read() != fresh:
            out.append(("compiler/tests/lexical.tokens", 1,
                        "the token dump is stale; regenerate it with "
                        "python3 check.py --tokens"))

    return out


def check_token_vocabulary(full_run):
    """The scanner's vocabulary is the grammar's, and says where it is not.

    Landin.Tokens names two things the grammar does not: the seventeen
    reserved words, which must be exactly the grammar's own, and a band of
    deferred lexemes the kernel refuses by [1830], each of which must name
    a construct spec.md actually defines.  Without this the scanner would
    be a second lexical authority, which is one more than this repository
    is willing to have.
    """
    if not full_run:
        return []

    spec = os.path.join(ROOT, "compiler/ada/src/syntax/landin-tokens.ads")
    body = os.path.join(ROOT, "compiler/ada/src/syntax/landin-tokens.adb")
    tour = os.path.join(ROOT, SPEC_NAME)
    missing = absent((spec, body, tour))
    if missing:
        return missing

    out = []
    spec_text = io.open(spec, encoding="utf-8").read()
    body_text = io.open(body, encoding="utf-8").read()
    rules, trees, problems = read_grammar(tour)
    if problems:
        return []

    #  The reserved words the scanner knows, from the enumeration itself.
    scanner_words = sorted(m.lower() for m in
                           re.findall(r"\bKw_([A-Za-z]+)", spec_text))
    scanner_words = sorted(set(scanner_words))
    grammar_words = sorted(set(re.findall(r'"([a-z]+)"',
                                          rules.get("keyword", ""))))

    if scanner_words != grammar_words:
        missing = sorted(set(grammar_words) - set(scanner_words))
        extra = sorted(set(scanner_words) - set(grammar_words))
        out.append((
            "compiler/ada/src/syntax/landin-tokens.ads", 1,
            "the scanner's reserved words differ from the grammar's "
            "keyword rule: missing %s, extra %s"
            % (missing or "none", extra or "none")))

    #  Every deferred lexeme names a construct, and the construct exists.
    constructs = construct_ids()
    arms = re.findall(r"when\s+([A-Za-z_]+)\s*=>\s*\"\[(\d{4})\]\"",
                      body_text)
    if not arms:
        out.append(("compiler/ada/src/syntax/landin-tokens.adb", 1,
                    "no deferred lexeme names a construct"))
    for kind, construct in arms:
        if construct not in constructs:
            out.append((
                "compiler/ada/src/syntax/landin-tokens.adb", 1,
                "%s names [%s], which neither document defines"
                % (kind, construct)))

    #  A deferred lexeme is one the grammar does NOT spell.  If the grammar
    #  grows to spell it, it stops being deferred and this says so.
    spelled = grammar_signs(trees)
    signs = dict(re.findall(r'when\s+([A-Za-z_]+)\s*=>\s*"([^"]+)",',
                            body_text))
    for kind, _ in arms:
        spelling = signs.get(kind)
        if spelling and spelling in spelled:
            out.append((
                "compiler/ada/src/syntax/landin-tokens.adb", 1,
                "%s is deferred and the grammar spells %r, so it is not "
                "deferred any more" % (kind, spelling)))

    return out


#  The lexical rules that produce exactly one token [1750], so a rule
#  above the lexical layer may treat them as terminals.  `literal` is not
#  among them: it is an alternation of three, and expanding it is what
#  makes a first set comparable with Landin.Tokens.Is_Literal.
TOKEN_PRODUCERS = frozenset(("identifier", "keyword", "integer"))


def grammar_first(trees):
    """rule -> (what it may begin with, whether it may be empty).

    The items are ('lit', bytes) for a terminal the rule spells and
    ('token', rule) for one of the four lexical rules that produce a token
    of their own [1750].  Those four are terminals to every rule above the
    lexical layer, which is what makes a first set comparable with a
    predicate over token kinds.
    """
    first = {name: set() for name in trees}
    empty = {name: False for name in trees}

    def of(node):
        kind = node[0]
        if kind == "lit":
            return {("lit", node[1])}, False
        if kind in ("range", "byte"):
            return {(kind,)}, False
        if kind == "rule":
            if node[1] in TOKEN_PRODUCERS:
                return {("token", node[1])}, False
            if node[1] in trees:
                return set(first[node[1]]), empty[node[1]]
            return {("rule", node[1])}, False
        if kind == "alt":
            items, nil = set(), False
            for child in node[1]:
                got, one = of(child)
                items |= got
                nil = nil or one
            return items, nil
        if kind == "seq":
            items, nil = set(), True
            for child in node[1]:
                got, one = of(child)
                items |= got
                if not one:
                    nil = False
                    break
            return items, nil
        if kind in ("*", "?"):
            got, _ = of(node[1])
            return got, True
        if kind == "+":
            return of(node[1])
        return set(), False

    moving = True
    while moving:
        moving = False
        for name, tree in trees.items():
            got, nil = of(tree)
            if got - first[name] or (nil and not empty[name]):
                first[name] |= got
                empty[name] = empty[name] or nil
                moving = True
    return first, empty


def precedence_chain(rules):
    """[1820] read as a chain: (rule, sub, operators, fold), loosest first.

    Every binary level is written the same way -- one sub-level, then a
    group of operators and that sub-level again, repeated -- and the only
    thing that differs is the operator set and whether the repetition is
    '*' or '?'.  Walking the chain down from `expression` is what turns
    those rules into a table an implementation can be compared with.
    """
    chain = []
    name = "expression"
    seen = set()
    while name in rules and name not in seen:
        seen.add(name)
        found = re.match(r"^([a-z_]+)\s*\((.*)\)\s*([*?])$",
                         rules[name].strip())
        if not found:
            break
        sub, inner, repeat = found.group(1), found.group(2), found.group(3)
        if not re.search(r"\b%s\s*$" % re.escape(sub), inner):
            break
        chain.append((name, sub, re.findall(r'"([^"]*)"', inner), repeat))
        name = sub
    return chain, name


def ada_level(rule):
    """The enumeration literal a rule's level is named after."""
    return "Level_" + "_".join(bit.capitalize() for bit in rule.split("_"))


def check_precedence_table(full_run):
    """Landin.Syntax.Precedence is a transcription of [1820], and checked.

    Ten productions of one shape become one table and one loop, and the
    whole argument for doing it that way is that a transcription can be
    compared with its source while ten paraphrases cannot.  This is that
    comparison: the same levels in the same order, the same operators at
    each, the same fold, the same prefix set, and first sets that agree
    with the grammar's own.
    """
    if not full_run:
        return []

    spec = os.path.join(ROOT,
                        "compiler/ada/src/syntax/landin-syntax-precedence.ads")
    tokens = os.path.join(ROOT, "compiler/ada/src/syntax/landin-tokens.ads")
    signs = os.path.join(ROOT, "compiler/ada/src/syntax/landin-tokens.adb")
    tour = os.path.join(ROOT, SPEC_NAME)
    missing = absent((spec, tokens, signs, tour))
    if missing:
        return missing

    where = "compiler/ada/src/syntax/landin-syntax-precedence.ads"
    out = []
    text = io.open(spec, encoding="utf-8").read()
    rules, trees, problems = read_grammar(tour)
    if problems:
        return []

    chain, tail = precedence_chain(rules)
    if not chain:
        return [(where, 1, "the tour's operator levels could not be read, "
                           "so the table is unchecked")]

    #  What a token kind spells, so a table over kinds can be compared with
    #  a grammar over bytes.
    spelling = dict(re.findall(r'when\s+([A-Za-z_]+)\s*=>\s*"([^"]+)",',
                               io.open(signs, encoding="utf-8").read()))
    token_text = io.open(tokens, encoding="utf-8").read()

    def item_of(kind):
        if kind == "Identifier":
            return ("token", "identifier")
        if kind == "Integer_Literal":
            return ("token", "integer")
        if kind.startswith("Kw_"):
            return ("lit", kind[3:].lower())
        if kind in spelling:
            return ("lit", spelling[kind])
        return ("kind", kind)

    def body_of(source, name):
        found = re.search(r"function %s \([^)]*\)\s*"
                          r"return [A-Za-z_.]+\s*is \((.*?)\);"
                          % name, source, re.S)
        return found.group(1) if found else None

    def kinds_in(body):
        return set(re.findall(r"(?:Landin\.Tokens\.)?\b((?:Kw_[A-Za-z_]+)"
                              r"|Identifier|Integer_Literal|Ampersand|Bar"
                              r"|Caret|Equal_Equal|Greater_Greater|Greater_Equal"
                              r"|Greater|Left_Paren|Less_Greater|Less_Equal"
                              r"|Less_Less|Less|Minus_Percent|Minus|Percent"
                              r"|Plus_Percent|Plus|Right_Paren|Slash"
                              r"|Star_Percent|Star|Tilde|Underscore"
                              r"|Colon_Equal|Colon|Comma|Minus_Greater)\b",
                              body))

    #  1.  The same levels, in the same order.
    declared = re.search(r"type Level is\s*\((.*?)\);", text, re.S)
    if not declared:
        out.append((where, 1, "the Level enumeration could not be read"))
        return out

    levels = [n.strip() for n in re.sub(r"--[^\n]*", "", declared.group(1))
              .replace("\n", " ").split(",") if n.strip()]
    wanted = [ada_level(rule) for rule, _, _, _ in chain] \
        + [ada_level(tail), "Level_Primary"]

    if levels != wanted:
        out.append((where, 1,
                    "the levels are %s and the grammar's are %s"
                    % (", ".join(levels), ", ".join(wanted))))

    #  2.  The same operators at each level.
    binary = body_of(text, "Binary_Level")
    if binary is None:
        out.append((where, 1, "Binary_Level could not be read"))
    else:
        table = {}
        for piece in re.split(r"\n\s*when\b", "\n" + binary)[1:]:
            head, arrow, value = piece.partition("=>")
            if not arrow:
                continue
            level = value.strip().rstrip(",").rstrip(")").strip()
            for kind in kinds_in(head):
                table.setdefault(level, set()).add(item_of(kind))

        for rule, _, operators, _ in chain:
            level = ada_level(rule)
            said = table.get(level, set())
            meant = {("lit", op) for op in operators}
            if said != meant:
                out.append((
                    where, 1,
                    "%s spells %s and the grammar's %s spells %s"
                    % (level,
                       ", ".join(sorted(t for k, t in said if k == "lit"))
                       or "nothing",
                       rule, ", ".join(sorted(operators)))))

    #  3.  The same fold.  [1820] writes comparison with '?' and every
    #      other level with '*', and that is the whole of the rule.
    fold = body_of(text, "Fold")
    if fold is None:
        out.append((where, 1, "Fold could not be read"))
    else:
        said = set(re.findall(r"when\s+(Level_[A-Za-z_]+)\s*=>\s*"
                              r"Non_Associative", fold))
        meant = {ada_level(rule) for rule, _, _, repeat in chain
                 if repeat == "?"}
        if said != meant:
            out.append((where, 1,
                        "the table folds %s non-associatively and the "
                        "grammar folds %s"
                        % (", ".join(sorted(said)) or "nothing",
                           ", ".join(sorted(meant)) or "nothing")))

    #  4.  The same prefix operators.
    prefix_rule = rules.get(tail, "")
    found = re.match(r"^\((.*)\)\s*\*\s*([a-z_]+)$", prefix_rule.strip())
    prefix_body = body_of(text, "Is_Prefix")
    if found and prefix_body is not None:
        said = {t for k, t in (item_of(k) for k in kinds_in(prefix_body))
                if k == "lit"}
        meant = set(re.findall(r'"([^"]*)"', found.group(1)))
        if said != meant:
            out.append((where, 1,
                        "Is_Prefix spells %s and the grammar's %s spells %s"
                        % (", ".join(sorted(said)) or "nothing", tail,
                           ", ".join(sorted(meant)))))
    elif prefix_body is None:
        out.append((where, 1, "Is_Prefix could not be read"))
    else:
        out.append((where, 1,
                    "the grammar's %s rule is not a run of prefix "
                    "operators over a primary" % tail))

    #  5.  The first sets, which recovery depends on: a token that begins a
    #      statement in the grammar and not here is a recovery bug that
    #      would be blamed on the parser.
    first, _ = grammar_first(trees)
    literals = kinds_in(body_of(token_text, "Is_Literal") or "")
    prefixes = kinds_in(prefix_body or "")

    for name, rule in (("Begins_Expression", "expression"),
                       ("Begins_Statement", "statement"),
                       ("Begins_Declaration", "declaration")):
        body = body_of(text, name)
        if body is None:
            out.append((where, 1, "%s could not be read" % name))
            continue
        kinds = kinds_in(body)
        if "Is_Literal" in body:
            kinds |= literals
        if "Is_Prefix" in body:
            kinds |= prefixes
        said = {item_of(k) for k in kinds}
        meant = {i for i in first.get(rule, set())
                 if i[0] in ("lit", "token")}
        if said != meant:
            def shown(items):
                return ", ".join(sorted(
                    t if k == "lit" else "<%s>" % t for k, t in items))
            out.append((where, 1,
                        "%s admits %s and the grammar's %s begins with %s"
                        % (name, shown(said) or "nothing", rule,
                           shown(meant))))

    return out


def check_refused_constructs(full_run):
    """The parser's refusal tables are the tour's, and the corpus is pinned.

    [1760] reserves seventeen words, so `loop`, `match` and the rest lex as
    ordinary identifiers and only the parser can meet them.  That makes the
    parser a second authority on what the tour describes, which is one more
    than this repository is willing to have: every spelling it refuses has
    to be a word the tour writes and not one the grammar already spells,
    and every construct it cites has to exist.

    The eleven scalar names get the same treatment from the other side.
    They are ordinary declared names the kernel predeclares [1760], not
    keywords, so nothing in the scanner holds them to `type`; this does.
    """
    if not full_run:
        return []

    parser = os.path.join(ROOT,
                          "compiler/ada/src/syntax/landin-syntax-parser.adb")
    codes = os.path.join(
        ROOT, "compiler/ada/src/diagnostics/landin-diagnostics-syntactic.ads")
    tour = os.path.join(ROOT, SPEC_NAME)
    missing = absent((parser, codes, tour))
    if missing:
        return missing

    out = []
    parser_text = io.open(parser, encoding="utf-8").read()
    codes_text = io.open(codes, encoding="utf-8").read()
    #  Both documents, because a word the parser refuses is written where
    #  the language is explained and not where the kernel is specified:
    #  `loop` and `match` are in the tour and the spec omits them by
    #  design, which is the whole reason the parser has to name them.
    tour_text = "\n".join(
        io.open(os.path.join(ROOT, name), encoding="utf-8").read()
        for name in (SPEC_NAME, TOUR_NAME)
        if os.path.exists(os.path.join(ROOT, name)))
    rules, _, problems = read_grammar(tour)
    if problems:
        return []

    #  Every construct the refusals cite, and whether the tour defines it.
    defined = construct_ids()
    cited = re.findall(r"when\s+([A-Za-z0-9_]+)\s*=>\s*\"\[(\d{4})\]\"",
                       codes_text)
    if not cited:
        out.append((
            "compiler/ada/src/diagnostics/landin-diagnostics-syntactic.ads",
            1, "no refused construct names a paragraph of the tour"))
    for name, construct in cited:
        if construct not in defined:
            out.append((
                "compiler/ada/src/diagnostics"
                "/landin-diagnostics-syntactic.ads", 1,
                "%s names [%s], which neither document defines"
                % (name, construct)))

    #  Every refused construct names the work that enables it, and the
    #  roadmap has to have that item.
    roadmap = os.path.join(ROOT, "ROADMAP.md")
    if os.path.exists(roadmap):
        items = set(re.findall(r"^### (R\d+\.\d+)",
                               io.open(roadmap, encoding="utf-8").read(),
                               re.M))
        for named in set(re.findall(r'=>\s*"(R\d+\.\d+)"', codes_text)):
            if named not in items:
                out.append((
                    "compiler/ada/src/diagnostics"
                    "/landin-diagnostics-syntactic.ads", 1,
                    "%s is named as enabling work and ROADMAP.md has no "
                    "such item" % named))

    #  The spellings, read out of the parser's own tables.
    def spellings(kind):
        found = re.search(r"function Spelling \(Item : %s\) return String"
                          r"\s*is \(case Item is(.*?)\);" % kind,
                          parser_text, re.S)
        if not found:
            return None
        return dict(
            (m.group(1), m.group(2)) for m in
            re.finditer(r"when\s+([A-Za-z0-9_]+)\s*=>\s*\"([^\"]*)\"",
                        found.group(1)))

    keywords = set(re.findall(r'"([a-z]+)"', rules.get("keyword", "")))
    #  [1795] let a type position hold a declared name, so the eleven the
    #  kernel predeclares moved into their own rule.  This reads that one:
    #  `type` now spells no name of its own.
    scalars = set(re.findall(r'"([a-z0-9]+)"',
                             rules.get("scalar_name", "")))

    words = spellings("Real_Word")
    if words is None:
        out.append(("compiler/ada/src/syntax/landin-syntax-parser.adb", 1,
                    "the refused-word table could not be read"))
    else:
        for name, word in sorted(words.items()):
            if word in keywords:
                out.append((
                    "compiler/ada/src/syntax/landin-syntax-parser.adb", 1,
                    "%s refuses %r, which the grammar's keyword rule "
                    "spells, so the scanner meets it first and this row "
                    "is dead" % (name, word)))
            elif not re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])"
                               % re.escape(word), tour_text):
                out.append((
                    "compiler/ada/src/syntax/landin-syntax-parser.adb", 1,
                    "%s refuses %r, which neither document writes"
                    % (name, word)))

    #  [1795] moved the type names the tour writes and the kernel omits
    #  out of the parser: a type position holds any identifier now, so
    #  whether one names a type the kernel lacks is a question about what
    #  it resolved to, and only the checker can ask it.
    checking = os.path.join(
        ROOT, "compiler/ada/src/diagnostics/landin-diagnostics-checking.ads")
    out.extend(absent((checking,)))
    if os.path.exists(checking):
        checking_text = io.open(checking, encoding="utf-8").read()
        found = re.search(
            r"function Spelling \(Item : Refused_Type_Name\) return String"
            r"\s*is \(case Item is(.*?)\);", checking_text, re.S)
        if not found:
            out.append((
                "compiler/ada/src/diagnostics"
                "/landin-diagnostics-checking.ads", 1,
                "the refused-type table could not be read"))
        else:
            refused_types = dict(
                (m.group(1), m.group(2)) for m in
                re.finditer(r"when\s+([A-Za-z0-9_]+)\s*=>\s*\"([^\"]*)\"",
                            found.group(1)))
            for name, word in sorted(refused_types.items()):
                where = ("compiler/ada/src/diagnostics"
                         "/landin-diagnostics-checking.ads")
                if word in scalars:
                    out.append((
                        where, 1,
                        "%s refuses %r, which the grammar's type rule "
                        "spells" % (name, word)))
                elif not re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])"
                                   % re.escape(word), tour_text):
                    out.append((
                        where, 1,
                        "%s refuses %r, which neither document writes"
                        % (name, word)))

    #  The eleven, exactly.  A twelfth here would be a type the grammar
    #  does not have, and a missing one a type no program could name.
    declared = spellings("Scalar_Name")
    if declared is None:
        out.append(("compiler/ada/src/syntax/landin-syntax-parser.adb", 1,
                    "the scalar-type table could not be read"))
    elif set(declared.values()) != scalars:
        out.append((
            "compiler/ada/src/syntax/landin-syntax-parser.adb", 1,
            "the parser's types are %s and the grammar's are %s"
            % (", ".join(sorted(declared.values())),
               ", ".join(sorted(scalars)))))

    #  Landin.Types spells the eleven a second time, because it is the
    #  package that maps each onto a machine width.  Two transcriptions of
    #  one rule is one more than the repository allows to drift, so both
    #  are held to the tour and to each other.
    types = os.path.join(ROOT, "compiler/ada/src/checking/landin-types.ads")
    out.extend(absent((types,)))
    if os.path.exists(types):
        found = re.search(r"function Spelling \(Item : Scalar_Name\)"
                          r"[^;]*?is \(case Item is(.*?)\);",
                          io.open(types, encoding="utf-8").read(), re.S)
        if not found:
            out.append(("compiler/ada/src/checking/landin-types.ads", 1,
                        "the type table could not be read"))
        else:
            spelled = set(re.findall(r'=>\s*"([a-z0-9]+)"', found.group(1)))
            if spelled != scalars:
                out.append((
                    "compiler/ada/src/checking/landin-types.ads", 1,
                    "Landin.Types spells %s and the grammar's type rule "
                    "spells %s"
                    % (", ".join(sorted(spelled)) or "nothing",
                       ", ".join(sorted(scalars)))))
            elif declared is not None \
                    and spelled != set(declared.values()):
                out.append((
                    "compiler/ada/src/checking/landin-types.ads", 1,
                    "Landin.Types and the parser spell different types"))

    #  A negative fixture that names no codes is a rejection nobody
    #  checked the shape of.
    base = os.path.join(ROOT, "compiler/tests/fixtures/negative")
    if os.path.isdir(base):
        for name in sorted(os.listdir(base)):
            meta = os.path.join(base, name, "fixture.meta")
            if not os.path.exists(meta):
                continue
            text = io.open(meta, encoding="utf-8").read()
            if not re.search(r"^program: ", text, re.M):
                continue
            named = re.search(r"^codes: (.*)$", text, re.M)
            if not named or not named.group(1).strip():
                out.append((
                    "compiler/tests/fixtures/negative/%s/fixture.meta"
                    % name, 1,
                    "a negative fixture with a program must name the "
                    "codes its report carries"))

    return out


def catalogue_rows():
    """The catalogue, read out of the Ada table that owns it."""
    spec = os.path.join(ROOT,
                        "compiler/ada/src/diagnostics"
                        "/landin-diagnostics-catalogue.ads")
    if not os.path.exists(spec):
        return None

    text = io.open(spec, encoding="utf-8").read()

    names = re.search(r"type Code_Name is\s*\((.*?)\);", text, re.S)
    if not names:
        return None

    order = [n.strip() for n in re.sub(r"--[^\n]*", "", names.group(1))
             .replace("\n", " ").split(",") if n.strip()]

    def choices(head):
        """The code names one `when` stands for, ranges expanded.

        A band of codes sharing a value is written as a range, because
        twelve identical arms is twelve chances to mistype one.  The
        reading copy has to see through that, or a whole band shows up as
        unknown and nobody notices the column stopped being read.
        """
        out = []
        for part in re.sub(r"--[^\n]*", "", head).split("|"):
            part = part.strip()
            if ".." in part:
                low, _, high = (bit.strip() for bit in part.partition(".."))
                if low in order and high in order:
                    out.extend(order[order.index(low):order.index(high) + 1])
            elif part:
                out.append(part)
        return out

    def column(name):
        found = re.search(r"function %s \(Of_Code : Code_Name\)[^;]*?"
                          r"is \(case Of_Code is(.*?)\);" % name, text, re.S)
        if not found:
            return {}
        arms = {}
        #  Every arm begins a line, and a value may run over several with
        #  `&`, so the arms are cut at the line each `when` starts and the
        #  value is whatever follows the arrow.  Cutting on the bare word
        #  would cut inside a string that happened to contain it.
        for piece in re.split(r"\n\s*when\b", "\n" + found.group(1))[1:]:
            head, arrow, value = piece.partition("=>")
            if not arrow:
                continue
            value = value.strip().rstrip(";").strip().rstrip(")").strip()
            value = value.rstrip(",").strip()
            if '"' in value:
                value = "".join(re.findall(r'"([^"]*)"', value))
            else:
                value = value.split("\n")[0].strip()
            for one in choices(head):
                arms[one] = value
        return arms

    def read(arms, name, fallback="?"):
        return arms.get(name, arms.get("others", fallback))

    codes = column("Code")
    levels = column("Level")
    states = column("State")
    rules = column("Rule")
    secondaries = column("Required_Secondaries")
    notes = column("Required_Notes")

    rows = []
    for name in order:
        rows.append(dict(
            name=name,
            code=read(codes, name),
            level=read(levels, name),
            state=read(states, name),
            rule=read(rules, name),
            secondaries=read(secondaries, name, "0"),
            notes=read(notes, name, "0")))
    return rows


def catalogue_dump():
    """The reading copy, generated from the table that owns the codes."""
    rows = catalogue_rows()
    if rows is None:
        return None

    lines = ["#  Generated by check.py from",
             "#  compiler/ada/src/diagnostics/landin-diagnostics-catalogue.ads,",
             "#  which is where a diagnostic code is written.  Do not edit;",
             "#  regenerate with python3 check.py --catalogue.",
             "#",
             "#  code   state    rule"]
    for row in rows:
        lines.append("%-6s %-8s %s" % (row["code"], row["state"],
                                       row["rule"]))
    return "\n".join(lines) + "\n"


def check_catalogue(full_run):
    """The catalogue owns every code, and nothing else writes one.

    A code literal outside the catalogue is a second place a number can be
    decided, which is how two codes end up meaning one rule.  The reading
    copy is generated, so it cannot drift either.
    """
    if not full_run:
        return []

    rows = catalogue_rows()
    if rows is None:
        return []

    out = []
    catalogue = ("compiler/ada/src/diagnostics"
                 "/landin-diagnostics-catalogue.ads")

    seen = {}
    for row in rows:
        if not re.fullmatch(r"L\d{4}", row["code"]):
            out.append((catalogue, 1, "%s has no code" % row["name"]))
        elif row["code"] in seen:
            out.append((catalogue, 1,
                        "%s and %s share the code %s"
                        % (seen[row["code"]], row["name"], row["code"])))
        else:
            seen[row["code"]] = row["name"]

    #  Every code written in src/ has to be the catalogue's.
    source_root = os.path.join(ROOT, "compiler/ada/src")
    for here, _, files in os.walk(source_root):
        for name in sorted(files):
            if not name.endswith((".ads", ".adb")):
                continue
            path = os.path.join(here, name)
            if path.endswith("landin-diagnostics-catalogue.ads"):
                continue
            text = io.open(path, encoding="utf-8").read()
            for found in re.finditer(r'"(L\d{4})"', text):
                where = os.path.relpath(path, ROOT)
                out.append((where, text.count("\n", 0, found.start()) + 1,
                            "%s is written here and the catalogue is the "
                            "only place a code belongs" % found.group(1)))

    #  And the reading copy is what the table says.
    recorded = os.path.join(ROOT, "compiler/tests/diagnostics.catalogue")
    fresh = catalogue_dump()
    if fresh is not None:
        if not os.path.exists(recorded):
            out.append(("compiler/tests/diagnostics.catalogue", 1,
                        "the catalogue reading copy is missing; regenerate "
                        "it with python3 check.py --catalogue"))
        elif io.open(recorded, encoding="utf-8").read() != fresh:
            out.append(("compiler/tests/diagnostics.catalogue", 1,
                        "the catalogue reading copy is stale; regenerate "
                        "it with python3 check.py --catalogue"))

    #  A fixture may name the codes its report must carry.
    known = {row["code"] for row in rows}
    fixtures = os.path.join(ROOT, "compiler/tests/fixtures")
    for kind in ("positive", "negative"):
        directory = os.path.join(fixtures, kind)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            meta = os.path.join(directory, name, "fixture.meta")
            if not os.path.exists(meta):
                continue
            wanted = re.search(r"^codes: (.+)$",
                               io.open(meta, encoding="utf-8").read(), re.M)
            if not wanted:
                continue
            for code in (c.strip() for c in wanted.group(1).split(",")):
                if code not in known:
                    out.append((
                        "compiler/tests/fixtures/%s/%s/fixture.meta"
                        % (kind, name), 1,
                        "this names %s, which the catalogue does not hold"
                        % code))

    return out


def fixture_constructs():
    """Every `constructs:` a fixture names, held to a paragraph.

    R1.90 indexes the corpus by construct, and an index whose keys are not
    the documents' own keys indexes nothing.  A fixture may name a
    construct the kernel does not enable yet -- a negative fixture for
    `while` is about [1140] -- so the only question here is whether the
    paragraph exists.
    """
    out = []
    known = construct_ids()
    fixtures = os.path.join(ROOT, "compiler/tests/fixtures")
    if not os.path.isdir(fixtures):
        return out

    for kind in sorted(os.listdir(fixtures)):
        directory = os.path.join(fixtures, kind)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            meta = os.path.join(directory, name, "fixture.meta")
            if not os.path.exists(meta):
                continue
            text = io.open(meta, encoding="utf-8").read()
            named = re.search(r"^constructs: (.+)$", text, re.M)
            where = "compiler/tests/fixtures/%s/%s/fixture.meta" % (
                kind, name)

            if not named:
                #  A fixture with a program is written in the language and
                #  so is evidence about some construct of it.  One without
                #  is about the tool, and names none for that reason.
                if re.search(r"^program: ", text, re.M):
                    out.append((where, 1,
                                "this carries a program and names no"
                                " construct it is evidence about"))
                continue

            for one in (c.strip() for c in named.group(1).split(",")):
                if not re.fullmatch(r"\d{4}", one):
                    out.append((where, 1,
                                "`%s` is not a four-digit construct" % one))
                elif one not in known:
                    out.append((where, 1,
                                "this names [%s], which neither document"
                                " defines" % one))

    return out


def lowering_verifies():
    """The lowering stage verifies every Unit it builds.

    `Landin.IR.Verifier`'s header argues that malformed IR cannot be
    caused by a source program, and that is why the `L0400`-`L0499` band
    is unassigned: a code there would promise that some program can
    provoke one.  The same argument is why no fixture can reach the
    verifier, and so why deleting the call would turn every one of its
    rules off without a single case going red.

    A structural check is the only kind that can see that, which is the
    same reason the catalogue owns every code literal: some invariants are
    about where a line is, not about what a run produces.
    """
    where = "compiler/ada/src/stages/landin-stages-lowering.adb"
    path = os.path.join(ROOT, where)
    missing = absent((path,))
    if missing:
        return missing

    text = io.open(path, encoding="utf-8").read()
    if "Landin.IR.Verifier.Verify" in text:
        return []
    return [(where, 1,
             "this builds every Unit and no longer verifies one; no"
             " fixture can catch that, which is why this check exists")]


def fixture_sources():
    """Every file a fixture names is a file that is there.

    `with` names the rest of a module [1840], and a name that points at
    nothing is the same dead data `expect` without `args` already is: the
    fixture would compile one file and claim to have compiled two.
    """
    out = []
    fixtures = os.path.join(ROOT, "compiler/tests/fixtures")
    if not os.path.isdir(fixtures):
        return out

    for kind in sorted(os.listdir(fixtures)):
        directory = os.path.join(fixtures, kind)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            case = os.path.join(directory, name)
            meta = os.path.join(case, "fixture.meta")
            if not os.path.exists(meta):
                continue
            text = io.open(meta, encoding="utf-8").read()
            where = "compiler/tests/fixtures/%s/%s/fixture.meta" % (kind,
                                                                    name)
            for key in ("program", "with"):
                named = re.search(r"^%s: (.+)$" % key, text, re.M)
                if not named:
                    continue
                for one in (f.strip() for f in named.group(1).split(",")):
                    if one and not os.path.exists(os.path.join(case, one)):
                        out.append((where, 1,
                                    "`%s` names %s, which is not here"
                                    % (key, one)))

    return out


def construct_matrix():
    """R1.90's construct matrix, generated from what the corpus says.

    Every `[NNNN]` either document defines, against the evidence there is
    for it.  Three of the columns are three different claims and the
    distinction is the point: a fixture that is *accepted* says the
    compiler took the program, *emitted* says a backend was handed it, and
    *executed* says a machine ran it.  R1.80's audit found four statement
    forms with the first and not the second, so a matrix that folded them
    together would have shown a row that looked covered.

    A construct with no evidence is not automatically a gap: most of the
    tour is not enabled, and a parser that refuses one by name and cites
    the paragraph is an explanation.  What is left after both -- neither
    exercised nor refused -- is what this item has to answer for.
    """
    ids = []
    for name in (TOUR_NAME, SPEC_NAME):
        path = os.path.join(ROOT, name)
        if not os.path.exists(path):
            return None
        text = io.open(path, encoding="utf-8").read()
        for found in re.finditer(r"^### \[(\d{4})\] (.+)$", text, re.M):
            ids.append((found.group(1), name, found.group(2).strip()))
    ids.sort()

    #  What each class of fixture is evidence of.  A runtime fixture is
    #  compiled, emitted and run, so it says all three.
    says = {"positive": ("accepted", "emitted"),
            "runtime": ("accepted", "emitted", "executed"),
            "negative": ("refused",),
            "end-to-end": ("refused",)}

    evidence = {}
    fixtures = os.path.join(ROOT, "compiler/tests/fixtures")
    if os.path.isdir(fixtures):
        for kind in sorted(os.listdir(fixtures)):
            directory = os.path.join(fixtures, kind)
            if not os.path.isdir(directory):
                continue
            for name in sorted(os.listdir(directory)):
                meta = os.path.join(directory, name, "fixture.meta")
                if not os.path.exists(meta):
                    continue
                named = re.search(r"^constructs: (.+)$",
                                  io.open(meta, encoding="utf-8").read(),
                                  re.M)
                if not named:
                    continue
                for one in (c.strip() for c in named.group(1).split(",")):
                    for claim in says.get(kind, ()):
                        evidence.setdefault(one, set()).add(claim)

    #  A construct the parser refuses by name is explained by that refusal.
    refused = set()
    codes = os.path.join(
        ROOT, "compiler/ada/src/diagnostics/landin-diagnostics-syntactic.ads")
    if os.path.exists(codes):
        text = io.open(codes, encoding="utf-8").read()
        refused = set(re.findall(r'"\[(\d{4})\]"', text))

    order = ("accepted", "emitted", "executed", "refused")
    lines = ["#  Generated by check.py from the fixture corpus and the",
             "#  parser's refusal table.  Do not edit; regenerate with",
             "#  python3 check.py --matrix.",
             "#",
             "#  Evidence is what the fixtures *say* they are about, out of",
             "#  their own `constructs:` lists.  A row is therefore a claim",
             "#  by whoever wrote the fixture and not a measurement: a",
             "#  runtime program full of literals says nothing about [1770]",
             "#  unless it names it.  Under-claiming is the expected state",
             "#  of a list seeded from prose, and correcting it is work.",
             "#",
             "#  A construct with no evidence and no refusal is this",
             "#  item's to answer for; see ROADMAP.md R1.90.",
             "#",
             "#  id    defined in  evidence"]

    bare = 0
    for one, where, title in ids:
        has = evidence.get(one, set())
        if one in refused:
            has = has | {"refused by name"}
        if not has:
            bare += 1
        shown = " ".join(w for w in order if w in has)
        if "refused by name" in has:
            shown = (shown + " refused-by-name").strip()
        lines.append("%-6s %-11s %-34s %s"
                     % (one, where.replace(".md", ""),
                        shown or "-", title))

    lines.insert(13, "#  %d constructs, %d with evidence, %d with neither."
                 % (len(ids), len(ids) - bare, bare))
    return "\n".join(lines) + "\n"


def check_matrix(full_run):
    """The matrix is generated, so it cannot drift from the corpus."""
    if not full_run:
        return []

    recorded = os.path.join(ROOT, "compiler/tests/constructs.matrix")
    fresh = construct_matrix()
    if fresh is None:
        return []

    if not os.path.exists(recorded):
        return [("compiler/tests/constructs.matrix", 1,
                 "the construct matrix is missing; regenerate it with "
                 "python3 check.py --matrix")]
    if io.open(recorded, encoding="utf-8").read() != fresh:
        return [("compiler/tests/constructs.matrix", 1,
                 "the construct matrix is stale; regenerate it with "
                 "python3 check.py --matrix")]
    return []


def present(relative):
    """Whether a repository-relative path exists, case included.

    os.path.exists asks the host, and a case-insensitive host answers yes
    for `HANDOFF.md` when the file is `handoff.md`.  That is how a
    reference that reads correctly on macOS failed the Linux gate.  The
    directory listing is the authority instead, which is the same rule
    Landin.Targets keeps one level down: do not ask the host a question
    whose answer is a fact about the host.
    """
    here = ROOT
    #  `./scripts/build.sh` is how a document writes a command, and it
    #  names the same file as `scripts/build.sh`.
    parts = os.path.normpath(relative).split("/")
    if parts[:1] == [".."]:
        return False
    for step in parts[:-1]:
        if not os.path.isdir(os.path.join(here, step)):
            return False
        if step not in os.listdir(here):
            return False
        here = os.path.join(here, step)
    return parts[-1] in os.listdir(here)


def basenames():
    """Every file's bare name, for a reference that omits a path."""
    global _BASENAMES
    if _BASENAMES is None:
        _BASENAMES = set()
        for here, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in dirs
                       if d not in (".git", "build", ".scratch", ".claude")]
            _BASENAMES |= set(files)
    return _BASENAMES


_BASENAMES = None


def check_borrowed_icons(full_run):
    """The borrowed icons are named, explained, and only used if defined.

    `assets/icons.py` holds shapes copied from Lucide and sourcehut, and
    the reason each one is there.  Two things can drift: an icon added to
    the set without a word about what it is for, and a consumer asking
    for one that was never defined.  The second would stop a render --
    icons.py refuses an unknown name -- so this catches the first, and
    catches the second before a render has to.
    """
    if not full_run:
        return []

    module = os.path.join(ROOT, "assets/icons.py")
    site = os.path.join(ROOT, "docs/site/render_html.py")
    for path in (module, site):
        if not os.path.exists(path):
            return []

    text = io.open(module, encoding="utf-8").read()
    defined = set(re.findall(r'^    "([a-z-]+)": \(', text, re.M))
    explained = set(re.findall(r'^    "([a-z-]+)": "', text, re.M))
    out = []
    for name in sorted(defined - explained):
        out.append(("assets/icons.py", 1,
                    "the %s icon is drawn and not explained; give it a "
                    "line in WHY" % name))
    for name in sorted(explained - defined):
        out.append(("assets/icons.py", 1,
                    "WHY names %s, which is not in ICONS" % name))

    used = set(re.findall(r'icons\.use\("([a-z-]+)"', 
                          io.open(site, encoding="utf-8").read()))
    for name in sorted(used - defined):
        out.append(("docs/site/render_html.py", 1,
                    "asks for the %s icon, which assets/icons.py does not "
                    "define" % name))
    return out


def check_icon(full_run):
    """The mark wears the site's own colours, and only one file says which.

    `assets/icon.svg` is the drawing, `assets/landin_icon.py` is every
    rendering of it, and `docs/site/render_html.py` holds the stylesheet
    those renderings have to match: a favicon in a red the page does not
    use is not a smaller mistake than a wrong word, it is one nobody
    notices.  Four values, held to the two `:root` blocks that define them
    and to the drawing's own presentation attributes.
    """
    if not full_run:
        return []

    drawing = os.path.join(ROOT, "assets/icon.svg")
    module = os.path.join(ROOT, "assets/landin_icon.py")
    site = os.path.join(ROOT, "docs/site/render_html.py")
    for path in (drawing, module, site):
        if not os.path.exists(path):
            return []

    out = []
    svg = io.open(drawing, encoding="utf-8").read()
    code = io.open(module, encoding="utf-8").read()
    css = io.open(site, encoding="utf-8").read()

    #  The stylesheet's light values are the first :root, its dark ones the
    #  block the switch turns on over a light system; the other copy, the
    #  one a dark system gets, repeats them and is not read twice.
    blocks = {
        "light": re.search(r":root\{(.*?)\n\}", css, re.S),
        "dark": re.search(r":root:has\(#theme:checked\)\{(.*?)\n  \}",
                          css, re.S),
    }
    theme = {}
    for mode, found in blocks.items():
        if not found:
            out.append((site, 1, "the %s :root block cannot be read, so the "
                                 "icon's colours cannot be checked" % mode))
            continue
        for name in ("bg", "accent"):
            value = re.search(r"--%s:(#[0-9a-f]{6})" % name, found.group(1))
            if value:
                theme[(mode, name)] = value.group(1)

    #  Each constant, the stylesheet variable it copies, and the name a
    #  reader will look for when one of them moves.
    for constant, key in (("PAPER", ("light", "bg")),
                          ("INK", ("dark", "bg")),
                          ("ACCENT", ("light", "accent")),
                          ("ACCENT_DARK", ("dark", "accent"))):
        found = re.search(r"^%s = \"(#[0-9a-f]{6})\"" % constant, code, re.M)
        if not found:
            out.append((module, 1, "%s is not a colour this check can read"
                                   % constant))
            continue
        if key in theme and found.group(1) != theme[key]:
            out.append((module, 1,
                        "%s is %s but --%s in the %s stylesheet is %s"
                        % (constant, found.group(1), key[1], key[0],
                           theme[key])))

    #  The drawing carries the light pair as presentation attributes so it
    #  renders alone; those two are the same two.
    for element, constant in (("plate", "PAPER"), ("mark", "ACCENT")):
        found = re.search(r'class="%s"[^>]*?\sfill="(#[0-9a-f]{6})"'
                          % element, svg, re.S)
        wanted = re.search(r'^%s = "(#[0-9a-f]{6})"' % constant, code, re.M)
        if not found:
            out.append((drawing, 1,
                        "the %s has no fill for landin_icon.py to read"
                        % element))
        elif wanted and found.group(1) != wanted.group(1):
            out.append((drawing, 1, "the %s is %s but %s is %s"
                                    % (element, found.group(1), constant,
                                       wanted.group(1))))

    #  A drawing whose text was never converted is a drawing that renders
    #  in whatever face the host happens to have, which on the Linux gate
    #  is not the one it was drawn in.
    drawn = re.sub(r"<!--.*?-->", "", svg, flags=re.S)
    if re.search(r"<text\b|shape-inside|font-family", drawn):
        out.append((drawing, 1, "the mark is still text: convert it to a "
                                "path so it does not need a font"))

    #  The pages have no external references, so the icon travels in them.
    if "ICON_LINKS" not in css or 'rel="icon"' not in css:
        out.append((site, 1, "the pages carry no favicon"))

    return out


def check_fonts(full_run):
    """The pages are set in two vendored faces, and the subsets have to cover them.

    `assets/fonts.py` is every rendering of the two families, the way
    `landin_icon.py` is every rendering of the mark.  Two things can go
    wrong quietly, and both end the same way -- one paragraph, on one
    page, coming out in a fallback face while every word count balances.

    A `src` url that names a file nobody vendored, which is what a
    half-finished re-vendoring leaves behind.  And a document that has
    drifted outside the ranges the subsets carry: the faces are shipped as
    their sources subset them rather than trimmed to the documents, so
    this is a check the vendoring is still wide enough and not a check the
    documents stayed narrow.
    """
    if not full_run:
        return []

    module = os.path.join(ROOT, "assets/fonts.py")
    site = os.path.join(ROOT, "docs/site/render_html.py")
    for path in (module, site):
        if not os.path.exists(path):
            return []

    out = []
    code = io.open(module, encoding="utf-8").read()
    css = io.open(site, encoding="utf-8").read()

    #  Each family, its own stylesheet, and the ranges its subsets carry.
    families = re.findall(r'family="([^"]+)",\s*\n\s*css="([^"]+)"', code)
    if not families:
        out.append((module, 1, "no vendored family this check can read"))
    covered = {}
    for family, relative in families:
        source = os.path.join(ROOT, "assets/fonts", relative)
        if not os.path.exists(source):
            out.append((module, 1, "%s names %s, which is not vendored"
                                   % (family, relative)))
            continue
        sheet = io.open(source, encoding="utf-8").read()
        spans = []
        for face in re.findall(r"@font-face\s*\{(.*?)\}", sheet, re.S):
            #  A src url that resolves nowhere is a face the browser skips
            #  in silence, falling through to the next subset or the stack.
            for url in re.findall(r"url\(\s*['\"]?([^'\")]+?)['\"]?\s*\)",
                                  face):
                name = os.path.basename(url)
                if not os.path.exists(os.path.join(os.path.dirname(source),
                                                   "woff2", name)):
                    out.append((relative, 1, "asks for %s, which is not in "
                                             "woff2/" % name))
            found = re.search(r"unicode-range:\s*([^;}]+)", face)
            if not found:
                #  No range means the whole of Unicode, which is what an
                #  unsubsetted family says, and it covers everything.
                spans.append((0, 0x10FFFF))
                continue
            for low, high in re.findall(r"U\+([0-9A-Fa-f]+)(?:-([0-9A-Fa-f]+))?",
                                        found.group(1)):
                spans.append((int(low, 16), int(high or low, 16)))
        if not spans:
            out.append((relative, 1, "no @font-face this check can read"))
        else:
            covered[family] = spans

    #  Every document the pages are rendered from, read out of the
    #  renderer rather than listed again here.
    for relative in sorted(set(re.findall(r'src="([^"]+)"', css))):
        path = os.path.join(ROOT, relative)
        if not os.path.exists(path):
            continue
        text = io.open(path, encoding="utf-8").read()
        for family, spans in sorted(covered.items()):
            missing = sorted({
                ch for ch in set(text)
                if ch not in "\n\r\t"
                and not any(low <= ord(ch) <= high for low, high in spans)})
            if missing:
                out.append((relative, 1,
                            "%s has no subset carrying %s; vendor the subset "
                            "that does, in assets/fonts/"
                            % (family, ", ".join("U+%04X" % ord(c)
                                                 for c in missing[:8]))))

    #  The renderer must ask the module for both stacks rather than
    #  spelling a family of its own, and must copy what it asked for.
    for role in ("ui", "mono"):
        if 'fonts.stack("%s")' % role not in css:
            out.append((site, 1, "--%s does not come from assets/fonts.py"
                                 % role))
    if "fonts.files()" not in css:
        out.append((site, 1, "the faces are declared but never copied "
                             "beside the pages"))
    if "fonts.css()" not in css:
        out.append((site, 1, "the pages carry no @font-face block"))

    return out


def check_ascii_dashes(full_run):
    """Prose uses a typographic dash rather than a spaced ASCII pair.

    The renderer preserves source punctuation, as it must: replacing `--`
    while rendering would corrupt Landin comments, command options and code.
    Fences and inline code therefore stay literal, while prose writes an em
    dash directly.  Findings preserve obsolete wording and are excluded for
    the same reason the language checks exclude them.
    """
    if not full_run:
        return []

    paths = [os.path.join(ROOT, name) for name in LIVE_DOCS]
    missing = absent(paths)
    if missing:
        return missing

    inline_code = re.compile(r"`[^`]*`")
    ascii_dash = re.compile(r"(?<!\S)--(?!\S)")
    out = []
    for path in paths:
        name = os.path.relpath(path, ROOT)
        inside, findings = False, False
        for n, line in enumerate(
                io.open(path, encoding="utf-8").read().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("## WHAT THIS ONE FOUND") \
                    or stripped.startswith(
                        "## WHERE THE SPECIFICATION WAS SILENT") \
                    or stripped.startswith("## WHAT WAS TRIED AND DROPPED"):
                findings = True
            if stripped.startswith("```"):
                inside = not inside
                continue
            if not inside and not findings \
                    and ascii_dash.search(inline_code.sub("", line)):
                out.append((name, n,
                            "prose uses standalone '--' instead of an em "
                            "dash"))
    return out


def check_unfenced_code(full_run):
    """A line of Landin outside a fence is a line nothing highlights.

    The .txt form wrote an illustration as a comment beside the prose it
    belonged to, and the conversion to Markdown read the `--` as markup
    rather than as Landin.  Nine such lines landed in the prose, and two
    of them split one example into two blocks with a sentence of code
    between them: rendered, the line loses its highlighting and its
    monospace and reads as a claim the document does not make.  Every
    word survived, so the gate that counted words saw nothing.

    The shape is narrow on purpose.  A declaration or an assignment at
    column 0, or any line carrying a trailing Landin comment, outside a
    fence, in a document that has fences.  Prose does not take that
    shape; the nine lines all did.
    """
    if not full_run:
        return []

    paths = [os.path.join(ROOT, name) for name in LANGUAGE_FILES]
    missing = absent(paths)
    if missing:
        return missing

    #  A trailing comment, or a binding/assignment whose left side is a
    #  name and an optional type.  Backticks mean the line is prose
    #  quoting code, which is the form prose is supposed to use.
    code = re.compile(r"\S {2,}--\s"
                      r"|^[a-z_][a-z0-9_]*(\s*:\s*[A-Za-z_][\w\[\]().]*)?"
                      r"\s*(:=|(?<![=<>!+\-*/%])=(?!=))\s*\S")

    out = []
    for path in paths:
        name = os.path.basename(path)
        inside = False
        for n, line in enumerate(
                io.open(path, encoding="utf-8").read().splitlines(), 1):
            if line.strip().startswith("```"):
                inside = not inside
                continue
            if inside or "`" in line or not line.strip():
                continue
            if line.startswith(("#", "-", "*", "|", ">")):
                continue
            if code.search(line):
                out.append((name, n,
                            "Landin outside a fence, so nothing highlights "
                            "it: %r" % line.strip()[:60]))
    return out


def check_table_shape(full_run):
    """Every row of a table has the cell count its header has.

    A table is the form an aligned list takes, because indented prose is
    a code block.  The renderer builds one cell per unescaped pipe, so a
    row with one pipe too many grows a cell, and an inline code span that
    straddles the new boundary closes in the wrong place: the operator
    table in spec.md rendered `|` and `~` as two broken spans and a stray
    backslash.  Every word was on the page, so the gate that counts words
    saw nothing — which is the same blind spot the unfenced-code check
    was written for.

    A pipe inside a cell is written `\\|`, so a boundary is a pipe with no
    backslash in front of it.
    """
    if not full_run:
        return []

    paths = [os.path.join(ROOT, name) for name in LIVE_DOCS]
    boundary = re.compile(r"(?<!\\)\|")

    out = []
    for path in paths:
        if not os.path.exists(path):
            continue
        name = os.path.basename(path)
        inside = False
        width, header = None, 0
        for n, line in enumerate(
                io.open(path, encoding="utf-8").read().splitlines(), 1):
            if line.strip().startswith("```"):
                inside = not inside
                width = None
                continue
            s = line.strip()
            if inside or not (s.startswith("|") and s.endswith("|")):
                width = None
                continue
            count = len(boundary.split(s)) - 2      # the outer pipes
            if width is None:
                width, header = count, n
                continue
            if count != width:
                out.append((name, n,
                            "table row has %d cells and its header at line "
                            "%d has %d" % (count, header, width)))
        if inside:
            out.append((name, 1, "a fence is never closed"))
    return out


def check_comment_forms(full_run):
    """The tour shows every comment form the grammar spells.

    The three comment openers are demonstrated in the tour by being
    written: the marker of [0010] IS a line comment, and [0020] is a block
    comment containing a nested one.  A conversion that treated those
    markers as markup rather than as content destroyed the whole section
    and every word survived, because `--(`, `)--` and `---` are
    punctuation and the check that gated the conversion counted words.

    So the openers the grammar spells are held to appearing literally in a
    Landin block in the tour.  Narrow on purpose: this is not a general
    claim that every construct is demonstrated, it is the one place where
    the demonstration is punctuation and nothing else was watching it.
    """
    if not full_run:
        return []

    spec = os.path.join(ROOT, SPEC_NAME)
    tour = os.path.join(ROOT, TOUR_NAME)
    missing = absent((spec, tour))
    if missing:
        return missing

    rules, _, problems = read_grammar(spec)
    if problems:
        return []

    #  Every sign the comment rules spell, from the grammar itself.
    spelled = set()
    for name, rule in rules.items():
        if "comment" in name:
            spelled |= {sign for sign in re.findall(r'"([^"]+)"', rule)
                        if sign and not sign[0].isalnum()
                        and not sign.startswith("\\")}

    if not spelled:
        return [(SPEC_NAME, 1,
                 "the comment rules spell no opener, so nothing is checked")]

    shown = set()
    inside = False
    for line in io.open(tour, encoding="utf-8").read().splitlines():
        fence = re.match(r"^```(\S*)\s*$", line.strip())
        if fence:
            inside = fence.group(1).startswith("landin") if not inside else False
            continue
        if inside:
            for sign in spelled:
                if sign in line:
                    shown.add(sign)

    return [(TOUR_NAME, 1,
             "the grammar spells %r and the tour never shows one" % sign)
            for sign in sorted(spelled - shown)]


def check_named_files(full_run):
    """A document or source file that names another names one that exists.

    The move from .txt to Markdown had to change 60 references across 21
    files, and a missed one is invisible: a header citing `tour.md` reads
    perfectly and points at nothing.  So every repository-relative
    filename a live document or an Ada source mentions has to resolve.
    Written after the rename rather than before it, because that is when
    the cost of not having it was obvious.
    """
    if not full_run:
        return []

    out = []
    #  `.ldn` is deliberately absent: a Landin file named in a comment is
    #  almost always an example program a case builds, not a file here.
    named = re.compile(
        r"(?<![\w/.-])((?:[A-Za-z0-9_./-]+/)?[A-Za-z0-9_-]+"
        r"\.(?:md|txt|py|sh|adb|ads|gpr|yml|nix|toml))(?![\w])")

    #  The documents, plus the compiler's own headers, which cite the
    #  specification constantly.
    roots = list(LIVE_DOCS)
    for directory in ("compiler/ada/src", "compiler/ada/tests/src"):
        base = os.path.join(ROOT, directory)
        for here, _, files in os.walk(base):
            for name in sorted(files):
                if name.endswith((".ads", ".adb")):
                    roots.append(os.path.relpath(
                        os.path.join(here, name), ROOT))

    for relative in roots:
        path = os.path.join(ROOT, relative)
        if not os.path.exists(path):
            continue
        ada = relative.endswith((".ads", ".adb"))
        for n, line in enumerate(
                io.open(path, encoding="utf-8").read().splitlines(), 1):
            #  In Ada only a comment names a file as a reference; a name in
            #  a string literal is data a test hands to the compiler.
            if ada:
                comment = line.find("--")
                if comment == -1:
                    continue
                line = line[comment:]
            for found in named.finditer(line):
                target = found.group(1)
                if target in NAMED_FILE_ALLOWLIST:
                    continue
                if present(target):
                    continue
                #  A bare name may sit next to the file that mentions it,
                #  or anywhere in the tree: ROADMAP.md names Ada units by
                #  their file name and not by their path.
                beside = os.path.relpath(
                    os.path.join(os.path.dirname(path), target), ROOT)
                if not beside.startswith("..") and present(beside):
                    continue
                if "/" not in target and target in basenames():
                    continue
                out.append((relative, n,
                            "this names %s, which is not in the repository"
                            % target))
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

    if "--catalogue" in argv:
        text = catalogue_dump()
        if text is None:
            print("the catalogue could not be read")
            return 2
        io.open(os.path.join(ROOT, "compiler/tests/diagnostics.catalogue"),
                "w", encoding="utf-8").write(text)
        print("wrote compiler/tests/diagnostics.catalogue")
        return 0

    if "--matrix" in argv:
        text = construct_matrix()
        if text is None:
            print("the documents could not be read")
            return 2
        io.open(os.path.join(ROOT, "compiler/tests/constructs.matrix"),
                "w", encoding="utf-8").write(text)
        print("wrote compiler/tests/constructs.matrix")
        return 0

    if "--tokens" in argv:
        text = token_dump()
        if text is None:
            print("the grammar has problems; fix those first")
            return 2
        io.open(os.path.join(ROOT, "compiler/tests/lexical.tokens"), "w",
                encoding="utf-8").write(text)
        print("wrote compiler/tests/lexical.tokens")
        return 0
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
    extra += check_token_vocabulary(full_run)
    extra += check_precedence_table(full_run)
    extra += check_refused_constructs(full_run)
    extra += check_comment_forms(full_run)
    extra += check_ascii_dashes(full_run)
    extra += check_unfenced_code(full_run)
    extra += check_table_shape(full_run)
    extra += check_icon(full_run)
    extra += check_fonts(full_run)
    extra += check_borrowed_icons(full_run)
    extra += check_named_files(full_run)
    extra += check_catalogue(full_run)
    if full_run:
        extra += fixture_constructs()
        extra += fixture_sources()
        extra += lowering_verifies()
    extra += check_matrix(full_run)
    for path, line, why in sorted(set(extra)):
        total += 1
        print("%-30s %5d  %s" % (path, line, why))

    print("\n%s" % ("all clean" if not total else "%d problem(s)" % total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
