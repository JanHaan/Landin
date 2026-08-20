#!/usr/bin/env python3
"""Render the Landin specification and prototypes as syntax-highlighted HTML.

    python3 render_html.py                  every document, into site/
    python3 render_html.py tour.txt         one of them
    python3 render_html.py --verify         and check that nothing was dropped
    python3 render_html.py --from ../landin read the text files from elsewhere
    python3 render_html.py --artifact       all five on one page, as a fragment
    python3 render_html.py --audit          how every prose line was classified

The pages are single files with no external references: the stylesheet,
the script and the highlighting are all inlined, so one file can be
opened from disk, mailed, or served as it is.

Nothing here is a parser. The highlighter is a token scanner with a small
symbol table collected from the document itself, and the document parser
knows the shape the specification is written in:

    ----------------------------------------------------------------------
    SECTION TITLE
    ----------------------------------------------------------------------

    -- [NNNN] A construct. The prose runs on, indented under the number,
    --       for as long as it needs to.
    the_code: that = follows(it)

The tour is rendered as a literate document: every construct becomes a
block holding its prose and the code that follows it, and every [NNNN]
citation becomes a link to the construct it names. The prototypes are
rendered as listings, because in those the code is the argument, with
their closing findings pulled out as entries.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SITE = HERE / "site"

VERSION_LINE = "specification 0.1.0"

DOCS = [
    dict(key="tour", src="tour.txt", out="tour.html", kind="tour",
         nav="the tour", group="the specification",
         blurb="The normative specification, as a numbered tour. "
               "Every construct keeps its number."),
    dict(key="p1", group="the prototypes", src="prototype-1-driver.txt", out="prototype-1.html", kind="prototype",
         nav="prototype 1 — driver",
         blurb="A driver from an ugly vendor SVD: GPIO, an interrupt-driven "
               "DMA UART, a vector table, and not one hand-written bitmask."),
    dict(key="p2", group="the prototypes", src="prototype-2-parser.txt", out="prototype-2.html", kind="prototype",
         nav="prototype 2 — parser",
         blurb="A parser that recovers, because a real one must not stop at "
               "the first mistake."),
    dict(key="p3", group="the prototypes", src="prototype-3-containers.txt", out="prototype-3.html", kind="prototype",
         nav="prototype 3 — containers",
         blurb="A generic container library: growing array, small vector, "
               "hash map, arena-backed tree."),
    dict(key="p4", group="the prototypes", src="prototype-4-app.txt", out="prototype-4.html", kind="prototype",
         nav="prototype 4 — application",
         blurb="A hosted application whose shape is decided by its command "
               "line, so it cannot be written without runtime dispatch."),
]

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
    "with", "begin", "unchecked", "defer", "undo", "arena",
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

CITE = re.compile(r"\[((?:\d{4})|(?:[XYZW]\d+))\]")

DECL_AFTER = re.compile(r"""^\s*(?:,\s*[A-Za-z_]\w*\s*)*:(?!=)|^\s*:=""")


def cite_links(escaped: str, links) -> str:
    """Turn [NNNN] and [Zn] in already-escaped text into links."""
    def one(m):
        target = links(m.group(1))
        if not target:
            return m.group(0)
        return f'<a class="cite" href="{target}" data-cite="{m.group(1)}">{m.group(0)}</a>'
    return CITE.sub(one, escaped)


class Highlighter:
    """A line-at-a-time token scanner for Landin source.

    It carries the state a line cannot decide on its own — block comment
    depth and an open raw literal — and a symbol table of the type and atom
    names the document declares, so that a name the file introduced reads
    the same everywhere it is used.
    """

    def __init__(self, types=(), atoms=(), links=lambda ref: None):
        self.types = set(types)
        self.atoms = set(atoms)
        self.links = links
        self.depth = 0        # --( nesting
        self.raw = None       # open raw literal delimiter

    # -- pieces ----------------------------------------------------------
    def _span(self, cls, text):
        return f'<span class="{cls}">{html.escape(text)}</span>'

    def _comment(self, cls, text):
        return f'<span class="{cls}">{cite_links(html.escape(text), self.links)}</span>'

    def word_class(self, word, before, after):
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
        if after.startswith("("):
            return "f"
        if before.rstrip().endswith("."):
            return "s"
        if DECL_AFTER.match(after) and self._statement_start(before):
            return "d"
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
    def line(self, text: str) -> str:
        out = []
        pos = 0

        if self.raw is not None:
            hit = text.find(self.raw)
            if hit < 0:
                return self._span("q", text)
            pos = hit + len(self.raw)
            out.append(self._span("q", text[:pos]))
            self.raw = None

        while pos < len(text):
            if self.depth > 0:
                close = text.find(")--", pos)
                nest = text.find("--(", pos)
                if nest >= 0 and (close < 0 or nest < close):
                    self.depth += 1
                    out.append(self._comment("c", text[pos:nest + 3]))
                    pos = nest + 3
                    continue
                if close < 0:
                    out.append(self._comment("c", text[pos:]))
                    return "".join(out)
                self.depth -= 1
                out.append(self._comment("c", text[pos:close + 3]))
                pos = close + 3
                continue

            m = TOKEN.match(text, pos)
            if not m:
                out.append(html.escape(text[pos]))
                pos += 1
                continue

            kind = m.lastgroup
            body = m.group()
            if kind == "rawq":
                rest = text[m.end():]
                closer = rest.find(body)
                if closer < 0:
                    self.raw = body
                    out.append(self._span("q", text[pos:]))
                    return "".join(out)
                end = m.end() + closer + len(body)
                out.append(self._span("q", text[pos:end]))
                pos = end
            elif kind == "doc":
                out.append(self._comment("cd", body))
                pos = m.end()
            elif kind == "comment":
                out.append(self._comment("c", body))
                pos = m.end()
            elif kind == "bopen":
                self.depth = 1
                out.append(self._comment("c", body))
                pos = m.end()
            elif kind == "bclose":
                out.append(self._comment("c", body))
                pos = m.end()
            elif kind in ("string", "char"):
                out.append(self._span("q", body))
                pos = m.end()
            elif kind == "number":
                out.append(self._span("n", body))
                pos = m.end()
            elif kind == "word":
                cls = self.word_class(body, text[:pos], text[m.end():])
                out.append(self._span(cls, body) if cls else html.escape(body))
                pos = m.end()
            elif kind == "op":
                out.append(self._span("o", body))
                pos = m.end()
            else:
                out.append(html.escape(body))
                pos = m.end()

        return "".join(out)

    def block(self, lines) -> str:
        return "\n".join(self.line(l) for l in lines)

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
# the symbol table: names the document declares
# --------------------------------------------------------------------------

DECL_TYPE = re.compile(r"^\s*(?:public\s+)?([a-z_]\w*)\s*:\s*type\b")
DECL_ATOM = re.compile(r"^\s*(?:public\s+)?([a-z_][\w,\s]*?)\s*:\s*atom\b")
DECL_ENUM = re.compile(r"^\s*(?:public\s+)?[a-z_]\w*\s*:\s*type\s*=\s*(.*)$")
NAMED_VAL = re.compile(r"\(?\s*([a-z_]\w*)\s*=\s*(?:0[xX][0-9A-Fa-f_]+|\d)")


def collect_symbols(lines):
    """Type and atom names, so a name the file declares reads as one."""
    types, atoms = set(), set()
    for line in lines:
        if line.lstrip().startswith("--"):
            body = line.lstrip()[2:].lstrip("-( ")
            if not re.match(r"^\[?\d{0,4}\]?\s*[a-z_]\w*\s*:\s*(type|atom)\b", body):
                continue
            line = body
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


# --------------------------------------------------------------------------
# document shape: rule / title / rule, then a body
# --------------------------------------------------------------------------

RULE = re.compile(r"^-{20,}\s*$")


def split_sections(text):
    """Split a document into its front matter and its sections.

    Three things are written with rules across the page and they have to be
    told apart. A section header is a rule, a title, and a rule. A banner is
    a rule, a block of comment lines, and a rule — the prototypes use those
    to divide one module into parts, and they belong to the body. A lone
    rule with nothing but blank lines after it closes what came before.
    """
    lines = text.split("\n")
    sections = []
    cur = None
    i = 0
    while i < len(lines):
        if not RULE.match(lines[i]):
            if cur is not None:
                cur["body"].append(lines[i])
            i += 1
            continue

        j = i + 1
        while j < len(lines) and not RULE.match(lines[j]):
            j += 1
        band = [b for b in lines[i + 1:j] if b.strip()]
        if j >= len(lines) or not band:
            i = j                       # a closing rule; the next one decides
            continue
        if band[0].lstrip().startswith("--"):
            if cur is not None:         # a banner inside a body, kept whole
                cur["body"].extend(lines[i:j + 1])
            i = j + 1
            continue
        cur = dict(title=band[0].strip(), note=band[1:], body=[])
        sections.append(cur)
        i = j + 1

    front = sections.pop(0) if sections else dict(title="", note=[], body=[])
    return front, sections


def split_banners(body):
    """A prototype body, as listings and the banners that divide them."""
    out, run = [], []

    def flush():
        while run and not run[0].strip():
            run.pop(0)
        while run and not run[-1].strip():
            run.pop()
        if run:
            out.append(("code", [l.rstrip() for l in run]))
        run.clear()

    i = 0
    while i < len(body):
        if RULE.match(body[i]):
            j = i + 1
            while j < len(body) and not RULE.match(body[j]):
                j += 1
            text = [b.strip().lstrip("-").strip() for b in body[i + 1:j] if b.strip()]
            flush()
            if text:
                out.append(("banner", " ".join(text)))
            i = j + 1
            continue
        run.append(body[i])
        i += 1
    flush()
    return out


# --------------------------------------------------------------------------
# the tour: numbered constructs, their prose, and the code under them
# --------------------------------------------------------------------------

ITEM = re.compile(r"^(\s*)-- \[(\d{4})\](?: (.*)|)$")
CONT = re.compile(r"^(\s*)--( {2,})(\S.*)$")
CODE_ITEM = re.compile(r"^\s*(?:--\(|---|--) \[(\d{4})\]")

PROSE_INDENT = 7          # -- and seven spaces, under the [NNNN]
PROSE_CONT_SPACE = 5      # less than that is a comment inside code
FILL_COLUMN = 70          # the width the file is hand-wrapped to
SENTENCE_END = re.compile(r"[.?]$")


def sample_like(text: str) -> bool:
    """Is an indented prose line a code sample rather than a sentence?"""
    if re.search(r"\S {2,}\S", text):           # aligned columns
        return True
    if re.match(r"^[\w.]+\s*:=", text):
        return True
    if re.match(r"^[\w.]+:\s", text) and "=" in text:
        return True
    return False


def parse_tour_body(body):
    """A section body becomes constructs, each holding prose and code.

    A construct opens at '-- [NNNN]'. Its prose continues on any line whose
    first characters are '--' followed by enough space to sit under the
    number, even across an intervening listing, which is how a construct
    that shows code and then keeps talking is written. A '--' with less
    space than that is a comment inside code and stays there. Everything
    else is code, and belongs to the construct it follows; code before the
    first construct is the section's own preamble.
    """
    items = [dict(id=None, children=[], anchors=[])]
    prose = []      # (pad, text, source line length)
    opening = None  # the run that starts with the '-- [NNNN]' line itself
    code = []
    blanks = []

    def flush_prose():
        nonlocal prose
        if not prose:
            return
        para, pre = [], []

        def close_para():
            if para:
                items[-1]["children"].append(("p", " ".join(para)))
                para.clear()

        def close_pre():
            if pre:
                strip = min(len(l) - len(l.lstrip()) for l in pre if l.strip())
                items[-1]["children"].append(
                    ("pre", [l[strip:] if l.strip() else "" for l in pre]))
                pre.clear()

        for idx, (pad, text, width) in enumerate(prose):
            # the line carrying the number states the construct; it is never
            # a sample, however much 'Comparison: == <> < <=' looks like one
            first = idx == 0 and pad == PROSE_INDENT and prose is opening
            if not first and (pad > PROSE_INDENT
                              or (pad == PROSE_INDENT and sample_like(text))):
                close_para()
                pre.append(" " * (pad - PROSE_INDENT) + text)
                continue
            close_pre()
            if para:
                prev_pad, prev, prev_width = prose[idx - 1]
                room = prev_width + 1 + len(text.split()[0])
                if SENTENCE_END.search(prev) and room <= FILL_COLUMN:
                    close_para()        # the file could have fitted the next
                                        # word on the line above and did not,
                                        # so the break was meant
            para.append(text)
        close_para()
        close_pre()
        prose = []

    def flush_code():
        nonlocal code
        while code and not code[0].strip():
            code.pop(0)
        while code and not code[-1].strip():
            code.pop()
        if code:
            for line in code:
                m = CODE_ITEM.match(line)
                if m:
                    items[-1]["anchors"].append(m.group(1))
            items[-1]["children"].append(("code", code))
        code = []

    for line in body:
        m = ITEM.match(line)
        if m:
            flush_prose()
            flush_code()
            blanks = []
            items.append(dict(id=m.group(2), children=[], anchors=[]))
            prose.append((PROSE_INDENT, (m.group(3) or "").strip(), len(line)))
            opening = prose
            continue

        m = CONT.match(line)
        if m and len(m.group(2)) >= PROSE_CONT_SPACE:
            flush_code()
            blanks = []
            prose.append((len(m.group(2)), m.group(3), len(line)))
            continue

        if not line.strip():
            blanks.append(line)
            continue

        flush_prose()
        opener = CODE_ITEM.match(line)
        if opener and not code:
            flush_code()                # '--( [0020]' and '--- [0030]' are
            items.append(dict(id=opener.group(1),   # constructs whose text is
                              children=[], anchors=[]))   # itself the example
        if code and blanks:
            code.extend(blanks)         # a blank line inside one listing
        blanks = []
        code.append(line.rstrip())

    flush_prose()
    flush_code()
    if not items[0]["children"]:
        items.pop(0)
    return items


# --------------------------------------------------------------------------
# the prototypes: listings, and the findings at the end
# --------------------------------------------------------------------------

FINDING = re.compile(r"^([XYZW]\d+)\s+(\S.*)$")
FINDING_SAMPLE = 8    # indented further than an entry's own text


def parse_findings(body):
    """The closing section of a prototype: prose, then F1 .. Fn.

    An entry starts at the left margin, its text is indented under the
    label, and a line indented further than that is a sample it quotes.
    """
    lead, entries = [], []
    cur = None

    def add(target, kind, payload):
        if kind == "p":
            if target and target[-1][0] == "p":
                target[-1] = ("p", target[-1][1] + " " + payload)
                return
        elif kind == "pre":
            if target and target[-1][0] == "pre":
                target[-1][1].append(payload)
                return
            payload = [payload]
        target.append((kind, payload))

    for line in body:
        m = FINDING.match(line)
        if m:
            cur = dict(id=m.group(1), children=[])
            entries.append(cur)
            add(cur["children"], "p", m.group(2).strip())
            continue
        if not line.strip():
            target = cur["children"] if cur else lead
            if target and target[-1][0] == "p":
                target.append(("p", ""))     # a paragraph boundary
            continue
        indent = len(line) - len(line.lstrip())
        target = cur["children"] if cur else lead
        if target and target[-1] == ("p", ""):
            target.pop()
            target.append(("p", line.strip()))
            continue
        if cur and indent >= FINDING_SAMPLE:
            add(target, "pre", line.rstrip())
        else:
            add(target, "p", line.strip())

    for e in entries:
        e["children"] = [c for c in e["children"] if c[1]]
    return [c for c in lead if c[1]], entries


def parse_plain(body):
    """Free text: paragraphs, bullet runs, indented blocks."""
    blocks = []
    run = []
    kind = None

    def flush():
        nonlocal run, kind
        if run:
            blocks.append((kind, list(run)))
        run, kind = [], None

    for line in body:
        if not line.strip():
            flush()
            continue
        indent = len(line) - len(line.lstrip())
        want = "quote" if indent else "para"
        if kind and kind != want:
            flush()
        kind = want
        run.append(line.rstrip())
    flush()

    out = []
    for k, lines in blocks:
        if k == "quote":
            indents = {len(l) - len(l.lstrip()) for l in lines}
            if len(indents) > 1:
                strip = min(indents)
                out.append(("pre", [l[strip:] for l in lines]))
            else:
                out.append(("quote", " ".join(l.strip() for l in lines)))
        else:
            out.append(("para", " ".join(lines)))
    return out

# --------------------------------------------------------------------------
# the page
# --------------------------------------------------------------------------

CSS = """
:root{
  color-scheme: light;
  --bg:#f7f6f2; --bg-soft:#efece5; --panel:#fffefb; --panel-2:#f2efe8;
  --ink:#1c2128; --ink-soft:#5a6270; --ink-faint:#8b9199;
  --rule:#dedad0; --rule-soft:#e9e5dc;
  --accent:#a03526; --accent-soft:#c4705f; --accent-bg:#f6ece9;
  --code-bg:#fbfaf6; --code-rule:#e4e0d5;
  --k:#9a2f6b; --t:#0f6f68; --f:#2c4c8c; --d:#243b6b; --n:#7a4bab;
  --q:#4a6a1f; --c:#8a8880; --cd:#5f6f4a; --o:#7b7f88; --b:#8a5a12;
  --sh:0 1px 2px rgba(20,20,20,.05), 0 6px 20px rgba(20,20,20,.04);
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    color-scheme: dark;
    --bg:#12161c; --bg-soft:#171c24; --panel:#161b23; --panel-2:#1b212b;
    --ink:#dfe4ec; --ink-soft:#9aa3b1; --ink-faint:#6d7683;
    --rule:#2a313c; --rule-soft:#222933;
    --accent:#e2705c; --accent-soft:#b6543f; --accent-bg:#241a17;
    --code-bg:#0f1319; --code-rule:#232a34;
    --k:#f0919d; --t:#6fd3c2; --f:#93bcff; --d:#b9cdf5; --n:#cbaaf2;
    --q:#b3d178; --c:#7a828f; --cd:#a9bd93; --o:#8b93a1; --b:#e0ae6a;
    --sh:0 1px 2px rgba(0,0,0,.3), 0 8px 26px rgba(0,0,0,.28);
  }
}
:root[data-theme="dark"]{
  color-scheme: dark;
  --bg:#12161c; --bg-soft:#171c24; --panel:#161b23; --panel-2:#1b212b;
  --ink:#dfe4ec; --ink-soft:#9aa3b1; --ink-faint:#6d7683;
  --rule:#2a313c; --rule-soft:#222933;
  --accent:#e2705c; --accent-soft:#b6543f; --accent-bg:#241a17;
  --code-bg:#0f1319; --code-rule:#232a34;
  --k:#f0919d; --t:#6fd3c2; --f:#93bcff; --d:#b9cdf5; --n:#cbaaf2;
  --q:#b3d178; --c:#7a828f; --cd:#a9bd93; --o:#8b93a1; --b:#e0ae6a;
  --sh:0 1px 2px rgba(0,0,0,.3), 0 8px 26px rgba(0,0,0,.28);
}

*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%; scroll-behavior:smooth; scroll-padding-top:4.5rem}
body{
  margin:0; background:var(--bg); color:var(--ink);
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,"Helvetica Neue",sans-serif;
  font-size:16.5px; line-height:1.62;
  font-feature-settings:"kern" 1,"liga" 1;
}
code,pre,.mono,.tag,.cite{
  font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
}
code{
  font-size:.88em; padding:.05rem .28rem; color:var(--ink);
  background:var(--panel-2); border:1px solid var(--rule-soft); border-radius:3px;
}
a{color:var(--accent); text-decoration-color:color-mix(in srgb, var(--accent) 35%, transparent); text-underline-offset:2px}

/* ---- top bar ---- */
header.bar{
  position:sticky; top:0; z-index:40;
  display:flex; align-items:center; gap:.75rem;
  padding:.5rem .9rem;
  background:color-mix(in srgb, var(--bg) 88%, transparent);
  backdrop-filter:saturate(1.4) blur(10px);
  border-bottom:1px solid var(--rule);
}
header.bar .brand{
  font-weight:700; letter-spacing:.16em; font-size:.72rem; text-transform:uppercase;
  color:var(--accent); text-decoration:none; white-space:nowrap;
}
header.bar .where{
  font-size:.74rem; color:var(--ink-faint); letter-spacing:.06em;
  text-transform:uppercase; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
}
header.bar .grow{flex:1}
header.bar button, .toggle{
  font:inherit; font-size:.72rem; letter-spacing:.08em; text-transform:uppercase;
  color:var(--ink-soft); background:var(--panel); cursor:pointer;
  border:1px solid var(--rule); border-radius:5px; padding:.3rem .55rem;
}
header.bar button:hover{color:var(--ink); border-color:var(--ink-faint)}
#menu{display:none}

/* ---- layout ---- */
.wrap{display:grid; grid-template-columns:17rem minmax(0,1fr); gap:0; align-items:start}
nav.side{
  position:sticky; top:3.1rem; align-self:start;
  height:calc(100vh - 3.1rem); overflow:auto;
  padding:1.4rem 1rem 3rem 1.4rem; border-right:1px solid var(--rule);
}
nav.side h3{
  margin:1.4rem 0 .45rem; font-size:.66rem; letter-spacing:.14em;
  text-transform:uppercase; color:var(--ink-faint); font-weight:600;
}
nav.side h3:first-child{margin-top:0}
nav.side a{
  display:block; padding:.22rem .45rem; margin-left:-.45rem;
  color:var(--ink-soft); text-decoration:none; font-size:.86rem;
  border-radius:4px; line-height:1.35;
}
nav.side a:hover{background:var(--panel-2); color:var(--ink)}
nav.side a.here{color:var(--accent); background:var(--accent-bg); font-weight:600}
nav.side a.doc{font-size:.88rem}
nav.side .sect{display:flex; gap:.5rem; align-items:baseline}
nav.side .sect .num{font-size:.66rem; color:var(--ink-faint); min-width:1.4rem; font-variant-numeric:tabular-nums}
#find{
  width:100%; font:inherit; font-size:.85rem; padding:.4rem .55rem;
  color:var(--ink); background:var(--panel); border:1px solid var(--rule); border-radius:5px;
}
#find:focus{outline:2px solid var(--accent-soft); outline-offset:1px}
#found{font-size:.72rem; color:var(--ink-faint); padding:.35rem .1rem 0}

main{padding:2.2rem 2.4rem 6rem; min-width:0; max-width:64rem}

/* ---- hero ---- */
.hero{border-bottom:1px solid var(--rule); padding-bottom:1.6rem; margin-bottom:.6rem}
.hero .kind{font-size:.7rem; letter-spacing:.16em; text-transform:uppercase; color:var(--accent)}
.hero h1{
  margin:.5rem 0 .9rem; font-size:clamp(1.5rem, 1.1rem + 1.6vw, 2.1rem);
  line-height:1.15; letter-spacing:-.015em; font-weight:700;
}
.hero p{margin:.55rem 0; max-width:44rem; color:var(--ink-soft)}
.hero p:first-of-type{color:var(--ink); font-size:1.06rem}
.hero pre, .plain pre{
  margin:.7rem 0; padding:.7rem .85rem; overflow-x:auto;
  background:var(--panel-2); border-left:2px solid var(--rule);
  font-size:.82rem; line-height:1.5; color:var(--ink-soft);
}
.hero blockquote, .plain blockquote{
  margin:.7rem 0; padding:.1rem 0 .1rem .95rem;
  border-left:2px solid var(--rule); color:var(--ink-soft); max-width:44rem;
}

/* ---- sections ---- */
section{padding-top:2.4rem; scroll-margin-top:4rem}
section > h2{
  margin:0 0 1.1rem; font-size:.82rem; font-weight:700;
  letter-spacing:.13em; text-transform:uppercase; color:var(--ink);
  display:flex; align-items:center; gap:.7rem;
}
section > h2::after{content:""; flex:1; height:1px; background:var(--rule)}
section > h2 .mod{font-family:ui-monospace,SFMono-Regular,Menlo,monospace; text-transform:none; letter-spacing:0; color:var(--accent)}
section > h2 .of{color:var(--ink-faint); font-weight:500; text-transform:none; letter-spacing:.02em}
section > .note{margin:-.5rem 0 1.4rem; color:var(--ink-soft); font-size:.92rem; max-width:44rem}

/* ---- one construct ---- */
.item{position:relative; padding:0 0 1.5rem 0; scroll-margin-top:4.5rem}
.item .tag{
  display:inline-block; font-size:.68rem; letter-spacing:.04em;
  color:var(--ink-faint); background:var(--panel-2);
  border:1px solid var(--rule-soft); border-radius:4px;
  padding:.05rem .3rem; text-decoration:none; margin-bottom:.3rem;
}
.item .tag:hover{color:var(--accent); border-color:var(--accent-soft)}
.item:target .tag, .item.lit .tag{color:var(--accent); background:var(--accent-bg); border-color:var(--accent-soft)}
.item p{margin:0 0 .75rem; max-width:44rem}
.item p:last-child{margin-bottom:0}
@media (min-width:70rem){
  .item{padding-left:4.2rem}
  .item .tag{position:absolute; left:0; top:.28rem; margin:0}
}

/* ---- code ---- */
.listing{position:relative; margin:.35rem 0 1rem}
.listing pre{
  margin:0; padding:.8rem 1rem; overflow-x:auto;
  background:var(--code-bg); border:1px solid var(--code-rule);
  border-left:2px solid var(--accent-soft); border-radius:5px;
  font-size:.845rem; line-height:1.55; tab-size:4;
}
.listing.cont pre{border-left-color:var(--rule)}
.listing .copy{
  position:absolute; top:.4rem; right:.4rem; opacity:0;
  font:inherit; font-size:.64rem; letter-spacing:.08em; text-transform:uppercase;
  color:var(--ink-faint); background:var(--panel); cursor:pointer;
  border:1px solid var(--rule); border-radius:4px; padding:.15rem .4rem;
  transition:opacity .12s;
}
.listing:hover .copy, .listing .copy:focus{opacity:1}
pre.sample{
  margin:.15rem 0 .85rem; padding:.5rem .8rem; overflow-x:auto;
  background:var(--panel-2); border-left:2px solid var(--rule);
  font-size:.82rem; line-height:1.55;
}
.k{color:var(--k)} .t{color:var(--t)} .f{color:var(--f)} .d{color:var(--d); font-weight:600}
.n{color:var(--n)} .q{color:var(--q)} .v{color:var(--b)} .b{color:var(--b); font-weight:600}
.s{color:var(--ink)} .o{color:var(--o)}
.c{color:var(--c); font-style:italic} .cd{color:var(--cd)}
pre a.cite, pre a.cite:hover{color:inherit; text-decoration-style:dotted}

/* ---- citations ---- */
a.cite{font-size:.92em; text-decoration:none; border-bottom:1px dotted var(--accent-soft)}
a.cite:hover{background:var(--accent-bg)}
#pop{
  position:absolute; z-index:60; max-width:29rem; display:none;
  padding:.6rem .75rem; font-size:.86rem; line-height:1.5;
  color:var(--ink); background:var(--panel); box-shadow:var(--sh);
  border:1px solid var(--rule); border-radius:6px;
}
#pop .tag{font-size:.68rem; color:var(--accent); display:block; margin-bottom:.2rem}

/* ---- findings ---- */
.finding{padding:0 0 1.4rem 0; scroll-margin-top:4.5rem; position:relative}
.finding .tag{
  display:inline-block; font-size:.7rem; font-weight:700; letter-spacing:.05em;
  color:var(--accent); background:var(--accent-bg);
  border:1px solid var(--accent-soft); border-radius:4px;
  padding:.05rem .35rem; margin-bottom:.35rem; text-decoration:none;
}
.finding p{margin:0 0 .65rem; max-width:44rem}
@media (min-width:70rem){
  .finding{padding-left:4.2rem}
  .finding .tag{position:absolute; left:0; top:.2rem; margin:0}
}

/* ---- index page ---- */
.cards{display:grid; gap:1rem; grid-template-columns:repeat(auto-fit,minmax(17rem,1fr)); margin:2rem 0}
.card{
  display:block; padding:1rem 1.1rem; text-decoration:none; color:inherit;
  background:var(--panel); border:1px solid var(--rule); border-radius:8px;
}
.card:hover{border-color:var(--accent-soft); box-shadow:var(--sh)}
.card strong{display:block; font-size:.95rem; margin-bottom:.3rem}
.card span{display:block; color:var(--ink-soft); font-size:.87rem; line-height:1.5}
.card em{display:block; margin-top:.5rem; font-style:normal; font-size:.7rem;
  letter-spacing:.1em; text-transform:uppercase; color:var(--ink-faint)}

footer{
  margin-top:3rem; padding-top:1.2rem; border-top:1px solid var(--rule);
  color:var(--ink-faint); font-size:.8rem; max-width:44rem;
}
footer code{font-size:.9em; color:var(--ink-soft)}
.hide{display:none !important}
nav.side a.sect{display:flex; gap:.55rem; align-items:baseline}
nav.side a.sect .num{
  font-size:.66rem; color:var(--ink-faint); min-width:1.5rem;
  text-align:right; font-variant-numeric:tabular-nums;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
}
.anchor{position:absolute; scroll-margin-top:4.5rem}
.lead{margin-bottom:1rem}
h3.banner{
  margin:2rem 0 .7rem; font-size:.98rem; font-weight:500; line-height:1.55;
  color:var(--ink-soft); max-width:44rem; padding-left:.9rem;
  border-left:2px solid var(--accent-soft);
}
ul.bullets{list-style:none; margin:0; padding:0; max-width:44rem}
ul.bullets li{
  position:relative; padding:.42rem 0 .42rem 1.1rem;
  border-bottom:1px solid var(--rule-soft); font-size:.96rem;
}
ul.bullets li:last-child{border-bottom:0}
ul.bullets li::before{
  content:""; position:absolute; left:0; top:1.05em;
  width:.5rem; height:1px; background:var(--accent);
}
p.dropped{
  max-width:44rem; padding-left:1.6rem; text-indent:-1.6rem;
  border-left:2px solid var(--rule-soft); padding-top:.1rem;
  margin:0 0 .9rem; padding-left:2.6rem; text-indent:-1rem;
}

@media (max-width:60rem){
  .wrap{grid-template-columns:minmax(0,1fr)}
  nav.side{
    position:fixed; inset:3.1rem 0 auto 0; height:auto; max-height:75vh;
    background:var(--bg); border-right:0; border-bottom:1px solid var(--rule);
    z-index:35; display:none;
  }
  nav.side.open{display:block}
  #menu{display:inline-block}
  main{padding:1.5rem 1.1rem 5rem}
}
@media print{
  header.bar, nav.side, .listing .copy{display:none}
  .wrap{display:block}
  main{max-width:none; padding:0}
  .listing pre, pre.sample{white-space:pre-wrap}
  a{color:inherit}
}
"""

JS = """
(function(){
  var root=document.documentElement;
  var saved=null;
  try{ saved=localStorage.getItem('landin-theme'); }catch(e){}
  if(saved){ root.setAttribute('data-theme',saved); }
  var tog=document.getElementById('theme');
  if(tog) tog.addEventListener('click',function(){
    var now=root.getAttribute('data-theme');
    if(!now) now=matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';
    var next=now==='dark'?'light':'dark';
    root.setAttribute('data-theme',next);
    try{ localStorage.setItem('landin-theme',next); }catch(e){}
  });

  var side=document.querySelector('nav.side');
  var menu=document.getElementById('menu');
  if(menu) menu.addEventListener('click',function(){ side.classList.toggle('open'); });
  if(side) side.addEventListener('click',function(e){
    if(e.target.closest('a')) side.classList.remove('open');
  });

  /* copy a listing */
  document.addEventListener('click',function(e){
    var b=e.target.closest('.copy'); if(!b) return;
    var pre=b.parentNode.querySelector('pre');
    navigator.clipboard.writeText(pre.innerText).then(function(){
      var was=b.textContent; b.textContent='copied';
      setTimeout(function(){ b.textContent=was; },1100);
    });
  });

  /* which section am I in */
  var where=document.getElementById('where');
  var links={}, sections=[].slice.call(document.querySelectorAll('main section'));
  document.querySelectorAll('nav.side a.sect').forEach(function(a){
    links[a.getAttribute('href').slice(1)]=a;
  });
  if(sections.length && 'IntersectionObserver' in window){
    var seen=new Set();
    var io=new IntersectionObserver(function(es){
      es.forEach(function(e){ e.isIntersecting?seen.add(e.target):seen.delete(e.target); });
      var first=sections.filter(function(s){ return seen.has(s); })[0];
      if(!first) return;
      if(where) where.textContent=first.dataset.title||'';
      Object.keys(links).forEach(function(k){ links[k].classList.toggle('here',k===first.id); });
    },{rootMargin:'-72px 0px -70% 0px'});
    sections.forEach(function(s){ io.observe(s); });
  }

  /* filter */
  var find=document.getElementById('find'), count=document.getElementById('found');
  document.querySelectorAll('.item, .finding').forEach(function(u){
    u.dataset.text=(u.textContent||'').toLowerCase();
  });
  function scope(){ return document.querySelector('.doc.on') || document; }
  function filter(){
    var here=scope();
    var units=[].slice.call(here.querySelectorAll('.item, .finding'));
    var secs=[].slice.call(here.querySelectorAll('section'));
    var q=find.value.trim().toLowerCase();
    if(!q){
      units.forEach(function(u){ u.classList.remove('hide'); });
      secs.forEach(function(s){ s.classList.remove('hide'); });
      count.textContent=''; return;
    }
    var hits=0;
    units.forEach(function(u){
      var ok=u.dataset.text.indexOf(q)>=0 || (u.id||'').indexOf(q)===0;
      u.classList.toggle('hide',!ok); if(ok) hits++;
    });
    secs.forEach(function(s){
      var any=s.querySelector('.item:not(.hide), .finding:not(.hide)');
      s.classList.toggle('hide', !any && s.querySelector('.item, .finding'));
    });
    count.textContent=hits+(hits===1?' match':' matches');
  }
  window.landinFilter=filter;
  if(find){
    find.addEventListener('input',filter);
    find.addEventListener('keydown',function(e){
      if(e.key==='Escape'){ find.value=''; filter(); find.blur(); }
    });
  }
  document.addEventListener('keydown',function(e){
    if(e.key==='/' && find && document.activeElement!==find){ e.preventDefault(); find.focus(); }
  });

  /* what a citation says, without leaving the line */
  var pop=document.getElementById('pop');
  function hide(){ if(pop) pop.style.display='none'; }
  document.addEventListener('mouseover',function(e){
    var a=e.target.closest('a.cite'); if(!a||!pop) return;
    var href=a.getAttribute('href');
    if(href.charAt(0)!=='#') return;
    var t=document.getElementById(href.slice(1)); if(!t) return;
    var p=t.querySelector('p'); if(!p) return;
    pop.innerHTML='<span class="tag mono">['+a.dataset.cite+']</span>';
    pop.appendChild(document.createTextNode(p.textContent));
    pop.style.display='block';
    var r=a.getBoundingClientRect(), w=pop.offsetWidth, h=pop.offsetHeight;
    var left=Math.min(r.left+window.scrollX, window.scrollX+innerWidth-w-16);
    var top=r.top+window.scrollY-h-8;
    if(top<window.scrollY+8) top=r.bottom+window.scrollY+8;
    pop.style.left=Math.max(window.scrollX+8,left)+'px';
    pop.style.top=top+'px';
  });
  document.addEventListener('mouseout',function(e){
    if(e.target.closest('a.cite')) hide();
  });
  window.addEventListener('scroll',hide,{passive:true});

  /* light up the construct a link arrives at */
  function lit(){
    document.querySelectorAll('.lit').forEach(function(n){ n.classList.remove('lit'); });
    if(location.hash.length>1){
      var t=document.getElementById(location.hash.slice(1));
      if(t) t.classList.add('lit');
    }
  }
  window.addEventListener('hashchange',lit); lit();
})();
"""


def esc(text):
    return html.escape(text, quote=False)

ARTIFACT_CSS = """
.doc{display:none}
.doc.on{display:block}
nav.side .secs{display:none}
nav.side .secs.on{display:block}
nav.side button.doc{
  display:block; width:100%; text-align:left; font:inherit; font-size:.88rem;
  color:var(--ink-soft); background:none; border:0; border-radius:4px;
  padding:.26rem .45rem; margin-left:-.45rem; cursor:pointer; line-height:1.35;
}
nav.side button.doc:hover{background:var(--panel-2); color:var(--ink)}
nav.side button.doc[aria-current="true"]{
  color:var(--accent); background:var(--accent-bg); font-weight:600;
}
nav.side button.doc:focus-visible{outline:2px solid var(--accent-soft); outline-offset:1px}
"""

ARTIFACT_JS = """
(function(){
  var panels={}, groups={}, buttons={};
  document.querySelectorAll('.doc').forEach(function(d){ panels[d.dataset.doc]=d; });
  document.querySelectorAll('nav.side .secs').forEach(function(g){ groups[g.dataset.doc]=g; });
  document.querySelectorAll('nav.side button.doc').forEach(function(b){
    buttons[b.dataset.doc]=b;
    b.addEventListener('click',function(){ show(b.dataset.doc, true); });
  });

  function show(key, top){
    if(!panels[key]) return;
    Object.keys(panels).forEach(function(k){
      panels[k].classList.toggle('on',k===key);
      if(groups[k]) groups[k].classList.toggle('on',k===key);
      if(buttons[k]) buttons[k].setAttribute('aria-current',k===key?'true':'false');
    });
    var where=document.getElementById('where');
    if(where) where.textContent=buttons[key]?buttons[key].textContent:'';
    if(top) window.scrollTo({top:0});
    if(window.landinFilter) window.landinFilter();
  }

  /* a citation may name a construct in another document */
  function reveal(id){
    var t=document.getElementById(id); if(!t) return false;
    var panel=t.closest('.doc');
    if(panel && !panel.classList.contains('on')) show(panel.dataset.doc);
    t.scrollIntoView({block:'start'});
    return true;
  }
  document.addEventListener('click',function(e){
    var a=e.target.closest('a[href^="#"]'); if(!a) return;
    var id=a.getAttribute('href').slice(1);
    if(reveal(id)){ e.preventDefault(); history.replaceState(null,'','#'+id); }
  });
  window.addEventListener('hashchange',function(){
    if(location.hash.length>1) reveal(location.hash.slice(1));
  });

  show(document.querySelector('nav.side button.doc').dataset.doc);
  if(location.hash.length>1) reveal(location.hash.slice(1));
})();
"""


def artifact_nav(docs, groups):
    """One sidebar for five documents: pick one, then move about inside it."""
    out = ['<h3>documents</h3>']
    for d in docs:
        out.append(f'<button class="doc" type="button" data-doc="{d["key"]}">'
                   f'{esc(d["nav"])}</button>')
    out.append('<h3>find</h3>')
    out.append('<input id="find" type="search" placeholder="filter — press /" '
               'autocomplete="off" spellcheck="false">')
    out.append('<div id="found"></div>')
    out.append('<h3>in this document</h3>')
    for d in docs:
        out.append(f'<div class="secs" data-doc="{d["key"]}">')
        for sid, title, count in groups[d["key"]]:
            label = esc(title.split("  —  ")[0])
            n = str(count) if count else ""
            out.append(f'<a class="sect" href="#{sid}">'
                       f'<span class="num">{n}</span><span>{label}</span></a>')
        out.append("</div>")
    return "\n".join(out)


def artifact_page(panels, nav):
    """A fragment: the artifact host supplies the document around it."""
    return f"""<title>Landin — the specification, highlighted</title>
<style>{CSS}{ARTIFACT_CSS}</style>
<header class="bar">
  <span class="brand">Landin</span>
  <span class="where" id="where"></span>
  <span class="grow"></span>
  <button id="menu" type="button" aria-label="documents and sections">menu</button>
</header>
<div class="wrap">
<nav class="side">
{nav}
</nav>
<main>
{panels}
</main>
</div>
<div id="pop"></div>
<script>{JS}{ARTIFACT_JS}</script>
"""


def build_artifact(source, out_path):
    """Every document on one page, since an artifact is one page."""
    loaded = {d["src"]: split_sections((source / d["src"]).read_text())
              for d in DOCS}
    tour_ids = set()
    for sec in loaded[DOCS[0]["src"]][1]:
        for item in parse_tour_body(sec["body"]):
            if item["id"]:
                tour_ids.add(item["id"])
            tour_ids.update(item["anchors"])

    panels, groups = [], {}
    for d in DOCS:
        front, sections = loaded[d["src"]]
        symbols = collect_symbols((source / d["src"]).read_text().split("\n"))
        prefix = d["key"] + "-"

        findings = set()
        for sec in sections:
            if is_findings(sec["body"]):
                findings |= {e["id"] for e in parse_findings(sec["body"])[1]}

        def links(ref, _f=findings, _ids=tour_ids):
            return f"#{ref}" if ref in _f or ref in _ids else None

        if d["kind"] == "tour":
            body, nav_sections, _ = render_tour_sections(
                sections, links, symbols, prefix)
        else:
            body, nav_sections = render_prototype_sections(
                sections, links, symbols, prefix)
        groups[d["key"]] = nav_sections
        hero = render_plain(parse_plain(front["body"]), links)
        panels.append(
            f'<div class="doc" data-doc="{d["key"]}">\n'
            f'<div class="hero"><div class="kind">{esc(d["nav"])}</div>'
            f'<h1>{esc(front["title"])}</h1>{hero}</div>\n{body}\n'
            f'<footer>Generated from <code>{esc(d["src"])}</code> by '
            f'<code>render_html.py</code>. The text file is the specification; '
            f'this page is a reading of it.</footer>\n</div>')

    out_path.write_text(artifact_page("\n".join(panels), artifact_nav(DOCS, groups)))
    return out_path




TICKED = re.compile(r"`([^`]+)`")


def prose_html(text, links):
    out = cite_links(esc(text), links)
    return TICKED.sub(lambda m: f"<code>{m.group(1)}</code>", out)


def slug(title):
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s or "section"


def listing(code_html, cont=False):
    klass = "listing cont" if cont else "listing"
    return (f'<div class="{klass}"><pre>{code_html}</pre>'
            f'<button class="copy" type="button">copy</button></div>')


def render_sample(lines, hl, links):
    """An indented block inside prose: code where it is code, plain where not."""
    out = []
    for line in lines:
        if not line.strip():
            out.append("")
            continue
        if hl.known_only(line):
            out.append(hl.line(line))
            continue
        parts = list(re.finditer(r" {2,}", line))
        done = False
        for m in reversed(parts):
            left, right = line[:m.start()], line[m.start():]
            if left.strip() and hl.known_only(left):
                out.append(hl.line(left) + cite_links(esc(right), links))
                done = True
                break
        if done:
            continue
        if sample_like(line) and not re.search(r"\S {2,}\S", line):
            out.append(hl.line(line))
        else:
            out.append(cite_links(esc(line), links))
    return f'<pre class="sample">{chr(10).join(out)}</pre>'


def render_plain(blocks, links):
    out = []
    for kind, payload in blocks:
        if kind == "para":
            out.append(f"<p>{prose_html(payload, links)}</p>")
        elif kind == "quote":
            out.append(f"<blockquote>{prose_html(payload, links)}</blockquote>")
        else:
            body = "\n".join(prose_html(l, links) for l in payload)
            out.append(f"<pre>{body}</pre>")
    return "\n".join(out)


def is_findings(body):
    """A closing findings section, whatever its title says."""
    return sum(1 for l in body if FINDING.match(l)) >= 2


def hanging_groups(body):
    """Group free text the way a hanging indent groups it.

    A flush-left line opens a group and the indented lines under it belong
    to it, so the entries of WHAT WAS TRIED AND DROPPED come apart even
    though no blank line separates them, and a plain paragraph of
    flush-left lines stays one group.
    """
    groups, run = [], []

    def close():
        if run:
            groups.append(list(run))
            run.clear()

    for line in body:
        if not line.strip():
            close()
            continue
        flush = not line[:1].isspace()
        if flush and any(l[:1].isspace() for l in run):
            close()
        run.append(line.rstrip())
    close()
    return groups


def interior_blanks(body):
    solid = [i for i, l in enumerate(body) if l.strip()]
    if not solid:
        return 0
    return len([l for l in body[solid[0]:solid[-1]] if not l.strip()])


def section_style(title, body):
    """What a section that is not a run of constructs actually is.

    Read from the shape rather than from the title, so that renaming a
    section cannot silently turn a list into one paragraph of run-together
    lines. A section of constructs answers None and is parsed as such.
    """
    if is_findings(body):
        return "findings"
    if any(ITEM.match(l) for l in body):
        return None
    solid = [l.rstrip() for l in body if l.strip()]
    if not solid:
        return "prose"
    if any(len(g) > 1 and any(l[:1].isspace() for l in g)
           for g in hanging_groups(body)):
        return "entries"
    if (len(solid) >= 4 and interior_blanks(body) == 0
            and not any(l[:1].isspace() for l in solid)
            and not any(l.endswith(".") for l in solid)):
        return "bullets"        # one line, one item, as the no-list is written
    return "prose"


def render_bullets(body, links):
    out = ['<ul class="bullets">']
    for line in body:
        if line.strip():
            out.append(f"<li>{prose_html(line.strip(), links)}</li>")
    out.append("</ul>")
    return "\n".join(out)


def render_entries(body, links):
    """Hanging-indent entries, as WHAT WAS TRIED AND DROPPED is written."""
    out = []
    for group in hanging_groups(body):
        text = " ".join(l.strip() for l in group)
        hanging = len(group) > 1 and any(l[:1].isspace() for l in group)
        klass = ' class="dropped"' if hanging else ""
        out.append(f"<p{klass}>{prose_html(text, links)}</p>")
    return "\n".join(out)


def render_findings(body, links, hl):
    lead, entries = parse_findings(body)
    out = []

    def children_html(children):
        bits = []
        for kind, payload in children:
            if kind == "p":
                bits.append(f"<p>{prose_html(payload, links)}</p>")
            else:
                strip = min(len(l) - len(l.lstrip()) for l in payload if l.strip())
                bits.append(render_sample([l[strip:] for l in payload], hl, links))
        return chr(10).join(bits)

    if lead:
        out.append(f'<div class="lead">{children_html(lead)}</div>')
    for e in entries:
        out.append(f'<div class="finding" id="{e["id"]}">'
                   f'<a class="tag" href="#{e["id"]}">{e["id"]}</a>'
                   f'<div>{children_html(e["children"])}</div></div>')
    return "\n".join(out)


def render_section_head(title, note, links):
    if "  —  " in title:
        mod, rest = title.split("  —  ", 1)
        head = (f'<span class="mod">{esc(mod)}</span>'
                f'<span class="of">— {esc(rest)}</span>')
    else:
        head = esc(title)
    out = [f"<h2>{head}</h2>"]
    text = " ".join(l.strip() for l in note if l.strip())
    if text:
        out.append(f'<p class="note">{prose_html(text, links)}</p>')
    return "\n".join(out)


def render_tour_sections(sections, links, symbols, prefix=""):
    """Every construct as a block of prose and the code under it."""
    out, nav, ids = [], [], []
    for sec in sections:
        sid = prefix + slug(sec["title"])
        style = section_style(sec["title"], sec["body"])
        items = [] if style else parse_tour_body(sec["body"])
        body = []
        if style == "bullets":
            body.append(render_bullets(sec["body"], links))
        elif style == "entries":
            body.append(render_entries(sec["body"], links))
        elif style == "findings":
            body.append(render_findings(sec["body"], links,
                                        Highlighter(*symbols, links=links)))
        elif style == "prose":
            body.append(render_plain(parse_plain(sec["body"]), links))

        for item in items:
            hl = Highlighter(*symbols, links=links)
            inner = []
            for kind, payload in item["children"]:
                if kind == "p":
                    inner.append(f"<p>{prose_html(payload, links)}</p>")
                elif kind == "pre":
                    inner.append(render_sample(payload, hl, links))
                else:
                    cont = bool(payload) and payload[0][:1].isspace()
                    inner.append(listing(hl.block(payload), cont))
            anchors = "".join(f'<span class="anchor" id="{a}"></span>'
                              for a in item["anchors"] if a != item["id"])
            if item["id"]:
                ids.append(item["id"])
                ids.extend(a for a in item["anchors"] if a != item["id"])
                body.append(
                    f'<div class="item" id="{item["id"]}">{anchors}'
                    f'<a class="tag" href="#{item["id"]}">{item["id"]}</a>'
                    f'<div>{chr(10).join(inner)}</div></div>')
            else:
                body.append(f'<div class="lead">{anchors}'
                            f'{chr(10).join(inner)}</div>')

        count = len([i for i in items if i["id"]])
        nav.append((sid, sec["title"], count))
        out.append(f'<section id="{sid}" data-title="{esc(sec["title"])}">\n'
                   f'{render_section_head(sec["title"], sec["note"], links)}\n'
                   f'{chr(10).join(body)}\n</section>')
    return "\n".join(out), nav, ids


def render_prototype_sections(sections, links, symbols, prefix=""):
    """The code is the argument here, so each section stays one listing."""
    out, nav = [], []
    for sec in sections:
        sid = prefix + slug(sec["title"])
        if is_findings(sec["body"]):
            body = render_findings(sec["body"], links,
                                   Highlighter(*symbols, links=links))
            count = len(parse_findings(sec["body"])[1])
        else:
            hl = Highlighter(*symbols, links=links)
            parts, count = [], 0
            for kind, payload in split_banners(sec["body"]):
                if kind == "banner":
                    parts.append(f'<h3 class="banner">{prose_html(payload, links)}</h3>')
                else:
                    count += len(payload)
                    parts.append(listing(hl.block(payload)))
            body = "\n".join(parts)
        nav.append((sid, sec["title"], count))
        out.append(f'<section id="{sid}" data-title="{esc(sec["title"])}">\n'
                   f'{render_section_head(sec["title"], sec["note"], links)}\n'
                   f'{body}\n</section>')
    return "\n".join(out), nav


# --------------------------------------------------------------------------
# the shell
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# the guides
#
# The specification and the prototypes are written in a shape this file
# knows.  The rest of the documentation is Markdown, and what follows is a
# reader for the subset the repository actually uses: headings, paragraphs,
# fenced code, bullets and numbers, tables, quotes, and the inline spans.
#
# It is not a Markdown implementation and does not pretend to be one.  It
# refuses what it does not recognise rather than passing it through as
# text, because a table that silently renders as a row of pipes is worse
# than a build that stops.
# --------------------------------------------------------------------------

GUIDES = [
    dict(key="readme", src="README.md", out="readme.html",
         nav="the project", group="the project",
         blurb="What Landin is, what is in the repository, and how to build "
               "the part of it that exists."),
    dict(key="roadmap", src="ROADMAP.md", out="roadmap.html",
         nav="the roadmap", group="the project",
         blurb="The sole durable authority for open work: phases, "
               "dependencies, gates, and every inherited disposition."),
    dict(key="handoff", src="handoff.md", out="handoff.html",
         nav="the design, in one page", group="the project",
         blurb="The design and the principles behind it, and which "
               "decisions must not be quietly reversed."),
    dict(key="compiler", src="compiler/ada/README.md", out="compiler.html",
         nav="the bootstrap compiler", group="the implementation",
         blurb="The Ada 2022 chassis: what each package owns, what it may "
               "not own, and what is deliberately absent."),
    dict(key="toolchain", src="compiler/ada/TOOLCHAIN.md", out="toolchain.html",
         nav="the pinned toolchain", group="the implementation",
         blurb="One compiler, recorded exactly, with the warning policy and "
               "the checksums that verify it."),
    dict(key="environments", src="docs/environments.md",
         out="environments.html",
         nav="the environments", group="the implementation",
         blurb="Which machine produces which kind of evidence, and which "
               "one is the authority."),
    dict(key="fixtures", src="compiler/tests/README.md", out="fixtures.html",
         nav="the fixtures", group="the implementation",
         blurb="The test format that has to outlive the implementation "
               "currently checking it."),
    dict(key="harness", src="compiler/tests/harness-cases/README.md",
         out="harness-cases.html",
         nav="the malformed cases", group="the implementation",
         blurb="Trees that exist to be rejected, and the fault each one "
               "carries."),
]

GUIDE_CSS = """
.guide h3.sub{font:600 15px/1.4 var(--ui);color:var(--ink);margin:26px 0 10px}
.guide p{margin:0 0 12px}
.guide ul,.guide ol{margin:0 0 14px;padding-left:22px}
.guide li{margin:0 0 6px}
.guide blockquote{margin:0 0 14px;padding:2px 0 2px 14px;
  border-left:2px solid var(--accent-soft);color:var(--ink-soft)}
.guide table{width:100%;border-collapse:collapse;margin:0 0 16px;
  font:400 14px/1.5 var(--ui)}
.guide th{text-align:left;font-weight:600;color:var(--ink-soft);
  border-bottom:1px solid var(--rule);padding:7px 10px 7px 0;
  vertical-align:top}
.guide td{border-bottom:1px solid var(--rule-soft);padding:7px 10px 7px 0;
  vertical-align:top}
.guide tr:last-child td{border-bottom:0}
.guide td code,.guide th code{white-space:nowrap}
.guide .term{color:var(--ink-soft)}
.cards h3.group{grid-column:1/-1;font:600 13px/1 var(--ui);
  letter-spacing:.08em;text-transform:uppercase;color:var(--ink-faint);
  margin:18px 0 2px}
.cards h3.group:first-child{margin-top:0}
"""

FENCE = re.compile(r"^```(\w*)\s*$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
BULLET = re.compile(r"^[-*]\s+(.*)$")
NUMBER = re.compile(r"^\d+\.\s+(.*)$")
ROW = re.compile(r"^\|(.*)\|\s*$")
TABLE_RULE = re.compile(r"^\|[\s:|-]+\|\s*$")
QUOTE = re.compile(r"^>\s?(.*)$")
CODE_SPAN = re.compile(r"`([^`]+)`")
BOLD = re.compile(r"\*\*([^*]+)\*\*")
MD_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def guide_targets(docs):
    """Where a link to a source file should point on the site."""
    targets = {d["src"]: d["out"] for d in docs}
    for d in docs:
        #  A document may be named from a directory below it.
        targets[d["src"].split("/")[-1]] = d["out"]
    return targets


def rewrite_link(match, targets):
    label, href = match.group(1), match.group(2)
    bare = href.split("#")[0]
    anchor = href[len(bare):]
    if bare in targets:
        href = targets[bare] + anchor
    return f'<a href="{href}">{label}</a>'


def inline(text, links, targets):
    """Inline spans, in the one order that leaves the others alone."""
    out = esc(text)
    out = MD_LINK.sub(lambda m: rewrite_link(m, targets), out)
    out = BOLD.sub(r"<strong>\1</strong>", out)
    out = CODE_SPAN.sub(r"<code>\1</code>", out)
    return cite_links(out, links)


def cells(line):
    return [c.strip() for c in ROW.match(line).group(1).split("|")]


def guide_table(rows, links, targets):
    head = cells(rows[0])
    out = ["<table>", "<thead><tr>"]
    for cell in head:
        out.append(f"<th>{inline(cell, links, targets)}</th>")
    out.append("</tr></thead><tbody>")
    for row in rows[2:]:
        out.append("<tr>")
        for cell in cells(row):
            out.append(f"<td>{inline(cell, links, targets)}</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def parse_guide(text):
    """Split a Markdown document into a title, a lead, and its sections."""
    title = None
    lead = []
    sections = []
    current = None
    lines = text.split("\n")
    index = 0

    def block(kind, payload):
        (current["blocks"] if current else lead).append((kind, payload))

    while index < len(lines):
        line = lines[index]
        heading = HEADING.match(line)
        fence = FENCE.match(line)

        if heading and len(heading.group(1)) == 1 and title is None:
            title = heading.group(2).strip()
            index += 1
            continue

        if heading and len(heading.group(1)) <= 2:
            current = dict(title=heading.group(2).strip(), blocks=[])
            sections.append(current)
            index += 1
            continue

        if heading:
            block("sub", heading.group(2).strip())
            index += 1
            continue

        if fence:
            language = fence.group(1)
            body = []
            index += 1
            while index < len(lines) and not FENCE.match(lines[index]):
                body.append(lines[index])
                index += 1
            index += 1
            block("code", (language, body))
            continue

        if ROW.match(line):
            rows = []
            while index < len(lines) and ROW.match(lines[index]):
                rows.append(lines[index])
                index += 1
            if len(rows) >= 2 and TABLE_RULE.match(rows[1]):
                block("table", rows)
            else:
                block("para", [" ".join(r.strip() for r in rows)])
            continue

        if BULLET.match(line) or NUMBER.match(line):
            ordered = NUMBER.match(line) is not None
            items = []
            while index < len(lines):
                bullet = BULLET.match(lines[index])
                number = NUMBER.match(lines[index])
                if bullet:
                    items.append(bullet.group(1))
                elif number:
                    items.append(number.group(1))
                elif lines[index].startswith("  ") and items:
                    items[-1] += " " + lines[index].strip()
                else:
                    break
                index += 1
            block("list", (ordered, items))
            continue

        if QUOTE.match(line):
            quoted = []
            while index < len(lines) and QUOTE.match(lines[index]):
                quoted.append(QUOTE.match(lines[index]).group(1))
                index += 1
            block("quote", [" ".join(q for q in quoted if q)])
            continue

        if not line.strip():
            index += 1
            continue

        paragraph = []
        while index < len(lines) and lines[index].strip() \
                and not HEADING.match(lines[index]) \
                and not FENCE.match(lines[index]) \
                and not ROW.match(lines[index]) \
                and not BULLET.match(lines[index]) \
                and not NUMBER.match(lines[index]) \
                and not QUOTE.match(lines[index]):
            paragraph.append(lines[index].strip())
            index += 1
        block("para", [" ".join(paragraph)])

    return title, lead, sections


def render_guide_blocks(blocks, links, targets, hl):
    out = []
    for kind, payload in blocks:
        if kind == "para":
            out.append(f"<p>{inline(payload[0], links, targets)}</p>")
        elif kind == "sub":
            out.append(f'<h3 class="sub" id="{slug(payload)}">'
                       f"{inline(payload, links, targets)}</h3>")
        elif kind == "quote":
            out.append(f"<blockquote>{inline(payload[0], links, targets)}"
                       "</blockquote>")
        elif kind == "list":
            ordered, items = payload
            tag = "ol" if ordered else "ul"
            body = "".join(f"<li>{inline(i, links, targets)}</li>"
                           for i in items)
            out.append(f"<{tag}>{body}</{tag}>")
        elif kind == "table":
            out.append(guide_table(payload, links, targets))
        elif kind == "code":
            language, body = payload
            if language in ("ldn", "landin"):
                out.append(listing(render_sample(body, hl, links)))
            else:
                text = "\n".join(body)
                out.append(f'<div class="listing"><pre>{esc(text)}</pre></div>')
        else:
            raise SystemExit(f"render_html: unknown guide block {kind!r}")
    return "\n".join(out)


def render_guide(text, links, targets, hl):
    title, lead, sections = parse_guide(text)

    #  The hero carries the opening paragraph and nothing else.  Anything
    #  further above the first heading is ordinary body: a table in a hero
    #  is a table outside the styling that makes it readable, and a
    #  document with no headings at all is not a document with no content.
    opening = lead[:1] if lead and lead[0][0] == "para" else []
    remainder = lead[len(opening):]

    hero = render_guide_blocks(opening, links, targets, hl)
    body = []
    nav_sections = []

    if remainder:
        body.append('<section class="guide" id="top">\n'
                    + render_guide_blocks(remainder, links, targets, hl)
                    + "\n</section>")

    for sec in sections:
        sid = slug(sec["title"])
        subs = sum(1 for kind, _ in sec["blocks"] if kind == "sub")
        nav_sections.append((sid, sec["title"], subs))
        body.append(
            f'<section class="guide" id="{sid}" '
            f'data-title="{esc(sec["title"])}">\n'
            f'<h2>{inline(sec["title"], links, targets)}</h2>\n'
            + render_guide_blocks(sec["blocks"], links, targets, hl)
            + "\n</section>")

    return title, hero, "\n".join(body), nav_sections


def nav_html(docs, current, sections):
    out = ['<h3>documents</h3>']
    out.append(f'<a class="doc" href="index.html">contents</a>')
    for d in docs:
        here = ' here' if d["out"] == current else ""
        out.append(f'<a class="doc{here}" href="{d["out"]}">{esc(d["nav"])}</a>')
    out.append('<h3>find</h3>')
    out.append('<input id="find" type="search" placeholder="filter — press /" '
               'autocomplete="off" spellcheck="false">')
    out.append('<div id="found"></div>')
    if sections:
        out.append('<h3>in this document</h3>')
        for sid, title, count in sections:
            label = esc(title.split("  —  ")[0])
            n = str(count) if count else ""
            out.append(f'<a class="sect" href="#{sid}">'
                       f'<span class="num">{n}</span><span>{label}</span></a>')
    return "\n".join(out)


def page(title, kind, heading, hero, body, nav, docname):
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>{esc(title)}</title>
<style>{CSS}{GUIDE_CSS}</style>
</head>
<body>
<header class="bar">
  <a class="brand" href="index.html">Landin</a>
  <span class="where" id="where">{esc(kind)}</span>
  <span class="grow"></span>
  <button id="menu" type="button" aria-label="sections">menu</button>
  <button id="theme" type="button" aria-label="light or dark">theme</button>
</header>
<div class="wrap">
<nav class="side">
{nav}
</nav>
<main>
<div class="hero">
  <div class="kind">{esc(kind)}</div>
  <h1>{esc(heading)}</h1>
  {hero}
</div>
{body}
<footer>
Generated from <code>{esc(docname)}</code> by <code>render_html.py</code>.
The text file is the specification; this page is a reading of it.
Regenerate with <code>python3 render_html.py</code>.
</footer>
</main>
</div>
<div id="pop"></div>
<script>{JS}</script>
</body>
</html>
"""


def index_page(docs, pitch, counts):
    groups = []
    for d in docs:
        name = d.get("group", "the specification")
        if not groups or groups[-1][0] != name:
            groups.append((name, []))
        groups[-1][1].append(d)

    cards = []
    for name, members in groups:
        cards.append(f'<h3 class="group">{esc(name)}</h3>')
        for d in members:
            n = counts.get(d["out"], "")
            cards.append(
                f'<a class="card" href="{d["out"]}"><strong>{esc(d["nav"])}'
                f'</strong><span>{esc(d["blurb"])}</span>'
                f'<em>{esc(n)}</em></a>')

    body = f'<div class="cards">{chr(10).join(cards)}</div>'
    nav = nav_html(docs, "index.html", [])
    hero = (f"<p>{esc(pitch)}</p><p>{VERSION_LINE}. The compiler does not "
            "compile anything yet; the bootstrap chassis is built and "
            "tested.</p>")
    return page("Landin — the specification and the work", "contents",
                "Landin", hero, body, nav, "the repository")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

WORD = re.compile(r"[A-Za-z0-9_.]{3,}")
TAG = re.compile(r"<[^>]+>")
PRE = re.compile(r"(<pre\b.*?</pre>)", re.S)
SCRIPTY = re.compile(r"<(script|style)\b.*?</\1>", re.S)
ATTR = re.compile(r'\s(?:href|src)="([^"]*)"')


def verify(src: Path, out: Path):
    """Nothing may be lost on the way to the page.

    Both sides are reduced to a multiset of words, which survives rewrapping
    prose and dropping the '--' that carried it. A word that comes out fewer
    times than it went in means a line went missing.
    """
    from collections import Counter
    want = Counter(WORD.findall(src.read_text()))
    # inside a listing a span sits between the halves of one name, so tags
    # go without a space there and with one everywhere else
    #  A link's target lives in an attribute rather than in the text, and
    #  stripping tags takes it with them, so the targets are collected and
    #  counted alongside what a reader sees.
    raw = SCRIPTY.sub(" ", out.read_text())
    targets = " ".join(ATTR.findall(raw))
    parts = PRE.split(raw)
    page_text = html.unescape("\n".join(
        TAG.sub("", part) if part.startswith("<pre") else TAG.sub(" ", part)
        for part in parts))
    got = Counter(WORD.findall(page_text + " " + targets))
    lost = {w: (n, got.get(w, 0)) for w, n in want.items() if got.get(w, 0) < n}
    if lost:
        print(f"  {out.name}: {len(lost)} words come out short")
        for w, (a, b) in sorted(lost.items())[:20]:
            print(f"    {w!r}: {a} in the file, {b} on the page")
    else:
        print(f"  {out.name}: every word of {src.name} is on the page")
    return not lost


def main(argv):
    audit = "--audit" in argv
    check = "--verify" in argv
    one_page = "--artifact" in argv

    source = HERE
    if "--from" in argv:
        source = Path(argv[argv.index("--from") + 1]).resolve()
    named = [Path(a).name for a in argv if a.endswith(".txt")]

    named += [Path(a).name for a in argv if a.endswith(".md")]
    docs = [d for d in DOCS if not named or d["src"] in named
            or d["src"].split("/")[-1] in named]
    guides = [g for g in GUIDES if not named or g["src"] in named
              or g["src"].split("/")[-1] in named]
    if not docs and not guides:
        print("nothing to render; the documents are "
              + ", ".join(d["src"] for d in DOCS + GUIDES))
        return 1
    loaded = {d["src"]: split_sections((source / d["src"]).read_text())
              for d in DOCS}

    tour_front, tour_sections = loaded[DOCS[0]["src"]]
    tour_ids = set()
    for sec in tour_sections:
        for item in parse_tour_body(sec["body"]):
            if item["id"]:
                tour_ids.add(item["id"])
            tour_ids.update(item["anchors"])

    if audit:
        return run_audit(loaded, tour_ids)

    if one_page:
        SITE.mkdir(exist_ok=True)
        out = build_artifact(source, SITE / "landin-artifact.html")
        print(f"{SITE.name}/{out.name}    {out.stat().st_size // 1024} KB, "
              f"{len(DOCS)} documents on one page")
        return 0

    SITE.mkdir(exist_ok=True)
    counts = {}
    dangling = []

    for d in docs:
        front, sections = loaded[d["src"]]
        text_lines = (source / d["src"]).read_text().split("\n")
        symbols = collect_symbols(text_lines)

        if d["kind"] == "tour":
            def links(ref, _ids=tour_ids):
                if ref in _ids:
                    return f"#{ref}"
                if ref.isdigit() and ref.endswith("0"):
                    dangling.append(ref)
                return None
            body, nav_sections, ids = render_tour_sections(sections, links, symbols)
            counts[d["out"]] = (f"{len(ids)} constructs in "
                                f"{len(nav_sections)} sections")
        else:
            findings = set()
            for sec in sections:
                if is_findings(sec["body"]):
                    findings = {e["id"] for e in parse_findings(sec["body"])[1]}

            def links(ref, _f=findings, _ids=tour_ids):
                if ref in _f:
                    return f"#{ref}"
                if ref in _ids:
                    return f"tour.html#{ref}"
                if not ref.isdigit() or ref.endswith("0"):
                    dangling.append(ref)
                return None
            body, nav_sections = render_prototype_sections(sections, links, symbols)
            modules = len(nav_sections) - (1 if findings else 0)
            counts[d["out"]] = (f"{modules} modules, {len(findings)} findings")

        hero = render_plain(parse_plain(front["body"]), links)
        nav = nav_html(DOCS + GUIDES, d["out"], nav_sections)
        out = page(f"Landin — {front['title'].title()}", d["nav"],
                   front["title"], hero, body, nav, d["src"])
        (SITE / d["out"]).write_text(out)
        print(f"{SITE.name}/{d['out']:<20} {len(out) // 1024:4d} KB  "
              f"{len(nav_sections)} sections")

    guide_link_targets = guide_targets(DOCS + GUIDES)
    guide_symbols = collect_symbols(
        (source / DOCS[0]["src"]).read_text().split("\n"))

    for g in guides:
        text = (source / g["src"]).read_text()

        def links(ref, _ids=tour_ids):
            if ref in _ids:
                return f"tour.html#{ref}"
            return None

        title, hero, body, nav_sections = render_guide(
            text, links, guide_link_targets,
            Highlighter(*guide_symbols, links=links))
        nav = nav_html(DOCS + GUIDES, g["out"], nav_sections)
        out = page(f"Landin — {title}", g["nav"], title or g["nav"],
                   hero, body, nav, g["src"])
        (SITE / g["out"]).write_text(out)
        counts[g["out"]] = f"{len(nav_sections)} sections"
        print(f"{SITE.name}/{g['out']:<20} {len(out) // 1024:4d} KB  "
              f"{len(nav_sections)} sections")

    if check:
        print("checking that nothing was dropped:")
        ok = all(verify(source / d["src"], SITE / d["out"])
                 for d in docs + guides)
        if not ok:
            print("some content is missing from the pages")
            return 1

    if len(docs) == len(DOCS) and len(guides) == len(GUIDES):
        pitch = " ".join(l.strip() for l in tour_front["body"][:3] if l.strip())
        (SITE / "index.html").write_text(
            index_page(DOCS + GUIDES, pitch, counts))
        print(f"{SITE.name}/index.html")
    if dangling:
        print(f"warning: {len(set(dangling))} citations point nowhere: "
              f"{', '.join(sorted(set(dangling)))}")
    return 0


def run_audit(loaded, tour_ids):
    """Print how the tour's prose lines were classified, and what was skipped."""
    front, sections = loaded["tour.txt"]
    samples, paras, breaks = 0, 0, 0
    for sec in sections:
        style = section_style(sec["title"], sec["body"])
        if style:
            print(f"[plain:{style}] {sec['title']}")
            continue
        items = parse_tour_body(sec["body"])
        if not items:
            print(f"[plain:none] {sec['title']}")
        for item in items:
            for kind, payload in item["children"]:
                if kind == "pre":
                    samples += 1
                    print(f"  sample in [{item['id']}]:")
                    for l in payload:
                        print(f"      |{l}")
                elif kind == "p":
                    paras += 1
            breaks += max(0, len([1 for k, _ in item["children"] if k == "p"]) - 1)
    print(f"\n{samples} samples, {paras} paragraphs "
          f"({breaks} paragraph breaks found inside constructs)")
    print(f"{len(tour_ids)} construct anchors")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
