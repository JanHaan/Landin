#!/usr/bin/env python3
"""The Landin token scanner: one implementation, several consumers.

This is the lexical surface of the language as a highlighter needs to see
it — the reserved words, the token shapes, and the small amount of state a
line cannot decide on its own. It emits classified spans, not markup, so
that every highlighter the repository ships is a rendering of this file
rather than another scanner that drifts away from it:

    docs/site/render_html.py    the reading copies, as HTML spans
    landin_pygments.py          a Pygments lexer, for forges and doc builds
    generate.py                 TextMate, Vim, Notepad++, Nano and Kate

Nothing here is a parser. It is a token scanner with a symbol table
collected from the file itself, which is how a name the file declares
reads the same everywhere it is used. A regex cannot tell the `set` of
[0410] from a variable called `set`, and this does not pretend to: the
contextual words are coloured by position.  The checked tree-sitter grammar
in this directory provides the structural alternative for capable editors.

Standard library only, and no knowledge of any output format. The site
adds citation links and HTML escaping; Pygments maps the classes onto its
own token types.
"""

from __future__ import annotations

import re

# --------------------------------------------------------------------------
# the language
# --------------------------------------------------------------------------

KEYWORDS = {
    # declarations and types
    "type", "struct", "variant", "concept", "is", "distinct", "range", "set",
    "register", "layout", "atom", "soa", "option",
    # control
    "if", "then", "elsif", "else", "end", "while", "do", "for", "in", "loop",
    "break", "continue", "when", "complete", "match", "return", "fail", "try",
    "with", "begin", "unchecked", "defer", "undo", "uninit", "arena",
    # operators spelled as words
    "and", "or", "not",
    # memory and queries
    "ptr", "addr", "sizeof", "alignof", "lenof", "inc", "dec", "any",
    # conventions and attributes
    "mut", "public", "volatile", "align", "link", "extern", "big", "little",
    "escaping", "caller", "fixed", "inout", "sink", "from", "of", "at",
    # modules
    "import", "as",
}

TYPES = {
    "u8", "u16", "u32", "u64", "u128", "i8", "i16", "i32", "i64", "i128",
    "usize", "isize", "f16", "f32", "f64", "bool", "utf8", "utf16", "cstring",
}

# u4, u12, u23 — any width, for the packed fields of [0730]
WIDTH = re.compile(r"^[ui](?:[1-9][0-9]{0,2}|0)$")

CONSTANTS = {"true", "false", "zeroed", "none", "noreturn"}

# the three reserved toolchain modules of [1560]
BUILTIN_MODULES = {"compiler", "assembler", "linker"}

TOKEN = re.compile(
    r"""
      (?P<rawq>\"{3,})
    | (?P<doc>---.*)
    | (?P<bopen>--\()
    | (?P<bclose>\)--)
    | (?P<comment>--.*)
    | (?P<string>"(?:[^"\\\n]|\\.)*")
    | (?P<char>'(?:[^'\\\n]|\\.)')
    | (?P<number>
          0[xX][0-9A-Fa-f_]+(?:\.[0-9A-Fa-f_]+)?(?:[pP][-+]?[0-9]+)?
        | 0[bB][01_]+
        | 0[oO][0-7_]+
        | [0-9][0-9_]*(?:\.(?!\.)[0-9_]+)?(?:[eE][-+]?[0-9]+)?
      )
    | (?P<word>[A-Za-z_][A-Za-z0-9_]*)
    | (?P<op>[-+*/%<>=!&|^~:.,;()\[\]{}?@$#\\]+)
    | (?P<space>\s+)
    """,
    re.VERBOSE,
)

DECL_AFTER = re.compile(r"""^\s*(?:,\s*[A-Za-z_]\w*\s*)*:(?!=)|^\s*:=""")

#  The classes a scan can emit.  A consumer that does not know one of these
#  is a consumer that will silently stop colouring something, so the set is
#  written down rather than left implicit in the branches below.
CLASSES = {
    "k":  "reserved word",
    "t":  "type name, built in or declared by the file",
    "v":  "atom or literal constant",
    "b":  "reserved toolchain module",
    "f":  "name in call position",
    "s":  "name after a dot: a field or a module member",
    "d":  "name being declared",
    "n":  "number literal",
    "q":  "string, character, or raw literal",
    "o":  "operator or punctuation",
    "c":  "comment",
    "cd": "doc comment",
    None: "everything else, including whitespace",
}


def source_lines(text: str):
    """Split only at Landin line endings: LF, CR LF, and CR."""
    start = 0
    for ending in re.finditer(r"\r\n|[\r\n]", text):
        yield text[start:ending.end()]
        start = ending.end()
    if start < len(text):
        yield text[start:]


class Scanner:
    """A line-at-a-time token scanner for Landin source.

    It carries the state a line cannot decide on its own — block comment
    depth and an open raw literal — and a symbol table of the type and atom
    names the file declares, so that a name the file introduced reads the
    same everywhere it is used.

    Scan a file in order: the state is the reason a `--(` on one line still
    comments the next one.
    """

    def __init__(self, types=(), atoms=()):
        self.types = set(types)
        self.atoms = set(atoms)
        self.depth = 0        # --( nesting
        self.raw = None       # open raw literal delimiter

    # -- words -----------------------------------------------------------
    def word_class(self, word, text, start, end):
        if word in KEYWORDS:
            return "k"
        if word in TYPES or WIDTH.match(word):
            return "t"
        if word in CONSTANTS:
            return "v"
        if word in BUILTIN_MODULES:
            return "b"
        if word in self.types:
            return "t"
        if word in self.atoms:
            return "v"
        if text.startswith("(", end):
            return "f"
        previous = start - 1
        while previous >= 0 and text[previous].isspace():
            previous -= 1
        if previous >= 0 and text[previous] == ".":
            return "s"
        return None

    @staticmethod
    def _statement_start(before) -> bool:
        """True when nothing but keywords and punctuation precedes the word."""
        for tok in re.findall(r"[A-Za-z_]\w*|\S", before):
            if tok in KEYWORDS or tok in BUILTIN_MODULES:
                continue
            if not re.match(r"[A-Za-z_]", tok):
                continue
            return False
        return True

    # -- one line --------------------------------------------------------
    def scan(self, text: str, *, classify_words=True):
        """Yield (class, text) for one line, left to right and complete.

        Concatenating the second element of every pair returns the line, so
        a consumer cannot lose a character by not knowing a class.
        """
        pos = 0
        declaration_checked = False

        if self.raw is not None:
            hit = text.find(self.raw)
            if hit < 0:
                yield "q", text
                return
            pos = hit + len(self.raw)
            yield "q", text[:pos]
            self.raw = None

        while pos < len(text):
            if self.depth > 0:
                close = text.find(")--", pos)
                nest = text.find("--(", pos)
                if nest >= 0 and (close < 0 or nest < close):
                    self.depth += 1
                    yield "c", text[pos:nest + 3]
                    pos = nest + 3
                    continue
                if close < 0:
                    yield "c", text[pos:]
                    return
                self.depth -= 1
                yield "c", text[pos:close + 3]
                pos = close + 3
                continue

            m = TOKEN.match(text, pos)
            if not m:
                yield None, text[pos]
                pos += 1
                continue

            kind = m.lastgroup
            body = m.group()
            if kind == "rawq":
                rest = text[m.end():]
                closer = rest.find(body)
                if closer < 0:
                    self.raw = body
                    yield "q", text[pos:]
                    return
                end = m.end() + closer + len(body)
                yield "q", text[pos:end]
                pos = end
            elif kind == "doc":
                yield "cd", body
                pos = m.end()
            elif kind == "comment":
                yield "c", body
                pos = m.end()
            elif kind == "bopen":
                self.depth = 1
                yield "c", body
                pos = m.end()
            elif kind == "bclose":
                yield "c", body
                pos = m.end()
            elif kind in ("string", "char"):
                yield "q", body
                pos = m.end()
            elif kind == "number":
                yield "n", body
                pos = m.end()
            elif kind == "word":
                cls = None
                if classify_words:
                    cls = self.word_class(body, text, pos, m.end())
                    if cls is None and not declaration_checked:
                        #  Once this word is in the prefix, _statement_start
                        #  rejects every later name.  Check the declaration
                        #  suffix and prefix at most once per line.
                        declaration_checked = True
                        if (DECL_AFTER.match(text[m.end():])
                                and self._statement_start(text[:pos])):
                            cls = "d"
                yield cls, body
                pos = m.end()
            elif kind == "op":
                yield "o", body
                pos = m.end()
            else:
                yield None, body
                pos = m.end()

    def known_only(self, text: str) -> bool:
        """True when a fragment holds nothing but language words and symbols.

        This is what tells the attribute list of [0760] from an English
        sentence in the same indented position.
        """
        seen = False
        for m in TOKEN.finditer(text):
            kind = m.lastgroup
            if kind == "space":
                continue
            seen = True
            if kind == "word":
                w = m.group()
                if not (w in KEYWORDS or w in TYPES or WIDTH.match(w)
                        or w in CONSTANTS or w in BUILTIN_MODULES
                        or w in self.types or w in self.atoms):
                    return False
            elif kind in ("doc", "comment", "bopen", "bclose"):
                return False
        return seen


# --------------------------------------------------------------------------
# the symbol table: names the file declares
# --------------------------------------------------------------------------

DECL_TYPE = re.compile(r"^\s*(?:public\s+)?([a-z_]\w*)\s*:\s*type\b")
DECL_ATOM = re.compile(r"^\s*(?:public\s+)?([a-z_][\w,\s]*?)\s*:\s*atom\b")
DECL_ENUM = re.compile(r"^\s*(?:public\s+)?[a-z_]\w*\s*:\s*type\s*=\s*(.*)$")
NAMED_VAL = re.compile(r"\(?\s*([a-z_]\w*)\s*=\s*(?:0[xX][0-9A-Fa-f_]+|\d)")


def collect_symbols(lines):
    """Type and atom names, so a name the file declares reads as one."""
    types, atoms = set(), set()
    scanner = Scanner()
    for line in lines:
        # Keep the declaration regexes anchored to the original line while
        # treating every comment and literal as whitespace.  The scanner
        # carries nested-comment and raw-delimiter state across lines.
        line = "".join(" " * len(body) if kind in ("c", "cd", "q") else body
                       for kind, body in scanner.scan(line, classify_words=False))
        m = DECL_TYPE.match(line)
        if m:
            types.add(m.group(1))
        m = DECL_ATOM.match(line)
        if m:
            for name in m.group(1).split(","):
                name = name.strip()
                if re.fullmatch(r"[a-z_]\w*", name):
                    atoms.add(name)
        m = DECL_ENUM.match(line)
        if m:
            rhs = m.group(1)
            if "|" in rhs or "=" in rhs:
                for name in NAMED_VAL.findall(rhs):
                    atoms.add(name)
                if "|" in rhs and "=" not in rhs:
                    for name in re.findall(r"[a-z_]\w*", rhs):
                        if name not in KEYWORDS:
                            atoms.add(name)
    return types - KEYWORDS - TYPES, atoms - KEYWORDS - TYPES - CONSTANTS
