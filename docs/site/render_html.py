#!/usr/bin/env python3
"""Render the Landin specification and prototypes as syntax-highlighted HTML.

    python3 render_html.py                  every document, into site/
    python3 render_html.py tour.md         one of them
    python3 render_html.py --verify         and check that nothing was dropped
    python3 render_html.py --from ../landin read the text files from elsewhere

The pages are single files: the stylesheet, the script and the
highlighting are all inlined, so one file can be opened from disk,
mailed, or served as it is.  What sits beside them is what a browser
showing the document is not the one asking for -- the card a crawler
fetches, the two icons that want to be files -- and the webfonts, which
are inlined nowhere because eighty subsets are a megabyte and a page
carrying its four would carry them again on the next page.

Nothing here is a parser. The highlighting is not even here: it comes from
highlight/landin_highlight.py, the one scanner every Landin highlighter is
a rendering of, and this file only turns its classes into spans. What this
file knows is the shape the specification is written in:

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
import json
import posixpath
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import quote, unquote, urlsplit, urlunsplit

HERE = Path(__file__).resolve().parent
SITE = HERE / "site"

VERSION_LINE = "specification 0.2.7"
REPO = "https://github.com/JanHaan/Landin"
#  The canonical host.  The pages are served from GitHub Pages under
#  the CNAME the publishing workflow writes; every page still says
#  which of 701.dev and www.701.dev it wants to be found at, because a
#  reader who arrives at the other one should be told, not guessed at.
SITE_URL = "https://www.701.dev"
OG_IMAGE = "og.png"

DOCS = [
    dict(key="spec", banner=True, src="spec.md", out="spec.html", kind="document",
         nav="the specification", group="the specification",
         blurb="The normative reference, not for reading through: look up "
               "the exact rule a tour entry or a compiler message names."),
    #  The tour's opening three paragraphs are its lead, its first
    #  programs wrap on a phone, and its sidebar says where its path ends.
    dict(key="tour", src="tour.md", out="tour.html", kind="document",
         lead_paras=3, wrap_opening=True,
         reference_after="What you can write now",
         nav="the tour", group="the specification",
         blurb="The language explained, construct by numbered construct. "
               "It teaches; the specification decides."),
    dict(key="p1", banner=True, group="design stress tests", src="prototype-1-driver.md", out="prototype-1.html", kind="document",
         nav="prototype 1 — driver",
         blurb="Not learning material: a Cortex-M driver sketch, written "
               "before the compiler to find where the specification was "
               "silent. Its findings are the point."),
    dict(key="p2", banner=True, group="design stress tests", src="prototype-2-parser.md", out="prototype-2.html", kind="document",
         nav="prototype 2 — parser",
         blurb="Not learning material: a recovering parser sketch, written "
               "before the compiler to find where the specification was "
               "silent. Its findings are the point."),
    dict(key="p3", banner=True, group="design stress tests", src="prototype-3-containers.md", out="prototype-3.html", kind="document",
         nav="prototype 3 — containers",
         blurb="Not learning material: a generic container library sketch, "
               "written before the compiler to find where the specification "
               "was silent. Its findings are the point."),
    dict(key="p4", banner=True, group="design stress tests", src="prototype-4-app.md", out="prototype-4.html", kind="document",
         nav="prototype 4 — application",
         blurb="Not learning material: a hosted application sketch, written "
               "before the compiler to find where the specification was "
               "silent. Its findings are the point."),
]

# --------------------------------------------------------------------------
# the language
# --------------------------------------------------------------------------
#
#  The scanner is not here.  It lives in highlight/, where the Pygments
#  lexer reads the same file, so that a keyword added once is a keyword
#  everywhere rather than in whichever copy was edited last.

sys.path.insert(0, str(HERE.parents[1] / "highlight"))

from landin_highlight import Scanner, collect_symbols  # noqa: E402

#  Nor is the icon.  It lives in assets/, one drawing that the
#  favicon, the top bar and anything else wanting a mark are
#  renderings of; a page carries it as a data URL so that a page
#  is still one file.

sys.path.insert(0, str(HERE.parents[1] / "assets"))

import landin_icon  # noqa: E402
import icons  # noqa: E402
import fonts  # noqa: E402

#  Nor is the fixture format: a fixture's metadata is read the way every
#  lane reads it, by compiler/tests/fixture_meta.py.

sys.path.insert(0, str(HERE.parents[1] / "compiler" / "tests"))

import fixture_meta as fixture_format  # noqa: E402

#  Nor are the two files an agent asks for.  They are a reading of the
#  grammar, the compiler's refusal tables and the catalogue rather than
#  anything about a page, so they live beside this and not inside it.

sys.path.insert(0, str(HERE))

import llms  # noqa: E402
import library  # noqa: E402
from roadmap_order import execution_order  # noqa: E402

#  Both icons travel in the page.  The pages have no external references
#  at all, and a favicon fetched from a second file would be the first
#  one: a page that is mailed, or opened from disk, keeps its mark.
#  `mask-icon` is Safari's pinned tab, which wants the mark alone with no
#  plate around it and colours the shape itself.

#  The favicon stays a data: URL -- it follows the reader's light or dark
#  setting through a media query, which a file would too, but this one
#  costs no request.  The pinned-tab mark is a file because Safari has
#  never accepted a data: URL for one, so as a data: URL it simply did
#  not appear.
ICON_LINKS = "\n".join([
    '<link rel="icon" href="%s">' % landin_icon.data_uri("auto"),
    '<link rel="mask-icon" href="icon-mono.svg" color="%s">'
    % landin_icon.ACCENT,
    '<link rel="apple-touch-icon" href="apple-touch-icon.png">',
])

CITE = re.compile(r"\[((?:\d{4})|(?:[XYZW]\d+))\]")


def cite_links(escaped: str, links) -> str:
    """Turn [NNNN] and [Zn] in already-escaped text into links."""
    def one(m):
        target = links(m.group(1))
        if not target:
            return m.group(0)
        return f'<a class="cite" href="{target}" data-cite="{m.group(1)}">{m.group(0)}</a>'
    return CITE.sub(one, escaped)


class Highlighter(Scanner):
    """The shared scanner, rendered as HTML.

    The classes it emits become span classes, and the two comment classes
    have their citations linked as well, so a construct named in a comment
    reaches the construct it names.
    """

    def __init__(self, types=(), atoms=(), links=lambda ref: None):
        super().__init__(types, atoms)
        self.links = links

    def line(self, text: str) -> str:
        out = []
        for cls, body in self.scan(text):
            body = html.escape(body)
            if cls in ("c", "cd"):
                body = cite_links(body, self.links)
            out.append(f'<span class="{cls}">{body}</span>' if cls else body)
        return "".join(out)

    def block(self, lines) -> str:
        return "\n".join(self.line(l) for l in lines)


# --------------------------------------------------------------------------
# document shape: rule / title / rule, then a body
# --------------------------------------------------------------------------


# --------------------------------------------------------------------------
# the tour: numbered constructs, their prose, and the code under them
# --------------------------------------------------------------------------


def sample_like(text: str) -> bool:
    """Is an indented prose line a code sample rather than a sentence?"""
    if re.search(r"\S {2,}\S", text):           # aligned columns
        return True
    if re.match(r"^[\w.]+\s*:=", text):
        return True
    if re.match(r"^[\w.]+:\s", text) and "=" in text:
        return True
    return False


# --------------------------------------------------------------------------
# the prototypes: listings, and the findings at the end
# --------------------------------------------------------------------------

FINDING = re.compile(r"^([XYZW]\d+)\s+(\S.*)$")


# --------------------------------------------------------------------------
# the page
# --------------------------------------------------------------------------

#  The dark values, written once and substituted into both halves of the
#  theme question below.
DARK = """
    color-scheme: dark;
    --bg:oklch(0.2 0.012 255); --bg-soft:oklch(0.215 0.012 255);
    --panel:oklch(0.23 0.013 255); --panel-2:oklch(0.25 0.014 255);
    --ink:oklch(0.93 0.006 250); --ink-soft:oklch(0.8 0.012 250);
    --ink-faint:oklch(0.68 0.014 250);
    --rule:oklch(0.31 0.014 255); --rule-soft:oklch(0.27 0.013 255);
    --rule-strong:oklch(0.53 0.014 255);
    --accent:oklch(0.76 0.12 40); --accent-soft:oklch(0.6 0.1 40);
    --accent-bg:oklch(0.28 0.04 40);
    --code-bg:oklch(0.175 0.012 255);
    --k:oklch(0.8 0.09 350); --t:oklch(0.8 0.08 195); --f:oklch(0.8 0.08 255);
    --n:oklch(0.8 0.09 305); --q:oklch(0.8 0.09 135); --b:oklch(0.82 0.1 75);
    --cd:oklch(0.74 0.06 140);
    --term-bg:oklch(0.16 0.012 255); --term-ink:oklch(0.88 0.01 250);
    --sh:0 8px 24px oklch(0 0 0 / .45);"""

CSS = """
:root{
  color-scheme: light;
  /*  Every colour is oklch: lightness, chroma, hue.  The light surfaces
      share one warm hue (85) and differ only in lightness; the ink leans
      cool (255-260) so text never reads as brown; the accent is brick
      (30).  The dark theme turns the surfaces cool (255) as well -- warm
      darks read as brown -- and lifts the accent to coral (40).
      The syntax colours share one lightness and one chroma and differ
      only in hue, so no token shouts louder than another.  */
  --bg:oklch(0.975 0.006 85); --bg-soft:oklch(0.955 0.008 85);
  --panel:oklch(0.99 0.004 85); --panel-2:oklch(0.945 0.009 85);
  --ink:oklch(0.24 0.018 260); --ink-soft:oklch(0.45 0.02 255);
  --ink-faint:oklch(0.515 0.015 250);
  --rule:oklch(0.88 0.012 85); --rule-soft:oklch(0.92 0.01 85);
  /*  The boundary of a control -- a field, a button -- has to be seen
      to be found: about 3:1 against the surface, where --rule's 1.35:1
      is a hairline between two things that are not interactive.  */
  --rule-strong:oklch(0.64 0.014 85);
  --accent:oklch(0.5 0.15 30); --accent-soft:oklch(0.66 0.1 30);
  --accent-bg:oklch(0.95 0.02 30);
  --code-bg:oklch(0.985 0.005 85); --code-rule:var(--rule);
  --k:oklch(0.48 0.1 350); --t:oklch(0.48 0.1 190); --f:oklch(0.48 0.1 260);
  --n:oklch(0.48 0.1 300); --q:oklch(0.48 0.1 130); --b:oklch(0.48 0.1 60);
  --cd:oklch(0.48 0.06 140);
  /*  A terminal's output is a panel of its own, dark in both themes.  */
  --term-bg:oklch(0.25 0.014 255); --term-ink:oklch(0.92 0.006 250);
  --d:var(--ink); --c:var(--ink-faint); --o:var(--ink-faint);
  --sh:0 8px 24px oklch(0.2 0.02 60 / .12);
  /*  The sticky bar's height, which every scroll target clears.  */
  --bar:3.25rem;
  --ui:{UI_STACK};
  --mono:{MONO_STACK};
}
/*  The switch is a checkbox, and it inverts: checked means the theme the
    system did not ask for.  CSS cannot read which theme that is, only
    match on it, so the dark values are written under both halves of the
    question -- system dark and not inverted, system light and inverted.
    The choice itself is remembered by THEME_JS, which runs as the box is
    parsed and before anything is painted.
    They are one string substituted twice, so the two copies cannot
    drift apart.  */
@media (prefers-color-scheme: dark){
  :root:not(:has(#theme:checked)){{DARK}
  }
}
@media (prefers-color-scheme: light), (prefers-color-scheme: no-preference){
  :root:has(#theme:checked){{DARK}
  }
}

*{box-sizing:border-box}
/*  No smooth scrolling here: a jump across a long document animated
    for seconds, and the reduced-motion setting that switched it off was
    overridden by the rule after it.  JS animates a short in-page jump,
    and only for a reader who has not asked for less motion.  */
@media (prefers-reduced-motion: reduce){
  *{transition-duration:.01ms !important; animation-duration:.01ms !important}
}
a:focus-visible, button:focus-visible, input:focus-visible, summary:focus-visible{
  outline:2px solid var(--accent); outline-offset:2px;
}
a.skip{
  position:absolute; left:.5rem; top:-3rem; z-index:60;
  padding:.45rem .7rem; background:var(--panel); color:var(--ink);
  border:1px solid var(--accent); font-size:.85rem;
}
/*  Below the bar, not over the brand.  */
a.skip:focus{top:calc(var(--bar) + .5rem)}
html{-webkit-text-size-adjust:100%}
body{
  margin:0; background:var(--bg); color:var(--ink);
  font-family:var(--ui); font-size:16px; line-height:1.6;
  font-feature-settings:"kern" 1,"liga" 1;
}
/*  The code face's features: calt and liga draw `->`, `<>` and `:=` as
    one shape each, and zero slashes the digit.  dlig is the code face's
    own and is switched on only once that face is known to have loaded
    (JS sets .mono-dlig): a fallback face's dlig draws a struck `st`.  */
code,pre,.mono,.tag,.cite,.label{
  font-family:var(--mono);
  font-feature-settings:"kern" 1,"calt" 1,"liga" 1,"zero" 1;
}
.mono-dlig :is(code,pre,.mono,.tag,.cite,.label){
  font-feature-settings:"kern" 1,"calt" 1,"liga" 1,"dlig" 1,"zero" 1;
}
code{
  font-size:.85em; padding:.05rem .18rem; color:var(--ink);
  background:var(--panel-2); border-radius:2px;
}
/*  A field the reader types in is a control and is seen as one.  */
main input:not([type="checkbox"]):not([type="radio"]){border-color:var(--rule-strong)}
/*  A long path in a sentence or a cell may break anywhere rather than
    push the page wider than the phone.  An identifier keeps its case
    wherever an uppercase transform reaches it.  */
/*  A long path in a sentence or a cell may break rather than push the
    page wider than the phone.  In a sentence it breaks only where a word
    cannot fit at all -- `anywhere` split `--level=armv7-m` after its
    dashes and identifiers mid-token -- and on a wide screen a short span
    does not break at all; a span the generator marks long still may.  A
    table cell and a caption's path have no room to spare and keep
    `anywhere`.  */
p code, li code, blockquote code{overflow-wrap:break-word}
td code, th code{overflow-wrap:anywhere}
@media (min-width:48rem){
  p code:not(.long), li code:not(.long){white-space:nowrap}
}
:is(h1,h2,h3,h4,.where,summary) code{text-transform:none}
/*  Code in a heading is part of the title, not a chip inside it.  */
:is(h1,h2,h3,h4) code{background:none; padding:0; font-size:.92em}
a{
  color:var(--accent); text-underline-offset:.18em;
  text-decoration-thickness:1px;
  text-decoration-color:color-mix(in oklch, var(--accent) 40%, transparent);
}
a:hover{text-decoration-color:currentColor}
/*  A mono label: the small lowercase line that says what a thing is.  */
.label{font-size:.75rem; color:var(--ink-faint); letter-spacing:0}

/* ---- top bar ---- */
header.bar{
  position:sticky; top:0; z-index:40;
  display:flex; align-items:center; gap:.9rem;
  height:var(--bar); padding:0 1.5rem 0 1.25rem;
  /*  Opaque: translucent, the text scrolling under it showed through.  */
  background:var(--bg);
  border-bottom:1px solid var(--rule);
}
header.bar .brand{
  font-weight:700; font-size:.98rem; letter-spacing:-.01em;
  color:var(--ink); text-decoration:none; white-space:nowrap;
  display:inline-flex; align-items:baseline; gap:.5rem;
}
/*  The mark is 701 in figures, which stand on the baseline and rise to
    the cap height, so it is set exactly that tall and aligned to the
    baseline: an svg has no baseline of its own, and a flex item without
    one aligns its bottom edge.  Centring the box on the line box put it
    against the line-height rather than the letters.  The crop box is the
    drawing's own extremes, so overflow stays visible or the antialiased
    edge pixels are cut off.  */
header.bar .brand svg{height:.705em; width:auto; color:var(--accent);
  display:block; overflow:visible}
header.bar .brand:hover{color:var(--accent)}
header.bar .where{
  font-family:var(--mono); font-size:.75rem; color:var(--ink-faint);
  overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
}
header.bar .grow{flex:1}
svg.i{width:1em; height:1em; flex:none; vertical-align:-.12em}
header.bar .src, header.bar label{
  display:inline-flex; align-items:center; gap:.45rem;
  font-family:var(--mono); font-size:.72rem;
  color:var(--ink-soft); background:none; cursor:pointer;
  text-decoration:none; border:1px solid var(--rule-strong);
  padding:.32rem .6rem; white-space:nowrap;
}
header.bar .src:hover, header.bar label:hover,
input.menu-x:checked + label{
  color:var(--accent); border-color:var(--accent-soft);
}
.dark-only{display:none}
.light-only{display:inline-block}
@media (prefers-color-scheme: dark){
  :root:not(:has(#theme:checked)) .dark-only{display:inline-block}
  :root:not(:has(#theme:checked)) .light-only{display:none}
}
@media (prefers-color-scheme: light), (prefers-color-scheme: no-preference){
  :root:has(#theme:checked) .dark-only{display:inline-block}
  :root:has(#theme:checked) .light-only{display:none}
}
.sr-only, input.theme-x, input.menu-x{
  position:absolute; width:1px; height:1px; margin:-1px; padding:0;
  border:0; overflow:hidden; clip-path:inset(50%); white-space:nowrap;
}
/*  `~`, not `+`: the theme box's script sits between it and its label,
    so the adjacent-sibling form never matched and the switch showed no
    focus at all.  */
input.theme-x:focus-visible ~ label[for="theme"],
input.menu-x:focus-visible + label{
  outline:2px solid var(--accent); outline-offset:2px;
}
/*  The menu box is an invisible tab stop where there is no menu.  */
@media (width > 60rem){ input.menu-x{display:none} }
@media (max-width:35rem){
  :root{--bar:3.75rem}
  header.bar{gap:.45rem; padding:0 .65rem}
  /*  A phone keeps its place in the document, cut short, and gets the
      room discuss and source took: those two move to the foot of the
      drawer, where a reader looking for them opens the menu anyway.  */
  header.bar .where{min-width:0; flex:1 1 auto; font-size:.7rem}
  header.bar .grow{display:none}
  header.bar .src{display:none}
  header.bar label{height:2.75rem; justify-content:center; padding:0 .7rem}
  header.bar label[for="theme"]{width:2.75rem; gap:0; padding:0}
  header.bar label[for="theme"] span{
    position:absolute; width:1px; height:1px; margin:-1px; padding:0;
    border:0; overflow:hidden; clip-path:inset(50%); white-space:nowrap;
  }
}
/*  On a phone narrower than the menu's word needs, the icon alone.  */
@media (max-width:22rem){
  header.bar label[for="menu"]{width:2.75rem; gap:0; padding:0}
  header.bar label[for="menu"] span{
    position:absolute; width:1px; height:1px; margin:-1px; padding:0;
    border:0; overflow:hidden; clip-path:inset(50%); white-space:nowrap;
  }
}
header.bar label[for="menu"]{display:none}
/*  The drawer's foot: discuss and source, where a phone's bar has no
    room for them.  Hidden wherever the bar still carries them.  */
nav.side .side-foot{display:none}
label.scrim{display:none}

/* ---- layout ---- */
.wrap{display:grid; grid-template-columns:16.5rem minmax(0,1fr); align-items:start}

/* ---- the sidebar: the documents in five groups, and the sections of
        the one being read nested under it ---- */
nav.side{
  position:sticky; top:var(--bar); align-self:start;
  height:calc(100vh - var(--bar)); overflow:auto; overscroll-behavior:contain;
  padding:1.2rem 0 3rem; border-right:1px solid var(--rule);
  font-size:.875rem; scrollbar-width:thin;
}
nav.side a{display:block; color:var(--ink-soft); text-decoration:none; line-height:1.35;
  text-wrap:pretty}
/*  Inside the link: the drawer and the sidebar clip anything outside.  */
nav.side a:focus-visible{outline-offset:-2px}
nav.side a.doc{padding:.26rem 1rem .26rem 1.25rem; border-left:2px solid transparent}
nav.side a.doc:hover{color:var(--accent)}
nav.side a.doc.here{color:var(--accent); border-left-color:var(--accent); font-weight:650}
nav.side a.doc.retired{color:var(--ink-faint)}
nav.side details{margin-top:1rem}
nav.side summary{
  list-style:none; cursor:pointer; user-select:none;
  display:flex; align-items:center; gap:.5rem;
  padding:.2rem 1rem .4rem 1.25rem;
  font-family:var(--mono); font-size:.72rem; color:var(--ink-faint);
}
nav.side summary::-webkit-details-marker{display:none}
nav.side summary .count{margin-left:auto; font-size:.68rem}
/*  A chevron drawn from two borders, so it needs neither an icon nor a
    glyph the face might not have.  */
nav.side summary::after{
  content:""; width:.34rem; height:.34rem; flex:none;
  border-right:1.5px solid currentColor; border-bottom:1.5px solid currentColor;
  transform:translateY(-.1rem) rotate(45deg); transition:transform .15s;
}
nav.side details:not([open]) > summary::after{transform:rotate(-45deg)}
nav.side details[open] > summary .count{visibility:hidden}
nav.side summary:hover{color:var(--ink)}
nav.side .toc{margin:.2rem 0 .55rem 1.35rem; border-left:1px solid var(--rule)}
/*  The documents write their section titles in three cases -- THE
    GRAMMAR OF THE ENABLED KERNEL, chip/vendor/gpio, Canonical release --
    and the renderer sets the shouted ones in sentence case, so the list
    reads as one without an uppercase transform flattening identifiers.  */
nav.side a.sect{
  padding:.22rem .75rem .22rem .8rem; margin-left:-1px;
  border-left:1px solid transparent;
  font-size:.8rem; line-height:1.4; color:var(--ink-soft);
}
nav.side a.sect:hover{color:var(--ink)}
nav.side a.sect.here{color:var(--ink); border-left-color:var(--accent)}
/*  A section's own entries, under it, where a page lists them: indented,
    smaller, and with the script running, shown only under the section
    being read.  */
nav.side .subs a.sect{padding-left:1.55rem; font-size:.76rem}
nav.side .toc.folding .subs{display:none}
nav.side .toc.folding .subs.open{display:block}
/*  Where a document's teaching ends and its reference begins.  */
nav.side .toc .divide{display:block; margin:.6rem 0 .25rem; padding:.45rem .75rem 0 .8rem;
  border-top:1px solid var(--rule); font-family:var(--mono); font-size:.68rem;
  color:var(--ink-faint)}
nav.side .toc .divide ~ a.sect:not(.here){color:var(--ink-faint)}
nav.side .toc .divide ~ a.sect:not(.here):hover{color:var(--ink)}

main{padding:2.75rem 3rem 6rem; min-width:0; max-width:62rem}

/* ---- hero ---- */
.hero{border-bottom:1px solid var(--rule); padding-bottom:2rem; margin-bottom:.5rem}
/*  A title with nothing under it needs no rule to end it, and the first
    section follows it closely rather than across an empty band.  */
.hero.bare{border-bottom:0; padding-bottom:0; margin-bottom:0}
.hero.bare h1{margin-bottom:0}
.hero + section{padding-top:1.75rem}
.hero.bare + section{padding-top:1.25rem}
.hero h1{
  margin:.45rem 0 1rem; font-size:clamp(1.8rem, 1.3rem + 1.9vw, 2.6rem);
  line-height:1.08; letter-spacing:-.025em; font-weight:650; text-wrap:balance;
}
.hero p{margin:.6rem 0; max-width:42rem; color:var(--ink-soft)}
.hero p:first-of-type{color:var(--ink); font-size:1.1rem; line-height:1.55}
.hero pre{
  margin:.7rem 0; padding:.7rem .9rem; overflow-x:auto;
  background:var(--code-bg); border:1px solid var(--rule);
  font-size:.82rem; line-height:1.55; color:var(--ink-soft);
}
.hero blockquote{
  margin:.7rem 0; padding:.1rem 0 .1rem 1rem;
  border-left:2px solid var(--rule); color:var(--ink-soft); max-width:42rem;
}

/* ---- sections ---- */
section{padding-top:3rem; scroll-margin-top:calc(var(--bar) + 1rem)}
/*  Every addressable heading lands clear of the sticky bar, not under it:
    from-c.html#printf put its heading at the top edge, behind the bar.  */
main [id]{scroll-margin-top:calc(var(--bar) + 1rem)}
main .item[id]{scroll-margin-top:calc(var(--bar) + 1.5rem)}
/*  A section heading outranks the text under it: larger than the body,
    in sentence case, with the rule running out to the column's edge.  */
section > h2{
  margin:0 0 1.2rem; font-size:1.35rem; line-height:1.3; font-weight:700;
  letter-spacing:-.01em; color:var(--ink); text-wrap:balance;
  display:flex; align-items:baseline; gap:.9rem;
}
section > h2::after{content:""; flex:1 0 2rem; height:1px; background:var(--rule);
  align-self:center}
/*  Prose keeps a reading measure; only listings, tables, panels and
    figures take the wider column.  */
section > p{max-width:42rem}

/* ---- one construct ---- */
.item{position:relative; padding:0 0 1.6rem 0;
      scroll-margin-top:calc(var(--bar) + 1.5rem)}
.item .tag{
  display:inline-block; font-size:.75rem; color:var(--ink-faint);
  text-decoration:none; margin-bottom:.2rem;
}
.item .tag:hover{color:var(--accent)}
.item:target .tag, .item.lit .tag{color:var(--accent); font-weight:700}
/*  Arriving at a construct draws a brick rule down its left edge.  */
/*  Only where the gutter holds it: narrower, the rule sat at the
    screen's edge, and the accent tag already marks the landing.  */
@media (min-width:70rem){
  .item:target::before, .item.lit::before{
    content:""; position:absolute; left:-1.1rem; top:.3rem; bottom:1.4rem;
    width:2px; background:var(--accent);
  }
}
.item p{margin:0 0 .75rem; max-width:42rem}
.item p:last-child{margin-bottom:0}
/*  An entry ending in code is spaced like one ending in prose.  */
.item > :last-child{margin-bottom:0}
@media (min-width:70rem){
  .item{padding-left:4.2rem}
  .item .tag{position:absolute; left:0; top:.55rem; margin:0}
}

/* ---- code ---- */
.listing{position:relative; margin:.4rem 0 1.1rem}
.listing pre{
  /*  The right padding is the copy button's corner, so the first line
      clears it rather than running under it.  */
  margin:0; padding:.85rem 3rem .85rem 1rem; overflow-x:auto;
  background:var(--code-bg); border:1px solid var(--code-rule);
  font-size:.82rem; line-height:1.6; tab-size:4;
}
/*  The copy button sits in the panel's top-right corner on every device,
    at full strength with a control's border: faded to .55 at rest it read
    as disabled, and on a phone its strip of its own was 36px of nothing
    above every listing.  */
.listing .copy{
  position:absolute; top:.45rem; right:.45rem;
  display:inline-flex; align-items:center; justify-content:center; gap:.35rem;
  min-width:2rem; min-height:2rem; padding:0 .4rem;
  font:inherit; font-size:.8rem; line-height:1;
  color:var(--ink-soft); background:var(--panel); cursor:pointer;
  border:1px solid var(--rule-strong);
}
.listing .copy:hover{color:var(--accent); border-color:var(--accent)}
.listing .copy .done{display:none}
.listing .copy.done .i{display:none}
.listing .copy.done .done{display:inline-block; color:var(--q)}
/*  Copied: the button says so in words, for two seconds.  */
.listing .copy.done::after{content:"copied"; font-family:var(--mono); font-size:.72rem;
  color:var(--ink)}
/*  No clipboard: the code is selected instead, and the button says so.  */
.listing .copy.manual .i{display:none}
.listing .copy.manual::after{content:"selected \2014  copy it"; padding:0 .15rem;
  font-family:var(--mono); font-size:.72rem; color:var(--accent)}
/*  On a phone a listing's comments wrap, and its code keeps its columns:
    102 of the tour's 176 listings scrolled sideways at 390px, most of
    them for a comment.  A listing marked `wraps` -- the first programs a
    reader meets -- wraps whole, each line under its own indentation.  */
@media (max-width:35rem){
  /*  And a listing runs to the screen's edges, as wide as a phone has:
      the copy button's corner costs six columns, and the page's margins
      gave back five of them.  */
  main .listing:not(figure .listing), main pre.sample:not(.listing > pre){
    margin-inline:-1.15rem}
  main .listing:not(figure .listing) pre, main pre.sample:not(.listing > pre){
    border-inline:0; padding-left:1.15rem}
  main figure.panel{margin-inline:-1.15rem; max-width:none; border-inline:0}
  main figure.panel .listing pre{padding-left:1.15rem}
  .listing pre :is(.c, .cd){white-space:pre-wrap}
  .listing.wraps pre{white-space:pre-wrap; overflow-wrap:anywhere}
  .listing.wraps pre .ln{display:block;
    padding-left:calc((var(--i, 0) + 2) * 1ch); text-indent:calc((var(--i, 0) + 2) * -1ch)}
}
/*  A panel that scrolls sideways says so at its right edge (JS marks one
    that overflows, and unmarks it at the end of its scroll).  */
.overflows{
  -webkit-mask-image:linear-gradient(to right, #000 calc(100% - 2.75rem), transparent);
  mask-image:linear-gradient(to right, #000 calc(100% - 2.75rem), transparent);
}
pre.sample:not(.listing > pre){
  margin:.15rem 0 .85rem; padding:.55rem .85rem; overflow-x:auto;
  background:var(--code-bg); border:1px solid var(--rule);
  font-size:.82rem; line-height:1.55;
}
.k{color:var(--k)} .t{color:var(--t)} .f{color:var(--f)} .d{color:var(--d); font-weight:650}
.n{color:var(--n)} .q{color:var(--q)} .v{color:var(--b)} .b{color:var(--b); font-weight:600}
.s{color:var(--ink)} .o{color:var(--o)}
.c{color:var(--c); font-style:italic} .cd{color:var(--cd)}
pre a.cite, pre a.cite:hover{color:inherit; text-decoration-style:dotted}

/* ---- citations ---- */
/*  A citation, and a link whose text is code, is quiet: the ink of the
    prose around it with an accent underline, and the accent itself only
    under the pointer or the keyboard.  Accent text in every sentence --
    three citations a line in places -- outshouted the prose, and the
    navigation and real links, which keep it.  */
a.cite, :is(p,li,td,th,dd,blockquote,figcaption) a:has(> code:only-child){
  color:var(--ink-soft); text-decoration:underline; text-decoration-style:dotted;
  text-decoration-thickness:1px; text-underline-offset:.22em;
  text-decoration-color:var(--accent-soft);
}
a.cite{font-size:.9em}
:is(p,li,td,th,dd,blockquote,figcaption) a:has(> code:only-child) code{color:inherit}
a.cite:is(:hover,:focus-visible),
:is(p,li,td,th,dd,blockquote,figcaption) a:has(> code:only-child):is(:hover,:focus-visible){
  color:var(--accent); text-decoration-style:solid; text-decoration-color:currentColor;
}
a.cite:hover{background:var(--accent-bg)}
#pop{
  position:absolute; z-index:60; max-width:29rem; display:none;
  padding:.65rem .8rem; font-size:.86rem; line-height:1.5;
  color:var(--ink); background:var(--panel); box-shadow:var(--sh);
  border:1px solid var(--rule);
}
#pop .tag{font-size:.72rem; color:var(--accent); display:block; margin-bottom:.2rem}
#pop .go{display:block; margin-top:.45rem; font-family:var(--mono); font-size:.75rem}

/*  The footer's rule starts where main's content starts, not 3rem to the
    left of it in the padding.  */
footer{
  grid-column:2; justify-self:start;
  margin:0 3rem 4rem; padding:1.25rem 0 0;
  border-top:1px solid var(--rule);
  color:var(--ink-faint); font-size:.78rem; line-height:1.7; max-width:56rem;
}
footer code{font-size:.9em; color:var(--ink-soft)}
footer .totop{float:right; margin-left:1rem}
.anchor{position:absolute; scroll-margin-top:calc(var(--bar) + 1rem)}

@media (max-width:60rem){
  .wrap{grid-template-columns:minmax(0,1fr)}
  footer{grid-column:1; margin-left:1.15rem; margin-right:1.15rem}
  /*  The drawer runs the full height under the bar, over a scrim that
      closes it when tapped -- a second label for the box, so that works
      without a script too -- and the page behind it does not scroll.  */
  nav.side{
    position:fixed; inset:var(--bar) auto 0 0; width:min(22rem, 88vw);
    /*  Stretched, not the sidebar's `align-self:start`: a fixed box
        aligned to its start shrinks to its content, and the drawer ran
        past the screen's foot with nothing to scroll.  */
    height:auto; max-height:none; align-self:stretch;
    background:var(--bg); border-right:1px solid var(--rule);
    box-shadow:var(--sh); z-index:35; display:none; padding-bottom:1.5rem;
  }
  /*  A checkbox rather than a button, so the drawer opens without a
      script; the script only closes it again after a link is followed.  */
  :root:has(#menu:checked) nav.side{display:block}
  :root:has(#menu:checked) label.scrim{display:block; position:fixed;
    inset:var(--bar) 0 0 0; z-index:34; cursor:pointer;
    background:oklch(0.2 0.02 255 / .35)}
  :root:has(#menu:checked){overflow:hidden}
  header.bar label[for="menu"]{display:inline-flex}
  main{padding:1.75rem 1.15rem 5rem}
  /*  A finger needs a target: at least 24px a link in the drawer.  */
  nav.side a.doc, nav.side a.sect{padding-block:.5rem; min-height:24px}
}
@media (max-width:35rem){
  nav.side .side-foot{display:flex; gap:.6rem; margin:1.4rem 1.25rem 0;
    padding-top:1rem; border-top:1px solid var(--rule)}
  nav.side .side-foot a{display:inline-flex; align-items:center; gap:.45rem;
    padding:.55rem .75rem; border:1px solid var(--rule-strong);
    font-family:var(--mono); font-size:.75rem; color:var(--ink-soft)}
  nav.side .side-foot a:hover{color:var(--accent); border-color:var(--accent)}
}
"""
CSS = CSS.replace("{DARK}", DARK)

#  The paper's rules come last, after GUIDE_CSS and anything a page adds:
#  written inside CSS, before GUIDE_CSS, its square bullets lost to the
#  guide's own `list-style:none` at the same specificity, and every list
#  printed without a marker.
PRINT_CSS = """
/*  Paper is light whatever the screen was: the dark values printed pale
    ink on white.  */
@media print{
  :root, :root:has(#theme:checked), :root:not(:has(#theme:checked)){
    color-scheme:light;
    --bg:#fff; --bg-soft:#fff; --panel:#fff; --panel-2:oklch(0.96 0.005 85);
    --ink:#000; --ink-soft:oklch(0.3 0.015 255); --ink-faint:oklch(0.42 0.015 250);
    --rule:oklch(0.8 0.01 85); --rule-soft:oklch(0.88 0.01 85); --rule-strong:oklch(0.6 0.01 85);
    --accent:oklch(0.45 0.15 30); --accent-soft:oklch(0.6 0.1 30); --accent-bg:#fff;
    --code-bg:#fff; --term-bg:#fff; --term-ink:#000;
    --k:oklch(0.42 0.1 350); --t:oklch(0.42 0.1 190); --f:oklch(0.42 0.1 260);
    --n:oklch(0.42 0.1 300); --q:oklch(0.42 0.1 130); --b:oklch(0.42 0.1 60);
    --cd:oklch(0.42 0.06 140); --d:#000; --c:oklch(0.42 0.015 250); --o:oklch(0.42 0.015 250);
  }
  @page{margin:18mm 16mm}
  header.bar, nav.side, .listing .copy, footer .totop, nav.next, #pop{display:none}
  body{background:#fff; color:#000}
  .wrap{display:block}
  main{max-width:42rem; padding:0}
  .listing pre, pre.sample{white-space:pre-wrap; padding-right:1rem}
  .overflows{-webkit-mask-image:none; mask-image:none}
  a{color:inherit}
  h1, h2, h3, .item > .tag{break-after:avoid}
  .item > h3, .listing, figure.panel{break-inside:avoid}
  .guide ul:not([class]){list-style:square; padding-left:1.2rem}
  .guide ul:not([class]) > li::before{display:none}
  .item:target::before, .item.lit::before{display:none}
  label.scrim{display:none}
  footer{margin:2rem 0 0}
}
"""

#  The stacks are substituted rather than written above, because the list
#  of vendored families is assets/fonts.py's to keep, and the CSS is one
#  literal full of braces that `format` would read as fields.
CSS = (CSS.replace("{UI_STACK}", fonts.stack("ui"))
          .replace("{MONO_STACK}", fonts.stack("mono")))

#  The faces themselves are files beside the pages, not data: urls: the
#  thirty subsets come to a megabyte, and a page that carried even the
#  four an English reader needs would be 140 KiB heavier for glyphs the
#  next page would carry again.  The declarations are inlined, so a page
#  still knows what it wants to be set in; `font-display:swap` is what
#  makes a page whose faces did not arrive readable rather than blank.
#
#  A host without the licensed code face renders without it -- the pages
#  fall to the stack behind the family -- and says so once, here, rather
#  than failing: the build that must not go out that way is the publish,
#  and scripts/site.sh is what refuses it.
FONT_CSS = fonts.css()
for _family in fonts.missing():
    print("render_html: %s is not available on this host; the pages "
          "fall back to the stack behind it" % _family, file=sys.stderr)

#  The theme switch remembers itself.  It stores the theme chosen rather
#  than the box's state, because the box means "not what the system
#  asked for" and the system can change its mind between two pages; a
#  choice that agrees with the system is forgotten, so the page follows
#  the system again.  It runs inline, straight after the box, so the box
#  is set before the first paint and no page flashes the other theme.
THEME_JS = (
    "(function(){var b=document.getElementById('theme');"
    "var d=matchMedia('(prefers-color-scheme: dark)').matches;"
    "try{var s=localStorage.getItem('landin-theme');"
    "if(s)b.checked=(s==='dark')!==d;}catch(e){}"
    #  The switch is named by what it does next, not by what it is: a
    #  screen reader heard "theme, checkbox, not checked", which says
    #  neither which theme is showing nor which one a press gives.
    "function say(){b.setAttribute('aria-label',(b.checked!==d)?"
    "'switch to light theme':'switch to dark theme');}say();"
    "b.addEventListener('change',function(){say();"
    "try{if(b.checked)localStorage.setItem('landin-theme',d?'light':'dark');"
    "else localStorage.removeItem('landin-theme');}catch(e){}});})();")

#  How much of a paragraph a citation preview shows.  The longest
#  construct opens with four thousand characters, which is a page and not
#  a preview; the median is under three hundred and is shown whole.
PREVIEW = 400

JS = """
(function(){
  var PREVIEW=%d, MONO=%s;
  var root=document.documentElement;
  var side=document.querySelector('nav.side');
  var menu=document.getElementById('menu');
  /* The box says whether the drawer it controls is open, and opening it
     brings the section being read into view inside it, rather than the
     top of a list forty entries long. */
  function opened(){
    if(!menu) return;
    menu.setAttribute('aria-expanded',menu.checked?'true':'false');
    if(menu.checked && side){
      var here=side.querySelector('a.sect.here')||side.querySelector('a.doc.here');
      if(here) requestAnimationFrame(function(){
        here.scrollIntoView({block:'center',behavior:'instant'});
      });
    }
  }
  if(menu){ menu.addEventListener('change',opened); opened(); }
  function closeMenu(focus){
    if(!menu || !menu.checked) return;
    menu.checked=false;
    opened();
    if(focus) menu.focus();
  }
  if(side) side.addEventListener('click',function(e){
    if(e.target.closest('a')) closeMenu(false);
  });
  document.addEventListener('keydown',function(e){
    if(e.key==='Escape') closeMenu(true);
  });

  /* A short in-page jump glides; a long one, or any jump for a reader who
     asked for less motion, lands at once.  The browser still follows the
     link itself, so :target, the history and hashchange are what they
     would be without this. */
  var calm=matchMedia('(prefers-reduced-motion: no-preference)');
  var glide=0;
  document.addEventListener('click',function(e){
    var a=e.target.closest('a[href^="#"]');
    if(!a || e.defaultPrevented || e.button || e.metaKey || e.ctrlKey ||
       e.shiftKey || e.altKey || !calm.matches) return;
    var id; try{ id=decodeURIComponent(a.getAttribute('href').slice(1)); }catch(_){ return; }
    var t=id && document.getElementById(id); if(!t) return;
    if(Math.abs(t.getBoundingClientRect().top)>2*innerHeight) return;
    root.style.scrollBehavior='smooth';
    clearTimeout(glide);
    glide=setTimeout(function(){ root.style.scrollBehavior=''; },900);
  });

  /* A deep link lands, and then the faces arrive and every line above it
     reflows: on a cold cache it ended thousands of pixels away.  Once the
     faces are in, land again -- unless the reader has already moved. */
  (function(){
    var fragment=location.hash; if(fragment.length<2) return;
    if(document.fonts && document.fonts.status==='loaded') return;
    var moved=false, events=['wheel','touchstart','pointerdown','keydown'];
    function stop(){ moved=true; }
    events.forEach(function(n){ addEventListener(n,stop,{passive:true}); });
    var ready=document.fonts ? document.fonts.ready : Promise.resolve();
    ready.then(function(){ requestAnimationFrame(function(){ requestAnimationFrame(function(){
      events.forEach(function(n){ removeEventListener(n,stop); });
      if(moved || location.hash!==fragment) return;
      var id; try{ id=decodeURIComponent(fragment.slice(1)); }catch(_){ return; }
      var t=document.getElementById(id);
      if(t) t.scrollIntoView({block:'start',behavior:'instant'});
    }); }); });
  })();

  /* The code face's discretionary ligatures are its own; a fallback
     face's draw a struck `st`.  They go on only once the face itself has
     loaded. */
  if(document.fonts && MONO){
    var mono=function(){
      var on=false;
      document.fonts.forEach(function(f){
        if(f.family.replace(/["']/g,'')===MONO && f.status==='loaded') on=true;
      });
      if(on) root.classList.add('mono-dlig');
      return on;
    };
    if(!mono()){
      document.fonts.addEventListener('loadingdone',function once(){
        if(mono()) document.fonts.removeEventListener('loadingdone',once);
      });
    }
  }

  /* copy a listing */
  function selectCode(b,pre){
    var r=document.createRange(); r.selectNodeContents(pre);
    var s=getSelection(); s.removeAllRanges(); s.addRange(r);
    var copied=false;
    try{ copied=document.execCommand('copy'); }catch(_){}
    if(copied){ done(b); return; }
    b.classList.add('manual');
    setTimeout(function(){ b.classList.remove('manual'); },4000);
  }
  /* Copied is said, not only drawn: the button reads "copied" for two
     seconds, and a status region tells a screen reader the same. */
  var status=document.createElement('span');
  status.className='sr-only'; status.setAttribute('role','status');
  status.setAttribute('aria-live','polite');
  document.body.appendChild(status);
  function done(b){
    b.classList.add('done');
    status.textContent='copied';
    setTimeout(function(){ b.classList.remove('done'); status.textContent=''; },2000);
  }
  document.addEventListener('click',function(e){
    var b=e.target.closest('.copy'); if(!b) return;
    var pre=b.parentNode.querySelector('pre'); if(!pre) return;
    /* The text as written: innerText follows the layout, and a listing
       that wraps on a phone sets each line as a block of its own. */
    var text=pre.textContent;
    /* A page opened from disk or served over plain http has no
       clipboard; the code is selected instead and the button says so. */
    if(navigator.clipboard && navigator.clipboard.writeText && window.isSecureContext){
      navigator.clipboard.writeText(text).then(function(){ done(b); },
        function(){ selectCode(b,pre); });
    } else selectCode(b,pre);
  });

  /* A panel that scrolls sideways fades at its right edge until its end
     is in view. */
  var wide=[].slice.call(document.querySelectorAll('.listing pre, pre.sample, .scroller'));
  function edges(){
    wide.forEach(function(n){
      var more=n.scrollWidth>n.clientWidth+1 &&
               n.scrollLeft+n.clientWidth<n.scrollWidth-2;
      n.classList.toggle('overflows',more);
    });
  }
  wide.forEach(function(n){ n.addEventListener('scroll',function(){
    n.classList.toggle('overflows',
      n.scrollLeft+n.clientWidth<n.scrollWidth-2);
  },{passive:true}); });
  edges();
  addEventListener('resize',edges,{passive:true});
  if(document.fonts) document.fonts.ready.then(edges);

  /* which section am I in */
  var where=document.getElementById('where');
  var links={}, sections=[].slice.call(document.querySelectorAll('main section'));
  /* The entries a section holds, which the bar names once one is being
     read: the site cites entries, not sections.  The sidebar still
     marks the section. */
  var items=[].slice.call(document.querySelectorAll('main .item[data-title]'));
  document.querySelectorAll('nav.side a.sect:not(.sub)').forEach(function(a){
    links[a.getAttribute('href').slice(1)]=a;
  });
  /* A section's own entries in the sidebar show only under the section
     being read, where the list would otherwise run to forty. */
  var folds=[].slice.call(document.querySelectorAll('nav.side .toc[data-fold] .subs'));
  folds.forEach(function(f){ f.parentNode.classList.add('folding'); });
  /* Which one is decided by where the sections are, not by which ones a
     margin happens to overlap.  An observer band starting above the
     landing point meant the tail of the previous section was still inside
     it, and the first intersecting section in document order won -- so
     clicking a section highlighted the one before it. */
  if(sections.length){
    var bar=document.querySelector('header.bar');
    /*  The bar says which document you are reading until a titled section
        reaches the line, so the top of the page keeps its label. */
    var kind=where?where.textContent:'';
    var last=0;
    /*  A section lands a little below the bar's bottom edge, so the line
        that decides which one you are in is set below that landing.  */
    function line(){ return (bar?bar.getBoundingClientRect().bottom:48)+32; }
    function current(){
      var at=line(), best=null;
      sections.forEach(function(s){
        if(s.classList.contains('hide')) return;
        if(s.getBoundingClientRect().top<=at) best=s;
      });
      return best;
    }
    /*  The last entry whose top has passed the line, found by halving:
        the tour has four hundred.  Only one inside the current section
        counts, so a section's opening prose names the section.  */
    function entry(section){
      if(!section || !items.length) return null;
      var at=line(), lo=0, hi=items.length-1, best=-1;
      while(lo<=hi){
        var mid=(lo+hi)>>1;
        if(items[mid].getBoundingClientRect().top<=at){ best=mid; lo=mid+1; }
        else hi=mid-1;
      }
      var it=best<0?null:items[best];
      return it && section.contains(it) ? it : null;
    }
    function mark(){
      var now=current(), it=entry(now);
      if(where) where.textContent=(it&&it.dataset.title)||(now&&now.dataset.title)||kind;
      folds.forEach(function(f){
        f.classList.toggle('open',!!now && f.dataset.of===now.id);
      });
      Object.keys(links).forEach(function(k){
        var on=!!now && (k===now.id);
        links[k].classList.toggle('here',on);
        if(on){ links[k].setAttribute('aria-current','true'); }
        else { links[k].removeAttribute('aria-current'); }
      });
    }
    /*  Coalesced on a clock rather than on an animation frame: a frame
        never arrives in a hidden tab, and a pending flag waiting for one
        stays set, so the highlight stopped updating for good.  The last
        event of a burst is always marked, on a timer: dropping it left
        the highlight wherever a smooth scroll was 50ms before it
        stopped, which is the section before the one it landed on.  */
    var trailing=0;
    function schedule(){
      var now=Date.now();
      clearTimeout(trailing);
      trailing=setTimeout(mark,60);
      if(now-last<50) return;
      last=now;
      mark();
    }
    addEventListener('scroll',schedule,{passive:true});
    addEventListener('resize',schedule,{passive:true});
    addEventListener('hashchange',schedule);
    mark();
  }

  /* what a citation says, without leaving the line */
  var pop=document.getElementById('pop');
  var shown=null, closing=0, tapped=null;
  var touch=matchMedia('(hover: none)');
  function hide(){
    clearTimeout(closing);
    if(shown) shown.removeAttribute('aria-describedby');
    shown=null; tapped=null;
    if(pop) pop.style.display='none';
  }
  /* The preview stays while the pointer is on the citation or on the
     preview itself, and closes a moment after it leaves both: it used to
     close as the pointer crossed the gap into it. */
  function later(){ clearTimeout(closing); closing=setTimeout(hide,150); }
  function keep(){ clearTimeout(closing); }
  /* A citation of another page cannot read its paragraph out of this
     one, so the page carries what each of those says; before it did,
     only the specification's own citations of itself had a preview. */
  var says=null;
  function brief(text){
    if(text.length<=PREVIEW) return text;
    var cut=text.lastIndexOf(' ',PREVIEW);
    return text.slice(0,cut>0?cut:PREVIEW)+'\\u2026';
  }
  function said(id){
    if(says===null){
      var s=document.getElementById('says');
      try{ says=s?JSON.parse(s.textContent):{}; }catch(e){ says={}; }
    }
    return says[id];
  }
  /* Which document a citation of another page leads into: the preview
     says "spec [2000]", not a bare number that reads as this page's. */
  function docName(href){
    var file=href.split('#')[0].replace(/\\.html$/,'');
    var m=/^prototype-(\\d)$/.exec(file);
    return m ? 'prototype '+m[1] : file;
  }
  function show(a){
    if(!a||!pop) return;
    keep();
    if(shown===a) return;
    var href=a.getAttribute('href'), text, at='';
    if(href.charAt(0)==='#'){
      var t=document.getElementById(href.slice(1)); if(!t) return;
      /* A construct whose body is only code has no paragraph -- [0010] is
         one line of comment and a fence -- and the preview used to show
         nothing at all for those.  Its heading says what it is.  A
         finding's anchor sits inside the paragraph it opens. */
      var p=t.closest('p')||t.querySelector('p')||t.querySelector('h3');
      if(!p) return;
      text=brief(p.textContent);
    } else {
      text=said(a.dataset.cite); if(!text) return;
      at=docName(href)+' ';
    }
    if(shown) shown.removeAttribute('aria-describedby');
    shown=a;
    var name=at+'['+a.dataset.cite+']';
    pop.textContent='';
    var tag=document.createElement('span');
    tag.className='tag mono'; tag.textContent=name;
    pop.appendChild(tag);
    pop.appendChild(document.createTextNode(text));
    var go=document.createElement('a');
    go.className='go'; go.href=href; go.textContent='go to '+name+' \\u2192';
    pop.appendChild(go);
    pop.style.display='block';
    var r=a.getBoundingClientRect(), w=pop.offsetWidth, h=pop.offsetHeight;
    /* clientWidth, not innerWidth: the latter counts the scrollbar, and the
       preview slid under it at the right edge. */
    var room=document.documentElement.clientWidth;
    var left=Math.min(r.left+window.scrollX, window.scrollX+room-w-16);
    var top=r.top+window.scrollY-h-8;
    if(top<window.scrollY+8) top=r.bottom+window.scrollY+8;
    pop.style.left=Math.max(window.scrollX+8,left)+'px';
    pop.style.top=top+'px';
    a.setAttribute('aria-describedby','pop');
  }
  /* A citation is a link, so it is already in the tab order; hovering was
     the only way to read what it says, which left the keyboard and every
     touch device out. */
  var CITED='a[data-cite]';
  document.addEventListener('mouseover',function(e){
    if(touch.matches) return;
    var a=e.target.closest(CITED);
    if(a) show(a);
    else if(pop && pop.contains(e.target)) keep();
  });
  document.addEventListener('mouseout',function(e){
    if(touch.matches || !shown) return;
    var from=e.target, to=e.relatedTarget;
    var inside=function(n){ return n && (shown.contains(n) || pop.contains(n)); };
    if(inside(from) && !inside(to)) later();
  });
  /* A tap focuses the link before it clicks it.  Opened on that focus,
     the preview moved the page under the finger, the click landed on the
     body and closed it again: under a touch, the click opens it and the
     focus that precedes it is ignored.  Keyboard focus still opens it. */
  var pressed=0;
  function press(e){
    if(e.type==='touchstart' || e.pointerType==='touch' || e.pointerType==='pen')
      pressed=Date.now();
  }
  addEventListener('pointerdown',press,{passive:true,capture:true});
  addEventListener('touchstart',press,{passive:true,capture:true});
  function touching(){ return Date.now()-pressed<1000; }
  document.addEventListener('focusin',function(e){
    var a=e.target.closest(CITED);
    if(a){ if(!(touch.matches && touching())) show(a); }
    else if(pop && pop.contains(e.target)) keep();
  });
  document.addEventListener('focusout',function(e){
    if(shown && !(e.relatedTarget && (pop.contains(e.relatedTarget) ||
                                      shown.contains(e.relatedTarget)))) later();
  });
  /* Where nothing hovers, the first tap on a citation shows what it says,
     with a link to follow; a second tap on it follows.  A tap focuses the
     link before it clicks it, so being shown is not the same as having
     been tapped once. */
  document.addEventListener('click',function(e){
    if(!touch.matches) return;
    var a=e.target.closest(CITED);
    if(a && !pop.contains(a)){
      if(tapped!==a){ e.preventDefault(); shown=null; show(a); tapped=a; }
      return;
    }
    if(shown && !pop.contains(e.target)) hide();
  });
  document.addEventListener('keydown',function(e){ if(e.key==='Escape') hide(); });
  window.addEventListener('scroll',function(){ if(!touch.matches) hide(); },{passive:true});

  /* light up the construct a link arrives at */
  var unlit=0;
  function lit(){
    document.querySelectorAll('.lit').forEach(function(n){ n.classList.remove('lit'); });
    clearTimeout(unlit);
    if(location.hash.length>1){
      var t=document.getElementById(location.hash.slice(1));
      if(t){
        t.classList.add('lit');
        /* The light is for arriving; it goes out after a few seconds. */
        unlit=setTimeout(function(){ t.classList.remove('lit'); },4000);
      }
    }
  }
  window.addEventListener('hashchange',function(){ hide(); lit(); }); lit();
})();
""" % (PREVIEW, json.dumps("" if fonts.family("mono") in fonts.missing()
                           else fonts.family("mono")))


def esc(text):
    return html.escape(text, quote=False)


def attr(text):
    """For a value that lands inside "..." -- esc leaves quotes alone, and
    a heading with a quotation mark in it would end the attribute early."""
    return html.escape(text)


TICKED = re.compile(r"`([^`]+)`")


def prose_html(text, links):
    out = cite_links(esc(text), links)
    return TICKED.sub(lambda m: f"<code>{m.group(1)}</code>", out)


def slug(title):
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s or "section"


def listing(code_html, label="", wrap=False):
    if wrap:
        code_html = hanging(code_html)
    return listing_of(f"<pre>{code_html}</pre>", label, wrap)


#  A line's leading spaces, read off its highlighted HTML: the scanner
#  leaves whitespace outside any span, and entities are never spaces.
LEADING = re.compile(r"^((?:<span[^>]*>)*)( *)")


def hanging(code_html):
    """Each line of a listing as a span of its own, carrying its indent.

    On a phone a listing marked `wraps` wraps whole, and each line's
    continuation hangs two columns in from where the line itself starts,
    so a wrapped call still reads as the statement it is part of.  The
    line break stays inside the span, as text, so the page copies, reads
    and verifies as the listing it was; wide, the spans are inline and
    nothing changes.
    """
    lines = code_html.split("\n")
    out = []
    for at, line in enumerate(lines):
        indent = len(LEADING.match(line).group(2))
        style = f' style="--i:{indent}"' if indent else ""
        end = "\n" if at + 1 < len(lines) else ""
        out.append(f'<span class="ln"{style}>{line}{end}</span>')
    return "".join(out)


def listing_of(pre_html, label="", wrap=False):
    """The frame around a listing whose <pre> is already built.

    A <pre> may not contain a <pre>, and render_sample returns one of its
    own; wrapping that in another produced markup no parser is obliged to
    read the same way.
    """
    #  138 buttons on the tour all read "copy" and nothing else, which is
    #  what a screen reader announces, one after another.  The construct
    #  the listing belongs to is the only thing that tells them apart.
    says = (f'copy the code for [{label}]' if label else "copy the code")
    return (f'<div class="listing{" wraps" if wrap else ""}">{pre_html}'
            f'<button class="copy" type="button" aria-label="{says}" '
            f'title="{says}">' + icons.use("copy") + icons.use("check", "i done")
            + "</button></div>")


def render_landin(lines, hl, wrap=False):
    """A block tagged `landin` is Landin, and every line of it is highlighted.

    Nothing is guessed here, because the fence already said what the block
    is.  render_sample below has to guess, because it reads an indented
    block from the .txt era that carried no tag; run over a tagged block it
    asks `known_only` of each line and leaves as plain text every line
    holding an ordinary name — which was most of them.  Fifty-eight blocks
    across the tour and the four prototypes rendered with no highlighting
    at all, and every word was on the page, so the gate saw nothing.
    """
    code = "\n".join(hl.line(l) if l.strip() else "" for l in lines)
    return '<pre class="sample">' + (hanging(code) if wrap else code) + "</pre>"


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
    dict(key="documents", src="docs/documents.md", out="documents.html",
         nav="how the documents are arranged", group="the language",
         blurb="Where each kind of rule lives in the specification and the "
               "tour, where a new one goes, and what the arrangement is "
               "and is not evidence of."),
    dict(key="examples", src="examples.md", out="examples.html",
         nav="running examples", group="the language",
         blurb="Complete programs to copy and run, each printing what it "
               "computes: everyday tools, printing and failures, the classic "
               "exercises and the Benchmark Game ports."),
    dict(key="from-c", src="docs/from-c.md", out="from-c.html",
         nav="for C programmers", group="the language", captions=True,
         nest=True,
         blurb="Each habit a C programmer brings, from `#include` to "
               "`exit`, in its Landin form, and the habits with no answer "
               "yet."),
    dict(key="readme", src="README.md", out="readme.html",
         nav="the project", group="the project",
         blurb="What Landin is, what is in the repository, and how to build "
               "the part of it that exists."),
    dict(key="roadmap", src="ROADMAP.md", out="roadmap.html",
         nav="the roadmap", group="the project",
         blurb="The sole authority for open work: phases, dependencies, "
               "gates, and the register of work waiting for a trigger."),
    dict(key="handoff", src="handoff.md", out="handoff.html",
         nav="the design, in one page", group="the project",
         blurb="The design and the principles behind it, and which "
               "decisions must not be quietly reversed."),
    dict(key="compiler", src="compiler/ada/README.md", out="compiler.html",
         nav="the bootstrap compiler", group="the implementation",
         blurb="The Ada 2022 chassis: what each package owns, what it may "
               "not own, and what is deliberately absent."),
    dict(key="core", src="core/README.md", out="core.html",
         nav="the core modules", group="the implementation",
         blurb="Explicit allocator capabilities, collections and the "
               "constrained CPU library, with their module boundaries."),
    dict(key="devices", src="devices/README.md", out="devices.html",
         nav="generated device fixtures", group="the implementation",
         blurb="Pinned vendor sources, deterministic Landin modules and "
               "independent device-consumer evidence."),
    dict(key="driver", src="compiler/tests/driver/DERIVATION.md", out="driver.html",
         nav="the derived driver", group="the implementation",
         blurb="Prototype 1's executable application, public DMA contract, "
               "device adaptations and independent execution evidence."),
    dict(key="diagnostics", src="docs/diagnostics.md",
         out="diagnostics.html",
         nav="what each diagnostic means", group="the implementation",
         blurb="Every diagnostic code: the rule it enforces, the paragraph "
               "that states it, and what to change. What `refine explain` "
               "prints."),
    dict(key="format", src="docs/format.md", out="format.html",
         nav="how a source is laid out", group="the implementation",
         blurb="The one layout `refine fmt` gives every source: each rule "
               "with a program as written and as formatted."),
    dict(key="server", src="docs/server.md", out="server.html",
         nav="what the language server answers", group="the implementation",
         blurb="`refine lsp`: where a file belongs, what each request is "
               "answered with, and how far it reads past a syntax error."),
    dict(key="ir", src="docs/ir.md", out="ir.html",
         nav="the intermediate representation", group="the implementation",
         blurb="How checked source becomes verified, target-neutral IR, "
               "and why it takes this form. A derived implementation guide."),
    dict(key="targets", src="docs/targets.md", out="targets.html",
         nav="target contracts", group="the implementation",
         blurb="Target descriptions, ABI capabilities, symbol spelling "
               "and backend boundaries."),
    dict(key="toolchain", src="compiler/ada/TOOLCHAIN.md", out="toolchain.html",
         nav="the pinned toolchain", group="the implementation",
         blurb="One compiler, recorded exactly, with the warning policy and "
               "the checksums that verify it."),
    dict(key="environments", src="docs/environments.md",
         out="environments.html",
         nav="the environments", group="the implementation",
         blurb="Which machine produces which kind of evidence, and what "
               "runs where now that the native acceptance is retired."),
    dict(key="cortex-m", src="environments/cortex-m/README.md",
         out="cortex-m.html", nav="Cortex-M execution profile", group="the implementation",
         blurb="Pinned QEMU CPU probes and a deterministic synthetic peripheral lane, "
               "with executable evidence and explicit model limits."),
    dict(key="native-ci", src="environments/native-ci/README.md",
         out="native-ci.html", nav="native acceptance, retired",
         group="the implementation",
         blurb="The exact-revision acceptance that approved every revision "
               "through 0.2.0, kept as the record of how it worked."),
    dict(key="process", src="docs/process.md", out="process.html",
         nav="the validation workflow", group="the implementation",
         blurb="The edit, test and push loop that runs now, and the "
               "retired acceptance scopes and what they cost."),
    dict(key="editors", src="highlight/README.md", out="editors.html",
         nav="editor and IDE support", group="the implementation",
         blurb="Installable Landin highlighting for Zed, VS Code, Neovim, "
               "Vim, Emacs, Helix and the other major editor families, "
               "and the language server each of them starts."),
    dict(key="fixtures", src="compiler/tests/README.md", out="fixtures.html",
         nav="the fixtures", group="the implementation",
         blurb="The test format that has to outlive the implementation "
               "currently checking it."),
    dict(key="registers", src="compiler/tests/registers.md",
         out="registers.html",
         nav="the evidence registers", group="the implementation",
         blurb="Every construct's state, targets and owner, and every "
               "prototype derivation, held to the corpus by check.py."),
    dict(key="harness", src="compiler/tests/harness-cases/README.md",
         out="harness-cases.html",
         nav="the malformed cases", group="the implementation",
         blurb="Trees that exist to be rejected, and the fault each one "
               "carries."),
]

GUIDE_CSS = """
/*  An entry's heading outranks its text, as a section's outranks it.  */
.guide h3.sub{font:650 1.15rem/1.4 var(--ui);color:var(--ink);margin:2.2rem 0 .6rem;
  letter-spacing:-.005em}
.item > h3.sub{margin-top:0}
.item{margin-top:1.2rem}
.guide p{margin:0 0 12px}
.guide ul,.guide ol{margin:0 0 14px;padding-left:22px}
.guide li{margin:0 0 6px}
/*  The reading measure: prose, lists and quotes stop at 42rem.  */
.guide p, .guide ul:not([class]), .guide ol, .guide blockquote{max-width:42rem}
/*  A bullet is the small square the panels' captions carry, not the
    browser's disc, which sat heavy beside the mono code it introduces.
    Only a plain list: a list with a class of its own -- what a program
    uses, a library's columns -- draws its own rows.  */
.guide ul:not([class]){list-style:none;padding-left:20px}
.guide ul:not([class]) > li{position:relative}
.guide ul:not([class]) > li::before{content:"";position:absolute;left:-15px;top:.66em;
  width:5px;height:5px;background:var(--accent)}
.guide blockquote{margin:0 0 14px;padding:2px 0 2px 14px;
  border-left:2px solid var(--accent-soft);color:var(--ink-soft)}
.guide blockquote p{margin:0 0 8px}
.guide blockquote p:last-child{margin:0}
/*  A page's banner -- "You probably do not want to read this", "Not
    learning material" -- is the first thing it says and must not read
    as the faintest.  Only the pages that carry one: the README opens
    with its pitch in a quote, and that is not a warning.  */
main.banner .guide#top > blockquote:first-child{
  color:var(--ink); background:var(--panel-2); border:1px solid var(--rule);
  border-left:3px solid var(--accent); padding:.85rem 1.1rem; margin-bottom:1.6rem;
}
/*  The fine print under an entry: the tour's "The fine print:" and its
    list, set smaller and to one side of the teaching.  */
.guide aside.fine{margin:.2rem 0 1rem; padding:.15rem 0 .15rem 1rem;
  border-left:2px solid var(--rule-strong); color:var(--ink-soft);
  font-size:.9rem; max-width:42rem}
.guide aside.fine p.fine-head{margin:0 0 .35rem}
/*  A footnote in a guide: the tour's asterisk under its pitch.  */
.guide p.fine-print{margin:1.4rem 0 0}
.guide aside.fine ul:not([class]){margin-bottom:.2rem}
.guide aside.fine ul:not([class]) > li::before{background:var(--ink-faint)}
.guide p.exact{font-family:var(--mono); font-size:.75rem; color:var(--ink-faint);
  margin:.4rem 0 .9rem}
.guide p.exact a.cite{font-size:1em}
/*  A table with a long path in a cell cannot fit a phone, and nothing
    scrolled: it simply overflowed the page.  */
.scroller{overflow-x:auto; margin:0 0 16px}
/*  As wide as its cells want, up to the column: stretched to the full
    width, a table of two short columns sat its words half a page apart.  */
.guide table{width:auto;min-width:min(100%,42rem);border-collapse:collapse;
  font:400 14px/1.5 var(--ui)}
.guide th{text-align:left;font-weight:600;color:var(--ink-soft);
  border-bottom:1px solid var(--rule);padding:7px 18px 7px 0;
  vertical-align:top}
.guide td{border-bottom:1px solid var(--rule-soft);padding:7px 18px 7px 0;
  vertical-align:top}
.guide th:last-child, .guide td:last-child{padding-right:0}
.guide tr:last-child td{border-bottom:0}
.guide td code,.guide th code{white-space:nowrap}
@media (max-width:48rem){
  .guide td code{white-space:normal}
  /*  A table whose cells hold code is a list of records on a phone:
      each row a block, each cell under its column's name.  */
  .guide table.stack, .guide table.stack tbody, .guide table.stack tr,
  .guide table.stack td{display:block; width:auto}
  .guide table.stack thead{position:absolute; width:1px; height:1px;
    overflow:hidden; clip-path:inset(50%); white-space:nowrap}
  .guide table.stack tr{padding:.55rem 0; border-bottom:1px solid var(--rule)}
  .guide table.stack tr:last-child{border-bottom:0}
  .guide table.stack td{border:0; padding:.12rem 0}
  .guide table.stack td[data-label]::before{content:attr(data-label); display:block;
    font-family:var(--mono); font-size:.68rem; color:var(--ink-faint)}
}

/* ---- listings with a caption: the front page's panel, on every page ---- */
.guide figure.panel{margin:.4rem 0 1.1rem; max-width:100%}
.guide figure.panel figcaption > .source{min-width:0; overflow-wrap:anywhere; white-space:normal}
.guide figure.panel .source code{background:none; padding:0; font-size:1em;
  color:var(--ink-soft)}
figure.panel figcaption .lang{color:var(--ink-soft)}
/*  C beside Landin on the page for C programmers: the same panel, quieter,
    so the eye goes to the Landin.  */
figure.panel.lang-c{background:var(--panel-2); border-style:dashed}
figure.panel.lang-c figcaption .dot{background:var(--ink-faint)}
figure.panel.lang-c .listing pre{color:var(--ink-soft)}
/*  What a program prints: a terminal, under the listing or on its own.  */
figure.panel .foot.prints{font-family:var(--mono)}
figure.panel .out pre, figure.panel.output .listing pre{
  background:var(--term-bg); color:var(--term-ink)}
figure.panel .out .listing, figure.panel.output{background:var(--term-bg)}
figure.panel .out .copy, figure.panel.output .copy{background:var(--term-bg);
  color:var(--term-ink)}

/*  The way on, at the end of a long guide.  */
nav.next{margin:3.5rem 0 0; max-width:42rem}
nav.next a{display:block; padding:1rem 1.2rem; border:1px solid var(--rule-strong);
  text-decoration:none; color:var(--ink-soft)}
nav.next a:hover{border-color:var(--accent)}
nav.next .label{display:block; margin-bottom:.25rem}
nav.next strong{display:block; color:var(--ink); font-size:1.05rem; margin-bottom:.2rem}
nav.next a:hover strong{color:var(--accent)}

/* ---- the front page ---- */
.hero.wide h1{font-size:clamp(2rem, 1.4rem + 2.4vw, 3rem)}
.hero.wide p:first-of-type{font-size:1.15rem; text-wrap:pretty}
.hero-actions{display:flex; flex-wrap:wrap; gap:.6rem; margin:1.4rem 0 0}
.hero-actions a{
  display:inline-flex; align-items:center; min-height:2.5rem;
  padding:.45rem .95rem; border:1px solid var(--rule-strong);
  font-size:.9rem; font-weight:600; text-decoration:none; color:var(--ink);
}
.hero-actions a.primary{color:var(--bg); background:var(--accent); border-color:var(--accent)}
.hero-actions a:hover{border-color:var(--accent)}
.hero-actions a.primary:hover{background:color-mix(in oklch, var(--accent) 88%, var(--ink))}

/*  The hero's one line of status, which the section further down says
    in full.  */
.hero p.status-line{margin:1.3rem 0 0; font-family:var(--mono); font-size:.75rem;
  line-height:1.5; color:var(--ink-faint)}
.hero p.status-line a{white-space:nowrap}
/*  The status: what the README says on the left, where the roadmap is on
    the right.  */
.status{
  display:grid; grid-template-columns:2fr 1fr;
  border:1px solid var(--rule); background:var(--panel);
  color:var(--ink-soft); font-size:.92rem;
}
.status > .said{padding:1.1rem 1.25rem 1.25rem}
.status .said p.status-meta{margin:0 0 .5rem; line-height:1.4}
.status h3{margin:0 0 .6rem; color:var(--ink); font-size:1.05rem;
  line-height:1.4; font-weight:650; text-wrap:balance}
.status .said p:not(.status-meta){margin:0; color:var(--ink-soft); font-size:.92rem; line-height:1.6}
.roadmap-track{border-left:1px solid var(--rule); background:var(--bg-soft);
  padding:.9rem 1.1rem 1rem}
.roadmap-track > div{margin-bottom:.8rem}
.roadmap-head{display:block; margin:0 0 .75rem; padding-bottom:.55rem;
  border-bottom:1px solid var(--rule); font-family:var(--mono);
  font-size:.72rem; color:var(--accent); text-decoration:none}
.roadmap-head:hover{text-decoration:underline}
.status .said p.status-context{margin-top:.4rem}
.status .said p.status-links{margin-top:1rem; font-family:var(--mono);
  font-size:.75rem}
.status .said p.status-links a{color:var(--accent); text-decoration:none;
  margin-right:1.2rem}
.status .said p.status-links a:hover{text-decoration:underline}
.roadmap-track > div:last-child{margin-bottom:0}
.roadmap-label{display:block; margin-bottom:.3rem; font-family:var(--mono);
  font-size:.7rem; color:var(--ink-faint)}
.roadmap-item{display:block;
  padding:.15rem 0; color:var(--ink-soft); text-decoration:none;
  line-height:1.35; font-size:.82rem}
.roadmap-item:hover span{color:var(--accent)}
.roadmap-now .roadmap-item span{color:var(--ink); font-weight:600}

section.landing{padding-top:4rem}
section.landing > p.lead{max-width:42rem; color:var(--ink-soft); margin:-.2rem 0 1.4rem}
section.landing > .program + p.lead{margin-top:2.6rem}
/*  The pitch's asterisk, and where it sends the reader.  */
.hero a.asterisk{text-decoration:none; color:var(--accent)}
p.fine-print{margin:4rem 0 0; max-width:42rem; color:var(--ink-faint);
  font-size:.72rem; line-height:1.5}

/*  The program: one whole fixture, with what it uses beside it.  */
/*  The listing asks for its longest line and gets it: a code panel that
    scrolls sideways on a desktop is a layout that ran out of room, not a
    program that is too wide.  What it uses keeps its column only while
    both fit, and otherwise wraps underneath at full width.  Only a phone
    is left to scroll.  */
.program{display:flex; flex-wrap:wrap; gap:1.75rem; align-items:flex-start}
figure.panel{margin:0; border:1px solid var(--rule); background:var(--code-bg);
  min-width:0; flex:1 1 max-content; max-width:100%}
figure.panel figcaption, figure.panel .foot{
  display:flex; align-items:center; gap:.8rem; padding:.5rem .9rem;
  font-family:var(--mono); font-size:.72rem; color:var(--ink-faint);
  background:var(--panel-2);
}
figure.panel figcaption{border-bottom:1px solid var(--rule)}
figure.panel figcaption .path{min-width:0; overflow:hidden; text-overflow:ellipsis;
  white-space:nowrap; direction:rtl; text-align:left}
figure.panel figcaption > span:last-child{white-space:nowrap}
figure.panel figcaption .dot{width:.5rem; height:.5rem; background:var(--accent); flex:none}
/*  The file's short name: a link to its source, as quiet as the caption.  */
figure.panel figcaption a.name{color:var(--ink-soft); min-width:0;
  overflow-wrap:anywhere; text-decoration-color:var(--accent-soft)}
figure.panel figcaption a.name:hover{color:var(--accent)}
figure.panel figcaption .grow, figure.panel .foot .grow{flex:1}
figure.panel .foot{border-top:1px solid var(--rule)}
figure.panel .foot code{background:none; padding:0; font-size:1em; color:var(--ink-soft)}
figure.panel .foot a{white-space:nowrap}
figure.panel .listing{margin:0}
figure.panel .listing pre{border:0; padding:1rem 1.1rem; font-size:.82rem}
/*  A panel's own copy button sits in its caption row, at the right, so
    the code under it keeps its whole width.  A terminal under the code
    keeps its button in its own corner.  */
figure.panel{position:relative}
figure.panel > .listing{position:static}
figure.panel > figcaption{padding-right:3.1rem; min-height:2.3rem}
figure.panel > .listing .copy{top:.15rem; right:.3rem}
figure.panel .out .listing pre{padding-right:3rem}
.uses{position:sticky; top:calc(var(--bar) + 1.5rem); flex:1 0 13.5rem}
.uses .label{display:block; margin-bottom:.5rem}
.uses ul{list-style:none; margin:0; padding:0; border-top:1px solid var(--rule);
  columns:13.5rem; column-gap:1.5rem}
.uses li{border-bottom:1px solid var(--rule); break-inside:avoid}
/*  Under a program on a page, rather than beside one.  */
.uses.strip{position:static; margin:.2rem 0 1.4rem}
.uses.strip ul{columns:15rem}
.uses li a{display:grid; grid-template-columns:2.9rem 1fr; gap:.4rem;
  padding:.38rem 0; text-decoration:none; color:var(--ink-soft);
  font-size:.84rem; line-height:1.35}
.uses li a .tag{font-family:var(--mono); font-size:.72rem; color:var(--ink-faint);
  padding-top:.08rem}
.uses li a:hover{color:var(--accent)}
.uses li a:hover .tag{color:var(--accent)}
.uses p{margin:.8rem 0 0; font-size:.8rem; color:var(--ink-faint); line-height:1.5}
.uses p a{color:var(--ink-soft)}

/*  Six ways in, as one block of cells split by hairlines.  */
.routes{display:grid; grid-template-columns:1fr 1fr; gap:1px;
  background:var(--rule); border:1px solid var(--rule)}
.route{display:block; padding:1.1rem 1.25rem 1.2rem; background:var(--bg);
  text-decoration:none; color:inherit}
.route .label{display:block; margin-bottom:.35rem}
.route strong{display:block; color:var(--ink); font-size:1.02rem; margin-bottom:.3rem}
.route span.text{display:block; color:var(--ink-soft); font-size:.88rem; line-height:1.5}
.route:hover{background:var(--panel)}
.route:hover strong{color:var(--accent)}

/*  Every document, as rows under the sidebar's own groups.  */
.shelf{border-top:1px solid var(--rule)}
.shelf .group{display:grid; grid-template-columns:10.5rem minmax(0,1fr);
  border-bottom:1px solid var(--rule)}
.shelf .group > h3{margin:0; padding:.8rem 1rem .8rem 0; font-family:var(--mono);
  font-weight:500; font-size:.75rem; color:var(--ink-faint)}
/*  Every card shares the same three columns, so the shelf reads as one
    table: with the count's column sized to its own card, the blurbs
    started and ended somewhere different on every row.  */
.card{display:grid; grid-template-columns:14.5rem minmax(0,1fr) 9rem; gap:1.25rem;
  padding:.72rem 0; text-decoration:none; color:inherit;
  border-bottom:1px solid var(--rule-soft); align-items:baseline}
.shelf .group .card:last-child{border-bottom:0}
.card strong{font-weight:600; font-size:.92rem; color:var(--ink)}
.card span{color:var(--ink-soft); font-size:.86rem; line-height:1.5}
.card em{font-style:normal; font-family:var(--mono); font-size:.7rem;
  color:var(--ink-faint); text-align:right; text-wrap:balance}
.card:hover strong{color:var(--accent)}
.card.retired strong{color:var(--ink-faint); font-weight:500}

@media (max-width:70rem){
  .uses{position:static}
  .card{grid-template-columns:minmax(0,1fr) auto; row-gap:.2rem}
  .card em{white-space:nowrap}
  .card span{grid-column:1/-1; grid-row:2}
}
@media (max-width:48rem){
  .status{grid-template-columns:1fr}
  .roadmap-track{border-left:0; border-top:1px solid var(--rule)}
  .routes{grid-template-columns:1fr}
  .shelf .group{grid-template-columns:1fr}
  .shelf .group > h3{padding-bottom:0}
  /*  The run command stays on a phone, stacked above the way on.  */
  figure.panel .foot{flex-wrap:wrap; row-gap:.35rem}
  figure.panel .foot code{flex:1 1 100%; overflow-wrap:anywhere}
  figure.panel .foot .grow{display:none}
  .card{row-gap:.3rem}
}
"""

#  A hyphen is not \w, and the documents tag a fence `landin-grammar`.
#  With \w the opener never matched, so the CLOSING fence opened a block
#  that swallowed the next heading -- which showed up as every other
#  construct in spec.md losing its anchor.
FENCE = re.compile(r"^```([\w-]*)\s*$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
BULLET = re.compile(r"^[-*]\s+(.*)$")
#  CommonMark limits ordered markers to nine digits.  A roadmap paragraph once
#  wrapped before 4294967295, which must remain a number in the paragraph,
#  not a list.
NUMBER = re.compile(r"^([0-9]{1,9})\.\s+(.*)$")
ROW = re.compile(r"^\|(.*)\|\s*$")
TABLE_RULE = re.compile(r"^\|[\s:|-]+\|\s*$")
QUOTE = re.compile(r"^>\s?(.*)$")
RULE_LINE = re.compile(r"^-{3,}\s*$")
CODE_SPAN = re.compile(r"`([^`]+)`")
BOLD = re.compile(r"\*\*([^*]+)\*\*")
#  Single-asterisk emphasis: an opening asterisk not after a word
#  character, text that neither starts nor ends with a space, and a
#  closing asterisk not before one -- so `32 TB*` and `a * b` stay as
#  written.
EMPHASIS = re.compile(r"(?<![\w*])\*(?=[^\s*])([^*]*?[^\s*])\*(?![\w*])")
#  What emphasis must not reach into: code, and the inside of a tag.
CODE_OR_TAG = re.compile(r"(<code>.*?</code>|<[^>]+>)", re.S)
MD_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


class GuideTargets:
    """Resolve source links from the document that contains them."""

    def __init__(self, docs, source):
        self.pages = {d["src"]: d["out"] for d in docs}
        self.pages["docs/library.md"] = "library.html"
        self.directory = posixpath.dirname(source)

    def resolve(self, href):
        parts = urlsplit(href)
        if parts.scheme or parts.netloc or not parts.path or href.startswith("/"):
            return href
        source = posixpath.normpath(posixpath.join(self.directory, unquote(parts.path)))
        if source == ".." or source.startswith("../"):
            return href
        target = self.pages.get(source)
        if target is None:
            target = REPO + "/blob/main/" + quote(source, safe="/")
        return urlunsplit(("", "", target, parts.query, parts.fragment))


def guide_targets(docs, source=""):
    return GuideTargets(docs, source)


def rewrite_link(match, targets):
    label, original = match.group(1), match.group(2)
    href = esc(targets.resolve(html.unescape(original)))
    # Retain the written target for content verification, whose word count
    # must not mistake a correctly rewritten source path for dropped prose.
    source = f' data-source-href="{original}"' if href != original else ""
    return f'<a href="{href}"{source}>{label}</a>'


def inline(text, links, targets):
    """Inline spans, in the one order that leaves the others alone."""
    out = esc(text)
    out = MD_LINK.sub(lambda m: rewrite_link(m, targets), out)
    out = BOLD.sub(r"<strong>\1</strong>", out)
    out = CODE_SPAN.sub(r"<code>\1</code>", out)
    #  README wrote *syntactic sugar* and the page showed the asterisks.
    out = "".join(part if CODE_OR_TAG.fullmatch(part)
                  else EMPHASIS.sub(r"<em>\1</em>", part)
                  for part in CODE_OR_TAG.split(out))
    return cite_links(out, links)


#  A cell boundary is an unescaped pipe.  `\|` is how a table writes a
#  literal one, which the operator table needs for the bitwise or: split
#  on it and the row grows a cell, the code span closes in the wrong
#  place, and every word is still on the page.
CELL = re.compile(r"(?<!\\)\|")


def cells(line):
    body = ROW.match(line).group(1)
    return [c.strip().replace("\\|", "|") for c in CELL.split(body)]


def guide_table(rows, links, targets):
    """A table whose source puts a row on a line and a tab between cells,
    which the browser ignores and a reader of the page as text needs: run
    together, "Concept", "What it gives" and "Part of world" read as one
    word."""
    head = cells(rows[0])
    #  A wide table stacks into records on a phone, each cell under its
    #  column's name, rather than running off the side: one of four or
    #  more columns, or one whose cells are mostly code, which cannot
    #  wrap.  Any other stays a table, in a scroller, because a two-column
    #  table read as records is twice as long and no easier to compare.
    body_cells = [cell for row in rows[2:] for cell in cells(row)]
    coded = sum(1 for cell in body_cells if "`" in cell)
    stack = len(head) >= 4 or (len(head) >= 3 and 2 * coded > len(body_cells))
    labels = [attr(html.unescape(TAG.sub(
        "", inline(cell, lambda ref: None, targets)))) for cell in head]
    out = ['<div class="scroller">',
           '<table class="stack">' if stack else "<table>", "<thead><tr>"]
    out.append("\t".join(f'<th scope="col">{inline(cell, links, targets)}</th>'
                          for cell in head))
    out.append("</tr></thead>\n<tbody>")
    for row in rows[2:]:
        got = cells(row)
        if len(got) != len(head):
            #  A row that does not match its header renders lopsided, and
            #  a table read as a row of pipes is what this reader exists
            #  to refuse.
            raise SystemExit(
                "render_html: a table row has %d cells and its header %d:\n  %s"
                % (len(got), len(head), row.strip()))
        out.append("\n<tr>")
        out.append("\t".join(
            (f'<td data-label="{label}">' if stack and label else "<td>")
            + f"{inline(cell, links, targets)}</td>"
            for label, cell in zip(labels, got)))
        out.append("</tr>")
    out.append("\n</tbody></table></div>")
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

        #  A rule divides; it does not say anything.  Rendered as prose it
        #  put a literal '---' on the page 40 times across six documents,
        #  and the sections it divides already carry a rule of their own.
        if RULE_LINE.match(line):
            index += 1
            continue

        if fence:
            language = fence.group(1)
            body = []
            opened = index + 1
            index += 1
            while index < len(lines) and not FENCE.match(lines[index]):
                body.append(lines[index])
                index += 1
            if index >= len(lines):
                #  It used to run to the end of the file and take every
                #  heading after it, silently.
                raise SystemExit(
                    "render_html: the fence opened at line %d is never closed"
                    % opened)
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
                if bullet and not ordered:
                    items.append([None, bullet.group(1)])
                elif number and ordered:
                    #  The marker is content too.  Prototype 4 separates
                    #  numbered implementation sketches with code blocks,
                    #  so each becomes a one-item list; throwing the marker
                    #  away made 1, 2, 3 render as 1, 1, 1 while the word
                    #  check saw no missing word.
                    items.append([int(number.group(1)), number.group(2)])
                elif bullet or number:
                    #  Changing marker kind starts another list.  Folding a
                    #  bullet into an ordered list (or vice versa) invents a
                    #  relationship the source did not write.
                    break
                elif lines[index].startswith("  ") and items:
                    #  An indented line continues the item it sits under.
                    #  An indented BULLET is a nested list, which this
                    #  reader does not build -- folding it into the parent
                    #  turned structure into a run-on sentence that no
                    #  word count could notice, so it is refused instead.
                    rest = lines[index].strip()
                    if BULLET.match(rest) or NUMBER.match(rest):
                        raise SystemExit(
                            "render_html: nested list at line %d is not "
                            "supported:\n  %s" % (index + 1, lines[index]))
                    items[-1][1] += " " + rest
                elif not lines[index].strip() and items:
                    #  A blank line between items is a loose list, not the
                    #  end of one: three lettered alternatives spaced apart
                    #  for reading became three one-item lists.
                    ahead = index + 1
                    while ahead < len(lines) and not lines[ahead].strip():
                        ahead += 1
                    same_kind = (NUMBER.match(lines[ahead]) if ordered
                                 else BULLET.match(lines[ahead])) \
                                if ahead < len(lines) else None
                    if same_kind:
                        index = ahead
                        continue
                    break
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
            #  A `>` line with nothing after it ends a paragraph, as it
            #  does in Markdown; the prototypes' banners have two.
            paragraphs, run = [], []
            for q in quoted + [""]:
                if q:
                    run.append(q)
                elif run:
                    paragraphs.append(" ".join(run))
                    run = []
            block("quote", paragraphs)
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


#  The tour's fine print: a paragraph that says only this, and the list
#  under it.  And the line it ends an entry with, naming the paragraphs of
#  the specification that settle it.
FINE_HEAD = re.compile(r"^(?:The fine print|Fine print):$")
EXACT = re.compile(r"^Exact rules: [^.]{0,80}\.?$")
#  A running example's own line naming its fixture, which check.py and
#  scripts/outside_user.py read in the Markdown; rendered, it captions the
#  listing it introduces.
FIXTURE_LINE = re.compile(r"^Fixture source: `([^`]+)`\.$")
#  What a program prints, introduced by a short paragraph of its own.
PRINTS_LINE = re.compile(r"^It prints\b([^.]{0,60})$")
#  A footnote: a paragraph opening with the asterisk its mark carries.
FOOTNOTE = re.compile(r"^\*[^*\s][^*]*$")
#  A code span in a sentence longer than this may break on a wide screen;
#  a shorter one stays whole.
LONG_CODE = 40
CODE_TAG = re.compile(r"<code>(.*?)</code>", re.S)


def mark_long(text):
    """Mark the code spans in a sentence too long to be kept whole."""
    return CODE_TAG.sub(
        lambda m: (f'<code class="long">{m.group(1)}</code>'
                   if len(html.unescape(TAG.sub("", m.group(1)))) > LONG_CODE
                   else m.group(0)), text)


def source_link(path, label):
    """A short name for a file, the full path its title and its link."""
    return (f'<a class="name" href="{REPO}/blob/main/{quote(path, safe="/")}" '
            f'title="{attr(path)}">{esc(label)}</a>')


def line_count(lines):
    return f"{len(lines)} line{'' if len(lines) == 1 else 's'}"


def terminal_label(text):
    """`It prints` as the footer's label: always "in a terminal", with
    anything the line says beyond that kept after it."""
    rest = PRINTS_LINE.match(text).group(1).strip(" ,:")
    return "in a terminal" + (f" · {esc(rest)}" if rest else "")
#  The name a fence's tag is captioned with, where a page asks for that.
FENCE_NAMES = {"c": "C", "landin": "Landin", "ldn": "Landin"}


def panel(caption, inner, classes="", foot="", source_text=""):
    """A listing in the front page's frame: a caption row, the code, and
    what follows it.  One design for every captioned listing."""
    cls = "panel" + (f" {classes}" if classes else "")
    said = f' data-source-text="{attr(source_text)}"' if source_text else ""
    return (f'<figure class="{cls}"><figcaption{said}>{caption}</figcaption>'
            f"{inner}{foot}</figure>")


def render_guide_blocks(blocks, links, targets, hl, captions=False,
                        wrap=False):
    out = []
    open_item = False
    inside = ""

    def code_html(payload):
        language, body = payload
        if language in ("ldn", "landin"):
            return listing_of(render_landin(body, hl, wrap), inside, wrap)
        #  A shell or text block is a listing too, and used to be built by
        #  hand here -- which is why it was the one kind of block with no
        #  copy button.
        return listing(esc("\n".join(body)), inside, wrap)

    def is_code(at, *languages):
        return (at < len(blocks) and blocks[at][0] == "code"
                and (not languages or blocks[at][1][0] in languages))

    def prints_at(at):
        """Whether `It prints` and its text block start at `at`."""
        return (at + 1 < len(blocks) and blocks[at][0] == "para"
                and PRINTS_LINE.match(blocks[at][1][0])
                and is_code(at + 1, "text", ""))

    def output(at):
        """The terminal's label, said as every panel says it, with the
        source's own words kept for the check that none went missing."""
        text = blocks[at][1][0]
        said = (f'<span class="said" data-source-text="{attr(text)}">'
                f"{terminal_label(text)}</span>")
        return said, listing(esc("\n".join(blocks[at + 1][1][1])), inside,
                             wrap)

    at = 0
    while at < len(blocks):
        kind, payload = blocks[at]
        at += 1
        if kind == "para":
            text = payload[0]
            fixture = FIXTURE_LINE.match(text)
            if fixture and is_code(at):
                #  The line stays in the Markdown, where the checks read
                #  it, and becomes the caption of the listing it names as
                #  every panel is captioned: the file's short name and its
                #  length, with the full path its title and its link.  The
                #  line itself is kept for the check that no word was lost.
                path = fixture.group(1)
                body_lines = blocks[at][1][1]
                caption = ('<span class="dot"></span>'
                           + source_link(path, posixpath.basename(path))
                           + '<span class="grow"></span>'
                           f"<span>{line_count(body_lines)}</span>")
                inner = code_html(blocks[at][1])
                at += 1
                foot = ""
                if prints_at(at):
                    said, shown = output(at)
                    foot = (f'<div class="foot prints">{said}</div>'
                            f'<div class="out">{shown}</div>')
                    at += 2
                out.append(panel(caption, inner, foot=foot,
                                 source_text=text))
                continue
            if PRINTS_LINE.match(text) and is_code(at, "text", ""):
                said, shown = output(at - 1)
                out.append(panel(said, shown, "output"))
                at += 1
                continue
            if FINE_HEAD.match(text) and at < len(blocks) \
                    and blocks[at][0] == "list":
                held = render_guide_blocks([blocks[at]], links, targets, hl)
                #  One label, as every label on the site is set, saying
                #  what the reader may do with it.
                out.append('<aside class="fine"><p class="fine-head label" '
                           f'data-source-text="{attr(text)}">fine print · '
                           'skip on a first read</p>'
                           f'{held}</aside>')
                at += 1
                continue
            if FOOTNOTE.match(text):
                out.append('<p class="fine-print" id="fine-print">'
                           f"{inline(text, links, targets)}</p>")
                continue
            if EXACT.match(text):
                out.append(f'<p class="exact">{inline(text, links, targets)}</p>')
                continue
            #  A finding opens a paragraph flush left -- "Z7  A pattern
            #  binding needs..." -- and 26 citations across the prototypes
            #  link to it.  Nothing emitted the anchor, so every one of
            #  those links went nowhere.
            found = FINDING.match(text)
            anchor = (f'<span class="anchor" id="{found.group(1)}"></span>'
                      if found else "")
            out.append(f"<p>{anchor}{mark_long(inline(text, links, targets))}</p>")
        elif kind == "sub":
            #  A construct heading is `[NNNN] title`, and its anchor is the
            #  id alone: 872 citations outside the documents link to
            #  `tour.html#0190`, and slugging the whole title would break
            #  every one of them.
            #
            #  The id sits on a wrapper rather than on the heading, and the
            #  prose and code that follow sit inside it, because a construct
            #  is the thing a citation quotes.  With the id on a bare <h3>
            #  the hover preview had no paragraph to read.
            found = re.match(r"^\[(\d{4})\]", payload)
            if found:
                if open_item:
                    out.append("</div>")
                cid = found.group(1)
                rest = payload[len(cid) + 2:].strip() or payload
                #  What the bar says while this entry is being read: the
                #  site cites entries, so the bar names one, not only the
                #  section around it.
                named = attr(f"{cid} · {plain_title(rest)}")
                out.append(f'<div class="item" id="{cid}" data-title="{named}">')
                open_item, inside = True, cid
                #  The number, as its own anchor.  The stylesheet reserves
                #  a gutter for it and lights it up when a citation
                #  arrives; without it the gutter was empty on every
                #  construct and arriving at one highlighted nothing.
                out.append(f'<a class="tag" href="#{cid}">{cid}</a>')
                out.append(f'<h3 class="sub">{inline(rest, links, targets)}</h3>')
            else:
                out.append(f'<h3 class="sub" id="{slug(payload)}">'
                           f"{inline(payload, links, targets)}</h3>")
        elif kind == "quote":
            if len(payload) == 1:
                out.append(f"<blockquote>{inline(payload[0], links, targets)}"
                           "</blockquote>")
            else:
                out.append("<blockquote>" + "".join(
                    f"<p>{inline(one, links, targets)}</p>" for one in payload)
                    + "</blockquote>")
        elif kind == "list":
            ordered, items = payload
            if ordered:
                first = items[0][0]
                start = f' start="{first}"' if first != 1 else ""
                expected = first
                rendered = []
                for marker, item in items:
                    #  A discontinuity is legal HTML and must remain
                    #  visible rather than being silently renumbered.
                    value = f' value="{marker}"' if marker != expected else ""
                    rendered.append(
                        f"<li{value}>{mark_long(inline(item, links, targets))}</li>")
                    expected = marker + 1
                body = "\n".join(rendered)
                out.append(f"<ol{start}>{body}</ol>")
            else:
                #  An item a line, so a list read as text is not one run.
                body = "\n".join(
                    f"<li>{mark_long(inline(item, links, targets))}</li>"
                    for _, item in items)
                out.append(f"<ul>{body}</ul>")
        elif kind == "table":
            out.append(guide_table(payload, links, targets))
        elif kind == "code":
            language = payload[0]
            name = FENCE_NAMES.get(language) if captions else None
            if name:
                #  C beside Landin: each says which it is, and the C is the
                #  quieter of the two.
                quiet = " lang-c" if language == "c" else ""
                out.append(panel(
                    f'<span class="dot"></span><span class="lang">{name}</span>',
                    code_html(payload), quiet.strip()))
            else:
                out.append(code_html(payload))
        else:
            raise SystemExit(f"render_html: unknown guide block {kind!r}")
    if open_item:
        out.append("</div>")
    return "\n".join(out)


#  A title the source shouts -- COMMENTS, THE GRAMMAR OF THE ENABLED
#  KERNEL -- is set in sentence case, as every other heading is written.
#  The names in it keep their capitals.
PROPER_WORDS = {"c": "C", "landin": "Landin"}


def sentence_case(title):
    if re.search(r"[a-z]", title) or not re.search(r"[A-Z]", title):
        return title
    words = re.split(r"(\W+)", title.lower())
    text = "".join(PROPER_WORDS.get(word, word) for word in words)
    text = re.sub(r"^(\W*)(\w)", lambda m: m.group(1) + m.group(2).upper(), text)
    return re.sub(r"(:\s+)(\w)", lambda m: m.group(1) + m.group(2).upper(), text)


def section_heading(title, links, targets):
    """A section's <h2>, in sentence case.  The words the source spells
    differently are kept in an attribute, so the check that every word
    reached the page still reads the source's own spelling, as it reads
    a rewritten link's original target."""
    shown = sentence_case(title)
    if shown == title:
        return f"<h2>{inline(title, links, targets)}</h2>"
    return (f'<h2 data-source-text="{attr(title)}">'
            f"{inline(shown, links, targets)}</h2>")


def plain_title(title):
    """A title as the bar and the sidebar say it: no backticks, no shout."""
    return sentence_case(title).replace("`", "")


def render_guide(text, links, targets, hl, captions=False, lead_paras=1,
                 wrap_opening=False):
    title, lead, sections = parse_guide(text)

    #  The hero carries the opening paragraph and nothing else -- or, for
    #  a document that asks, its first few, so that what it says before
    #  its first heading reads as its lead rather than as an orphaned
    #  section under an empty band.  Anything further above the first
    #  heading is ordinary body: a table in a hero is a table outside the
    #  styling that makes it readable, and a document with no headings at
    #  all is not a document with no content.
    count = 0
    while (count < min(lead_paras, len(lead)) and lead[count][0] == "para"
           and not FOOTNOTE.match(lead[count][1][0])):
        count += 1
    opening = lead[:count]
    remainder = lead[len(opening):]

    hero = render_guide_blocks(opening, links, targets, hl, captions)
    body = []
    nav_sections = []

    #  A document's opening programs, before its first numbered entry, are
    #  the first a reader meets, and on a phone they wrap whole rather
    #  than scroll; past that point code keeps its columns.
    wrapping = wrap_opening

    def constructs(blocks):
        return any(kind == "sub" and re.match(r"^\[\d{4}\]", payload)
                   for kind, payload in blocks)

    if remainder:
        wrapping = wrapping and not constructs(remainder)
        body.append('<section class="guide" id="top">\n'
                    + render_guide_blocks(remainder, links, targets, hl,
                                          captions, wrap=wrapping)
                    + "\n</section>")

    for sec in sections:
        sid = slug(sec["title"])
        wrapping = wrapping and not constructs(sec["blocks"])
        subs = sum(1 for kind, _ in sec["blocks"] if kind == "sub")
        #  The entries a section holds, where they are headings of their
        #  own rather than numbered constructs: the sidebar can list them.
        entries = [(slug(payload), payload) for kind, payload in sec["blocks"]
                   if kind == "sub" and not re.match(r"^\[\d{4}\]", payload)]
        nav_sections.append((sid, sec["title"], subs, entries))
        body.append(
            f'<section class="guide" id="{sid}" '
            f'data-title="{attr(plain_title(sec["title"]))}">\n'
            f'{section_heading(sec["title"], links, targets)}\n'
            + render_guide_blocks(sec["blocks"], links, targets, hl, captions,
                                  wrap=wrapping)
            + "\n</section>")

    #  The pitch's asterisk leads to the footnote it promises, where the
    #  document has one.
    joined = "\n".join(body)
    if 'id="fine-print"' in joined and FINE_PRINT_MARK in hero:
        hero = hero.replace(FINE_PRINT_MARK,
                            '32 TB<a class="asterisk" href="#fine-print" '
                            'aria-label="the fine print">*</a>', 1)

    return title, hero, joined, nav_sections


#  The sidebar's groups, in reading order.  A reader looking for the
#  language should not have to scan past fifteen implementation guides, so
#  the documents are grouped by who they are for, numbered so a group can
#  be named in conversation, and only the groups that matter to the page
#  being read start open.  The front page's shelf uses the same table, so
#  the two cannot disagree about where a document lives.
NAV_GROUPS = [
    ("the language", ["tour", "spec", "examples", "from-c", "library",
                      "documents"]),
    ("the project", ["readme", "roadmap", "handoff"]),
    ("the compiler", ["compiler", "ir", "diagnostics", "format", "server",
                      "targets", "core", "toolchain", "editors"]),
    ("tests and evidence", ["fixtures", "registers", "harness", "process",
                            "environments", "devices", "driver",
                            "cortex-m", "native-ci"]),
    ("design stress tests", ["p1", "p2", "p3", "p4"]),
]
RETIRED = {"native-ci"}


def nav_groups(docs):
    """The documents in NAV_GROUPS order, each exactly once.

    The library reference is not one of DOCS or GUIDES -- library.py
    writes it -- but it is a document a reader looks for among the
    language's, so it takes its place in the groups from LIBRARY_CARD.
    """
    by_key = {d["key"]: d for d in docs}
    by_key.setdefault("library", LIBRARY_CARD)
    listed = [k for _, keys in NAV_GROUPS for k in keys]
    if sorted(listed) != sorted(by_key):
        raise SystemExit("render_html: NAV_GROUPS and the documents differ: "
                         + ", ".join(sorted(set(listed) ^ set(by_key))))
    return [(f"{i:02d}", name, [by_key[k] for k in keys])
            for i, (name, keys) in enumerate(NAV_GROUPS, 1)]


def nav_html(docs, current, sections, reference_after=None):
    """The sidebar: every document in its group, and under the one being
    read, its sections -- with their own entries nested under them where
    the page lists those, and a divider after `reference_after`, the
    section where a document's teaching ends and its reference begins."""
    def toc():
        if not sections:
            return ""
        #  Module-like headings use "name  —  purpose".  The compact name
        #  is enough until it repeats: prototype 3 has four core/mem
        #  sections, and reducing all four to CORE/MEM made the navigation
        #  indistinguishable.  Keep unique compact labels and disambiguate
        #  only the collisions with the full heading.
        compact = [entry[1].split("  —  ")[0] for entry in sections]
        repeats = {label for label in compact if compact.count(label) > 1}
        nested = any(len(entry) > 3 and entry[3] for entry in sections)
        #  A long list of entries folds to the section being read; the
        #  script does the folding, so without one every entry shows.
        out = ['<div class="toc" data-fold>' if nested else '<div class="toc">']
        for entry in sections:
            sid, title = entry[0], entry[1]
            short = title.split("  —  ")[0]
            label = esc(plain_title(title if short in repeats else short))
            out.append(f'<a class="sect" href="#{sid}">{label}</a>')
            if nested and entry[3]:
                out.append(f'<div class="subs" data-of="{sid}">' + "".join(
                    f'<a class="sect sub" href="#{eid}">'
                    f"{esc(plain_title(named))}</a>"
                    for eid, named in entry[3]) + "</div>")
            if reference_after and title == reference_after:
                out.append('<span class="divide">reference · when you '
                           'need it</span>')
        out.append("</div>")
        return "".join(out)

    def link(out, label, retired=False):
        here = out == current
        cls = "doc" + (" here" if here else "") + (" retired" if retired else "")
        now = ' aria-current="page"' if here else ""
        return f'<a class="{cls}"{now} href="{out}">{esc(label)}</a>' + (
            toc() if here else "")

    out = [link("index.html", "the front page")]
    for num, name, members in nav_groups(docs):
        holds = any(d["out"] == current for d in members)
        #  The language is open everywhere; any other group only when the
        #  page being read is in it.
        opened = " open" if holds or num == "01" else ""
        out.append(f'<details{opened}><summary>{num} · {esc(name)}'
                   f'<span class="count">{len(members)}</span></summary>')
        for d in members:
            out.append(link(d["out"], d["nav"], d["key"] in RETIRED))
        out.append("</details>")
    return "\n".join(out)


def social(title, description, out):
    """What a crawler and a chat window are given.

    The description is the document's own blurb from DOCS or GUIDES, so
    the sentence a search result shows is the one the contents page shows
    and there is no third place to keep it up to date.
    """
    where = f"{SITE_URL}/" + ("" if out == "index.html" else out)
    tags = [f'<link rel="canonical" href="{where}">']
    if description:
        tags.append(f'<meta name="description" content="{attr(description)}">')
    tags += [
        '<meta property="og:type" content="website">',
        f'<meta property="og:site_name" content="Landin">',
        f'<meta property="og:title" content="{attr(title)}">',
        f'<meta property="og:url" content="{where}">',
        f'<meta property="og:image" content="{SITE_URL}/{OG_IMAGE}">',
        '<meta property="og:image:width" content="1200">',
        '<meta property="og:image:height" content="630">',
        '<meta property="og:image:alt" content="701, the Landin mark">',
        '<meta name="twitter:card" content="summary_large_image">',
    ]
    if description:
        tags.append(f'<meta property="og:description" content="{attr(description)}">')
    return "\n".join(tags)


def brief(text):
    """A preview's text: the paragraph whole, or its first PREVIEW
    characters cut at a word."""
    if len(text) <= PREVIEW:
        return text
    cut = text.rfind(" ", 0, PREVIEW)
    return text[:cut if cut > 0 else PREVIEW] + "\u2026"


def construct_says(source, docs):
    """What every construct and finding says, as a citation preview.

    A construct's is its opening paragraph, or its title when it opens
    with code; a finding's is its own paragraph.  Read out of the sources
    rather than out of a rendered page, so the order the pages are
    written in does not matter.
    """
    says = {}
    for entry in docs:
        targets = guide_targets(docs, entry["src"])
        _, lead, sections = parse_guide((source / entry["src"]).read_text())
        blocks = list(lead)
        for section in sections:
            blocks.extend(section["blocks"])
        open_id = None
        for kind, payload in blocks:
            if kind == "sub":
                found = re.match(r"^\[(\d{4})\]\s*(.*)$", payload)
                open_id = found.group(1) if found else None
                if open_id:
                    says[open_id] = html.unescape(TAG.sub(
                        "", inline(found.group(2), lambda ref: None, targets)))
                continue
            if kind != "para":
                continue
            text = html.unescape(TAG.sub(
                "", inline(payload[0], lambda ref: None, targets)))
            finding = FINDING.match(text)
            if finding:
                says[finding.group(1)] = brief(finding.group(2))
            elif open_id:
                says[open_id] = brief(text)
                open_id = None
    return says


def says_json(region, says):
    """The previews a page needs and cannot read off itself: those of the
    citations that lead to another page."""
    wanted = sorted({cid for href, cid in re.findall(
        r'<a\b[^>]*\bhref="([^"#]+)#[^"]*"[^>]*\bdata-cite="([^"]+)"', region)
        if cid in says})
    if not wanted:
        return ""
    data = json.dumps({cid: says[cid] for cid in wanted},
                      ensure_ascii=False, separators=(",", ":"))
    return ('<script type="application/json" id="says">'
            + data.replace("</", "<\\/") + "</script>")


#  A page can link its style and scripts rather than carry them.  Read as
#  text -- by a fetch tool, a screen reader's text mode or `curl | sed` --
#  an inline page opens with 28 KB of @font-face rules and two scripts, and
#  a library page then lists every module's name before the module.  A
#  linked page names its files in the head, loads the theme from a file
#  where the inline script stood, so the box is still set before the first
#  paint, and puts its content before its navigation; the grid puts the
#  navigation back in its column.
LINKED_CSS = """
.wrap > nav.side{grid-column:1; grid-row:1}
.wrap > main{grid-column:2; grid-row:1}
@media (max-width:60rem){ .wrap > main{grid-column:1} }
"""


def linked_assets(prefix, css="", js=""):
    """The files the pages linked under `prefix` load: {name: text}."""
    return {prefix + ".css": FONT_CSS + CSS + GUIDE_CSS + LINKED_CSS + css
                             + PRINT_CSS,
            prefix + "-theme.js": THEME_JS + "\n",
            prefix + ".js": js + JS}


#  The Latin upright of the prose face, asked for before the stylesheet is
#  read: a page whose text reflowed when it arrived moved a deep link's
#  target out from under the reader.
PRELOAD = "\n".join(
    f'<link rel="preload" href="{fonts.OUT_DIR}/{name}" as="font" '
    'type="font/woff2" crossorigin>' for name in fonts.preload("ui"))


def footer_note(docname):
    """What the footer says a page is a reading of.  It used to say "the
    text file is the specification" on every page, the README's and the
    IR guide's included."""
    src = f"<code>{esc(docname)}</code>"
    if docname == "spec.md":
        return (f"Generated from {src}, which is the specification; this "
                "page is a reading of it.")
    if docname == "tour.md":
        return (f"Generated from {src}, which explains the language; where "
                'the two differ, <a href="spec.html">the specification</a> '
                "decides.")
    if docname.startswith("prototype-"):
        return (f"Generated from {src}, a design stress test kept in step "
                "with the specification; this page is a reading of it.")
    if docname.endswith(".md"):
        return (f"Generated from {src}; the file is the source and this "
                "page is a reading of it.")
    return (f"Generated from {esc(docname)}; each page names the file it is "
            "a reading of.")


def page(title, kind, heading, hero, body, nav, docname, logo=False,
         out="index.html", description="", extra="", says=None,
         source_note=None, linked=None, banner=False):
    if linked:
        style = f'<link rel="stylesheet" href="{linked}.css">'
        theme = f'<script src="{linked}-theme.js"></script>'
        script = f'<script src="{linked}.js"></script>'
    else:
        style = f"<style>{FONT_CSS}{CSS}{GUIDE_CSS}{PRINT_CSS}</style>"
        theme = f"<script>{THEME_JS}</script>"
        script = f"<script>{JS}</script>"
    #  The drawer's foot carries discuss and source on a phone, where the
    #  bar has no room for them; wider, the bar does and this is hidden.
    side = f"""<nav class="side" id="side" aria-label="documents and sections">
{nav}
<div class="side-foot"><a href="{REPO}/discussions">{icons.use("messages-square")}<span>discuss</span></a><a href="{REPO}">{icons.use("git-branch")}<span>source</span></a></div>
</nav>
<label class="scrim" for="menu" aria-hidden="true"></label>
"""
    lead, trail = ("", side) if linked else (side, "")
    note = (footer_note(docname) if source_note is None else
            f"Generated from <code>{esc(docname)}</code> by "
            f"<code>render_html.py</code>. {esc(source_note)}")
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>{esc(title)}</title>
{social(title, description, out)}
{extra}
{ICON_LINKS}
{PRELOAD}
{style}
</head>
<body>
{icons.symbols()}
<a class="skip" href="#document">skip to the document</a>
<header class="bar">
  <a class="brand" href="index.html">{landin_icon.inline("mark")}<span>Landin</span></a>
  <span class="where" id="where">{esc(kind)}</span>
  <span class="grow"></span>
  <a class="src" href="{REPO}/discussions">{icons.use("messages-square")}<span>discuss</span></a>
  <a class="src" href="{REPO}">{icons.use("git-branch")}<span>source</span></a>
  <input class="menu-x" id="menu" type="checkbox" autocomplete="off"
         aria-label="documents and sections" aria-controls="side"
         aria-expanded="false">
  <label for="menu">{icons.use("menu")}<span>menu</span></label>
  <input class="theme-x" id="theme" type="checkbox">
  {theme}
  <label for="theme">{icons.use("moon", "i light-only")}{icons.use("sun", "i dark-only")}<span>theme</span></label>
</header>
<div class="wrap">
{lead}<main id="document"{' class="banner"' if banner else ''}>
<div class="hero{' wide' if logo else ''}{'' if hero.strip() else ' bare'}" id="{slug(heading)}">
  <h1>{esc(heading)}</h1>
  {hero}
</div>
{body}
</main>
{trail}<footer>
<a class="totop" href="#">↑ top</a>
{note}
The repository is at <a href="{REPO}">github.com/JanHaan/Landin</a>;
questions, bugs and ideas go to <a href="{REPO}/discussions">its discussions</a>.
<br>Copyright &#169; 2026 Jan Haan.
Licensed under <a href="{REPO}/blob/main/LICENSE-MIT">MIT</a> or
<a href="{REPO}/blob/main/LICENSE-APACHE">Apache-2.0</a>, at your option.
</footer>
</div>
<div id="pop"></div>
{says_json(hero + body, says or {})}
{script}
</body>
</html>
"""


#  The front page introduces the language rather than listing the files,
#  so it needs four things out of the sources: what the tour opens by
#  saying, what the README says the state of the work is, the roadmap items
#  surrounding active work, and a few constructs to show.  None of it is
#  written here -- a second copy is a copy that goes stale.

#  One whole program rather than three fragments: the fragments showed
#  syntax, and a program shows how the pieces are meant to be used together.
LANDING_PROGRAM = "compiler/tests/fixtures/runtime/example-sensors"
#  And before it, the README's first program, with the command that builds
#  it and what it prints, so a reader sees the whole loop before a showcase.
HELLO_PROGRAM = "compiler/tests/fixtures/runtime/first-program"

FENCE_OPEN = re.compile(r"^```landin\s*$")
ROADMAP_ITEM = re.compile(
    r"^### (R\d+\.\d+) — (.+)\n\n?"
    r"Status: (planned|active|blocked|complete)"
    r"(?:\nDepends on: ([^\n]+))?$", re.M)


def tour_intro(text):
    """The paragraphs the tour opens with, before its first construct."""
    body = []
    for line in text.split("\n"):
        if line.startswith("### ") or RULE_LINE.match(line):
            break
        if line.startswith("#"):
            continue
        body.append(line)
    paras, run = [], []
    for line in body:
        if line.strip():
            run.append(line.strip())
        elif run:
            paras.append(" ".join(run))
            run = []
    if run:
        paras.append(" ".join(run))
    return paras


def readme_status(text):
    """The README's own status line, so the front page cannot claim more."""
    m = re.search(r"\*\*(Status:.*?)\*\*", text, re.S)
    return " ".join(m.group(1).split()) if m else ""


README_LINK = re.compile(r"\[([^\]]+)\]\((#[^)\s]+)\)")


def readme_status_context(text):
    """The README's paragraph after its status line, which says it in full."""
    m = re.search(r"\*\*Status:.*?\*\*\n\n(.+?)\n\n", text, re.S)
    return " ".join(m.group(1).split()) if m else ""


def status_parts(text):
    """The version, plain-language headline and detail in README's status."""
    prefix = f"Status: {VERSION_LINE}."
    if not text.startswith(prefix):
        raise SystemExit("render_html: README.md's status does not begin with "
                         f"{prefix!r}")
    remainder = text[len(prefix):].strip()
    m = re.match(r"^(.+?\.)(?:\s+(.+))?$", remainder)
    if not m:
        raise SystemExit("render_html: README.md's status needs a complete "
                         f"plain-language headline after {prefix!r}")
    return VERSION_LINE, m.group(1), m.group(2) or ""


def roadmap_progress(text, recent_count=3):
    """The completed, active, next-planned or endpoint items around the work.

    The endpoint lane came last. A roadmap with nothing left to do still has
    a front page, and it says so; a roadmap with work it cannot start does not
    get to use the same lane, so the endpoint is recognised only when no item
    is planned, active or blocked.
    """
    items = [dict(key=m.group(1), title=m.group(2), status=m.group(3),
                  depends=m.group(4).split(", ") if m.group(4) else [])
             for m in ROADMAP_ITEM.finditer(text)]
    by_key = {item["key"]: item for item in items}
    try:
        items = [by_key[key] for key in execution_order(
            text, [item["key"] for item in items])]
    except ValueError as error:
        raise SystemExit("render_html: " + str(error)) from error

    def track(recent_at, **lanes):
        completed = [item for item in items[:recent_at]
                     if item["status"] == "complete"][-recent_count:]
        return dict({"recent": completed, "current": None,
                     "following": None, "endpoint": None}, **lanes)

    active = [i for i, item in enumerate(items) if item["status"] == "active"]
    if len(active) == 1:
        at = active[0]
        return track(at, current=items[at],
                     following=items[at + 1] if at + 1 < len(items) else None)

    ready = [i for i, item in enumerate(items)
             if item["status"] == "planned"
             and all(dependency == "none"
                     or any(other["key"] == dependency
                            and other["status"] == "complete"
                            for other in items)
                     for dependency in item["depends"])]
    live = [item for item in items
            if item["status"] in ("planned", "active", "blocked")]
    if items and not live:
        return track(len(items) - 1, endpoint=items[-1])
    if active or not ready:
        raise SystemExit("render_html: ROADMAP.md must have exactly one active "
                         "item or at least one dependency-ready planned item for the "
                         "front page")
    # Execution order selects the next item when a phase opens parallel work.
    return track(ready[0], following=items[ready[0]])


def landing_program(source, titles, construct_page):
    """The front page's program, and the constructs its fixture declares.

    Only the constructs the tour teaches are listed: the rest are the
    specification's rules about calls and entry shapes, which say how the
    program is checked rather than what a reader sees in it.
    """
    where = source / LANDING_PROGRAM
    meta = fixture_meta(where)
    lines = (where / meta["program"]).read_text().rstrip("\n").split("\n")
    return (f"{LANDING_PROGRAM}/{meta['program']}", lines,
            fixture_uses(meta, titles, construct_page))


def hello_program(source):
    """The first program: its path, its lines and what it prints."""
    where = source / HELLO_PROGRAM
    meta = fixture_meta(where)
    lines = (where / meta["program"]).read_text().rstrip("\n").split("\n")
    printed = (where / meta["run_expect"]).read_text().rstrip("\n")
    return f"{HELLO_PROGRAM}/{meta['program']}", lines, printed


def fixture_meta(where):
    return fixture_format.read(where)


def fixture_uses(meta, titles, construct_page):
    """The constructs a fixture says it exercises, as the tour names them."""
    uses = []
    for cid in re.split(r",\s*", meta.get("constructs", "")):
        if construct_page.get(cid) == "tour.html":
            uses.append((cid, titles[cid].split(": ")[0], "tour.html"))
    return uses


def uses_list(uses, here=""):
    return "".join(
        f'<li><a href="{"" if where == here else where}#{cid}" '
        f'data-cite="{cid}">'
        f'<span class="tag">{cid}</span>'
        #  A construct's title is Markdown: `any C` is code, not backticks.
        f'<span>{prose_html(label, lambda ref: None)}</span></a></li>'
        for cid, label, where in uses)


#  A running example names its fixture in one line of prose, and the
#  fixture says which constructs it exercises.  The strip goes at the end
#  of the example's section, under its listing.
FIXTURE_SOURCE = re.compile(
    r'<figcaption data-source-text="Fixture source: '
    r'`(compiler/tests/fixtures/runtime/[\w-]+)/main\.ldn`\.">')


def with_uses(body, source, titles, construct_page):
    parts = re.split(r"(?=<section )", body)
    for at, part in enumerate(parts):
        found = FIXTURE_SOURCE.search(part)
        if not found:
            continue
        uses = fixture_uses(fixture_meta(source / found.group(1)), titles,
                            construct_page)
        if not uses:
            continue
        strip = ('<aside class="uses strip" aria-label="Constructs this '
                 'program uses"><span class="label">what it uses</span>'
                 f'<ul class="used">{uses_list(uses)}</ul></aside>')
        end = part.rindex("</section>")
        parts[at] = part[:end] + strip + part[end:]
    return "".join(parts)


def write_resources(docs, extra_pages=()):
    """The files a crawler asks for, and the card a chat window shows.

    A sitemap is worth more here than on most sites: almost nothing links
    in yet, so there is little for a crawler to follow.  It is generated
    with the pages rather than kept beside them, because a hand-written
    list written by hand is a list that goes stale on the next document.
    """
    pages = ["index.html"] + [d["out"] for d in docs] + list(extra_pages)
    urls = "".join(
        "<url><loc>%s/%s</loc></url>"
        % (SITE_URL, "" if out == "index.html" else out)
        for out in pages)
    (SITE / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
        + urls + "</urlset>\n")

    (SITE / "robots.txt").write_text(
        "User-agent: *\nAllow: /\n"
        f"Sitemap: {SITE_URL}/sitemap.xml\n")

    (SITE / OG_IMAGE).write_bytes(landin_icon.card())

    #  Safari's pinned tab wants a file, and iOS wants a raster.
    (SITE / "icon-mono.svg").write_text(
        landin_icon.svg("mono", crop=True) + "\n")
    (SITE / "apple-touch-icon.png").write_bytes(
        landin_icon.card(180, 180, share=0.62))

    #  The faces.  Which of the thirty a reader fetches is the browser's
    #  decision, from the `unicode-range` of each: an English page asks
    #  for four of them, and a page that gained an arrow would ask for a
    #  fifth without the build being changed.  That is the reason the
    #  subsets are shipped whole rather than merged into one file.
    fonts_dir = SITE / fonts.OUT_DIR
    fonts_dir.mkdir(exist_ok=True)
    for name, source in fonts.files():
        (fonts_dir / name).write_bytes(source.read_bytes())

    return ["sitemap.xml", "robots.txt", OG_IMAGE,
            "icon-mono.svg", "apple-touch-icon.png",
            "%s/ (%d faces)" % (fonts.OUT_DIR, len(fonts.files()))]


def shelf_blurb(text):
    """A document's blurb on the shelf, its backticked words set as code."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", esc(text))


def shelf_count(constructs, findings, sections):
    """What a contents card says a document holds.

    Every DOCS card used to say "N constructs in M sections", so the four
    prototypes -- which carry findings and not constructs -- advertised
    themselves as "0 constructs in 4 sections", and a document with no
    headings at all as "0 sections".
    """
    if constructs:
        held = f"{constructs} construct{'' if constructs == 1 else 's'}"
    elif findings:
        held = f"{findings} finding{'' if findings == 1 else 's'}"
    else:
        held = ""
    where = (f"{sections} section{'' if sections == 1 else 's'}"
             if sections else "one page")
    return f"{held} in {where}" if held else where


#  Where a long guide sends its reader when it ends: the tour to programs
#  that run, the programs to the library they call, and a C programmer's
#  page to the tour that it keeps citing.
NEXT_DOCS = {"tour": "examples", "examples": "library", "from-c": "tour"}
LIBRARY_CARD = dict(key="library", out="library.html", nav="the library reference",
                    blurb="Every module's calls and signatures, with common "
                          "tasks as one complete program and each module's "
                          "own example.")


def next_card(key, docs):
    """The card at the end of a long guide naming the one to read next."""
    then = NEXT_DOCS.get(key)
    if not then:
        return ""
    found = (LIBRARY_CARD if then == "library"
             else next(d for d in docs if d["key"] == then))
    return (f'<nav class="next" aria-label="next document">'
            f'<a href="{found["out"]}"><span class="label">read next</span>'
            f'<strong>{esc(found["nav"])} →</strong>'
            f'<span>{shelf_blurb(found["blurb"])}</span></a></nav>')


def not_found_page(docs):
    """What GitHub Pages serves for a path that is not there.

    It is served at whatever path was asked for, so its relative links
    are resolved from the site's root rather than from that path.
    """
    hero = ("<p>The address may be mistyped, or the page "
            "may have moved when the documents were rearranged.</p>")
    links = [("tour.html", "the tour", "learn the language from the start"),
             ("examples.html", "running examples", "programs to copy and run"),
             ("library.html", "the library reference", "every module's calls"),
             ("index.html", "the front page", "everything else")]
    cards = "".join(
        f'<a class="route" href="{href}"><strong>{esc(name)}</strong>'
        f'<span class="text">{esc(what)}</span></a>'
        for href, name, what in links)
    body = ('<section class="landing" id="somewhere-else">'
            f'<h2>Somewhere else</h2><div class="routes">{cards}</div>'
            '</section>')
    return page("No page here — Landin", "not found", "No page here", hero,
                body, nav_html(docs, "404.html", []), "the repository",
                out="404.html", extra='<base href="/">'
                '\n<meta name="robots" content="noindex">')


def tab_title(title, nav):
    """What the tab, the bookmark and the search result say.

    The distinctive words go first, and the name is not said twice: the
    documents that carry it in their own title -- "Landin prototype 1" --
    would otherwise be listed as "Landin - Landin prototype 1".
    """
    t = (title or "").strip()
    if not t or t.lower() == "landin":
        return f"Landin — {nav}"
    if "landin" in t.lower():
        return t
    return f"{t} — Landin"


#  The pitch is the tour's own opening, which is plain prose, so the one
#  name a newcomer may not know is linked here rather than in the tour.
PITCH_LINKS = {
    "Peter Landin": "https://en.wikipedia.org/wiki/Peter_Landin",
}


#  The pitch's one asterisk, and the paragraph the tour opens with it.
#  The claim keeps its punchline and the qualification goes where an
#  asterisk always sends it: the bottom of the page.
FINE_PRINT_MARK = "32 TB*"


def fine_print(paras):
    """The tour's footnote to its pitch, so the asterisk lands somewhere."""
    return next((p for p in paras if p.startswith("*")), "")


def pitch_html(text):
    out = esc(text)
    for name, href in PITCH_LINKS.items():
        out = out.replace(esc(name), f'<a href="{esc(href)}">{esc(name)}</a>', 1)
    return out.replace(FINE_PRINT_MARK,
                       '32 TB<a class="asterisk" href="#fine-print" '
                       'aria-label="the fine print">*</a>', 1)


#  Where the front page sends a reader who wants the compiler: the README's
#  own section, which says where an archive unpacks and what `refine
#  version` prints.  The build refuses a README without it rather than
#  publishing a link to nothing.
INSTALL_ANCHOR = "installing"


def status_places(headline):
    """The places the README's headline names, for the hero's one line:
    every capitalised word after its first, which is the language's own
    name -- "Linux, macOS, FreeBSD, Cortex-M0"."""
    words = re.findall(r"[A-Za-z][\w-]*", headline)[1:]
    return [w for w in words if re.search(r"[A-Z]", w)]


def index_page(docs, counts, intro, status, progress, program, symbols,
               says, footnote, hello=None, context=""):
    """The front door: what the language is, what it looks like, where to go.

    In the order a newcomer asks: the pitch, then the smallest whole
    program, then which document to open, then a larger program, and only
    then how far the work has got.  The contents remain, at the bottom,
    because a reader who came back for one document should not have to
    read the introduction again.
    """
    body = []

    #  What it looks like: the first program, the command and what it
    #  prints, read from its fixture so what is shown is what compiles.
    first = ""
    if hello:
        hello_path, hello_lines, printed = hello
        hello_hl = Highlighter(*collect_symbols(hello_lines),
                               links=lambda ref: None)
        run = ("$ refine compile main.ldn -o hello &amp;&amp; ./hello\n"
               + esc(printed))
        first = (
            '<p class="lead">A whole program that prints one line, saved as '
            '<code>main.ldn</code>, compiled and run:</p>'
            '<div class="program">'
            '<figure class="panel">'
            '<figcaption><span class="dot"></span>'
            + source_link(hello_path, posixpath.basename(hello_path))
            + '<span class="grow"></span>'
            f'<span>{line_count(hello_lines)}</span></figcaption>'
            f'{listing(hello_hl.block(hello_lines), wrap=True)}'
            '<div class="foot"><span>in a terminal</span></div>'
            f'<div class="out">{listing(run, wrap=True)}</div>'
            '</figure></div>')
    body.append('<section class="landing" id="what-it-looks-like">'
                f'<h2>What it looks like</h2>{first}</section>')

    #  Six ways in, because the documents answer different questions and
    #  a reader who starts in the wrong one finds it slow going.  The four
    #  that teach come first; the two that decide and explain come after.
    #  Each is labelled by who it is for, not by its file name, which
    #  means nothing to a reader who has not opened it yet.
    routes = [
        ("tour.html", "the tour", "learn the language",
         "The tour teaches it in numbered constructs, from comments to "
         "runtime dispatch. Start at the top and read down."),
        ("examples.html", "examples", "run real programs",
         "Printing, reporting failures and the classic exercises, then "
         "everyday tools: counting lines, a directory listing, a shell, an "
         "echo server and a tree copy, each printing what it computes."),
        ("from-c.html", "from C", "come from C",
         "The Landin form of each C habit: strings, structs, pointers, "
         "errors and allocation, with examples the compiler accepts."),
        ("library.html", "library", "use the library",
         "Every module's calls and signatures, with common tasks as one "
         "complete program and each module's own example."),
        ("spec.html", "reference", "look up an exact rule",
         "The normative reference, not something to read through: follow "
         "a number from the tour or a compiler message to the one paragraph "
         "that settles it."),
        ("handoff.html", "design", "understand the design",
         "The design in one page, the principles behind it, and which "
         "decisions must not be quietly reversed."),
    ]
    cards = "".join(
        f'<a class="route" href="{href}"><span class="label">{esc(group)}'
        f'</span><strong>{esc(head)}</strong>'
        f'<span class="text">{esc(text)}</span></a>'
        for href, group, head, text in routes)
    body.append('<section class="landing" id="start-here">'
                f'<h2>Start here</h2><div class="routes">{cards}</div>'
                '</section>')

    #  A larger one: one whole program the gate runs, not a handful of
    #  lines chosen to fit, and beside it the constructs it leans on, each
    #  a link to where the language explains it.
    path, lines, uses = program
    hl = Highlighter(*collect_symbols(lines), links=lambda ref: None)
    used = uses_list(uses)
    body.append(
        '<section class="landing" id="a-larger-one">'
        '<h2>A larger one</h2>'
        '<p class="lead">Sensors of two kinds behind one '
        'concept, polled through runtime dispatch. The poll is generic over '
        'its allocator, which the caller lends as an arena over a stack '
        'buffer; each failure is declared in a signature and either skipped '
        'or passed on at the call. This is the whole file; it compiles and '
        'runs as shown.</p>'
        '<div class="program">'
        '<figure class="panel">'
        '<figcaption><span class="dot"></span>'
        + source_link(path, posixpath.basename(path))
        + f'<span class="grow"></span><span>{line_count(lines)}</span></figcaption>'
        f'{listing(hl.block(lines), wrap=True)}'
        '<div class="foot"><code>$ refine compile main.ldn -o sensors '
        '&amp;&amp; ./sensors</code><span class="grow"></span>'
        '<a href="examples.html">more programs →</a></div>'
        '</figure>'
        '<aside class="uses" aria-label="Constructs the program uses">'
        '<span class="label">what it uses</span>'
        f'<ul class="used">{used}</ul>'
        '<p>Both programs compile with today\'s refine. The '
        '<a href="tour.html">tour</a> explains each construct they use.'
        '</p></aside></div></section>')

    hero = "".join(f"<p>{pitch_html(t)}</p>" for t in intro)
    hero += ('<div class="hero-actions">'
             '<a class="primary" href="tour.html">read the tour</a>'
             #  Not the specification, whose first words tell a newcomer
             #  they probably do not want to read it; that is a link in
             #  the status line, for the reader who does.
             '<a href="examples.html">run the examples</a>'
             f'<a href="readme.html#{INSTALL_ANCHOR}">install refine</a></div>')
    if status:
        version, headline, detail = status_parts(status)
        #  One line in the hero; the status in full is a section of its
        #  own further down, after the language has had its say.
        places = status_places(headline)
        hero += ('<p class="status-line">'
                 '<a href="#status">status</a> · '
                 f'<a href="spec.html">{esc(version)}</a>'
                 + (" · " + esc(", ".join(places)) if places else "")
                 + ' · <a href="roadmap.html">roadmap →</a></p>')
        box = ('<aside class="status" aria-label="Project status">'
               '<div class="said">'
               f'<p class="status-meta label">status · {esc(version)}</p>'
               f'<h3>{prose_html(headline, lambda ref: None)}</h3>')
        if detail:
            box += f'<p>{prose_html(detail, lambda ref: None)}</p>'
        if context:
            box += ('<p class="status-context">'
                    + README_LINK.sub(
                        r'<a href="readme.html\2">\1</a>',
                        prose_html(context, lambda ref: None))
                    + '</p>')
        box += ('<p class="status-links">'
                f'<a href="readme.html#{INSTALL_ANCHOR}">install →</a></p>')
        box += '</div>'
        if progress:
            def progress_item(item):
                heading = f'{item["key"]} — {item["title"]}'
                #  The title alone: an item's number means nothing to a
                #  reader who has not opened the roadmap, and the link
                #  takes one who wants it there.
                return (f'<a class="roadmap-item" '
                        f'href="roadmap.html#{slug(heading)}">'
                        f'<span>{esc(item["title"])}</span></a>')

            recent = "".join(progress_item(item)
                             for item in progress["recent"])
            current = (progress_item(progress["current"])
                       if progress["current"] else "")
            following = (progress_item(progress["following"])
                         if progress["following"] else "")
            endpoint = (progress_item(progress["endpoint"])
                        if progress.get("endpoint") else "")
            current_lane = ('<div class="roadmap-now">'
                            '<span class="roadmap-label">in progress</span>'
                            f'{current}</div>') if current else ""
            if endpoint:
                last_label, last_item = "roadmap endpoint", endpoint
            else:
                last_label = "up next" if current else "next planned item"
                last_item = following
            #  A roadmap that has not finished an item yet has nothing to
            #  show here, and an empty lane under a label reads as a fault.
            recent_lane = ('<div><span class="roadmap-label">recently completed'
                           f'</span>{recent}</div>') if recent else ""
            box += ('<div class="roadmap-track">'
                    '<a class="roadmap-head" href="roadmap.html">'
                    'the roadmap: its items, by state</a>'
                    f'{recent_lane}'
                    f'{current_lane}'
                    '<div><span class="roadmap-label">'
                    f'{last_label}</span>'
                    f'{last_item}</div></div>')
        box += '</aside>'
        body.append('<section class="landing" id="status">'
                    f'<h2>Status and roadmap</h2>{box}</section>')

    #  The contents, in the sidebar's groups.
    rows = []
    for num, name, members in nav_groups(docs):
        rows.append(f'<div class="group"><h3>{num} · {esc(name)}</h3><div>')
        for d in members:
            n = counts.get(d["out"], "")
            retired = " retired" if d["key"] in RETIRED else ""
            rows.append(
                f'<a class="card{retired}" href="{d["out"]}">'
                f'<strong>{esc(d["nav"])}</strong>'
                f'<span>{shelf_blurb(d["blurb"])}</span><em>{esc(n)}</em></a>')
        rows.append("</div></div>")
    body.append('<section class="landing" id="every-document">'
                '<h2>Every document</h2>'
                f'<div class="shelf">{"".join(rows)}</div>'
                '</section>')
    body.append(f'<p class="fine-print" id="fine-print">'
                f'{esc(footnote)}</p>')

    nav = nav_html(docs, "index.html", [
        ("what-it-looks-like", "What it looks like", 0),
        ("start-here", "Start here", 0),
        ("a-larger-one", "A larger one", 0),
        ("status", "Status and roadmap", 0),
        ("every-document", "Every document", 0)])
    #  What a search result and a chat preview say about the front page.
    #  Two sentences, because that is what is shown before it is cut.
    #  Under 160 characters, because that is where a search result is cut.
    summary = ("A systems programming language and its compiler, built from "
               "scratch: one way of writing code from a 32 KB "
               "microcontroller to a hosted application. "
               + VERSION_LINE.capitalize() + ".")
    ld = {
        "@context": "https://schema.org",
        "@type": "SoftwareSourceCode",
        "name": "Landin",
        "description": summary,
        "url": SITE_URL + "/",
        "codeRepository": REPO,
        "programmingLanguage": {"@type": "ComputerLanguage", "name": "Ada"},
        "about": {"@type": "ComputerLanguage", "name": "Landin"},
        "image": f"{SITE_URL}/{OG_IMAGE}",
    }
    extra = ('<script type="application/ld+json">'
             + json.dumps(ld, ensure_ascii=False) + "</script>")
    return page("Landin — a systems language from 32 KB to 32 TB",
                "", "Landin", hero, chr(10).join(body), nav,
                "the repository", logo=True, out="index.html",
                description=summary, extra=extra, says=says)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

WORD = re.compile(r"[A-Za-z0-9_.]{3,}")
TAG = re.compile(r"<[^>]+>")
PRE = re.compile(r"(<pre\b.*?</pre>)", re.S)
SCRIPTY = re.compile(r"<(script|style)\b.*?</\1>", re.S)
ATTR = re.compile(r'\s(?:href|src)="([^"]*)"')


MAIN = re.compile(r"<main\b[^>]*>(.*)</main>", re.S)
ASIDE = re.compile(r"<(nav|header|footer)\b[^>]*>.*?</\1>", re.S)


class PageShape(HTMLParser):
    """The few generated-HTML relationships whose semantics must not drift."""

    def __init__(self):
        super().__init__()
        self.headings = []
        self.shelf = []
        self.sections = []
        self.section_links = []
        self.ordered_items = []
        self._section_link = None
        self._ordered_next = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if re.fullmatch(r"h[1-6]", tag):
            self.headings.append(tag)
        if tag == "section":
            self.sections.append(values.get("id") == "every-document")
        if (tag == "a" and any(self.sections)
                and "card" in values.get("class", "").split()):
            self.shelf.append(values.get("href", ""))
        if (tag == "a"
                and "sect" in values.get("class", "").split()):
            self._section_link = [values.get("href", ""), ""]
        if tag == "ol":
            self._ordered_next.append(int(values.get("start", "1")))
        if tag == "li" and self._ordered_next:
            marker = int(values.get("value", self._ordered_next[-1]))
            self.ordered_items.append(marker)
            self._ordered_next[-1] = marker + 1

    def handle_data(self, data):
        if self._section_link is not None:
            self._section_link[1] += data

    def handle_endtag(self, tag):
        if tag == "section" and self.sections:
            self.sections.pop()
        if tag == "a" and self._section_link is not None:
            href, label = self._section_link
            self.section_links.append((href, " ".join(label.split())))
            self._section_link = None
        if tag == "ol" and self._ordered_next:
            self._ordered_next.pop()


def page_shape(out):
    shape = PageShape()
    shape.feed(out.read_text())
    return shape


def ordered_markers(text):
    """The explicit numbers written on Markdown list items, outside fences."""
    _, lead, sections = parse_guide(text)
    blocks = list(lead)
    for section in sections:
        blocks.extend(section["blocks"])
    return [marker for kind, payload in blocks if kind == "list"
            for ordered, items in [payload] if ordered
            for marker, _ in items]


def verify_structure(out: Path, source: Path | None = None):
    """Check relationships that a word-presence comparison cannot see."""
    shape = page_shape(out)
    headings = shape.headings
    failures = []
    if headings.count("h1") != 1:
        failures.append(f"has {headings.count('h1')} h1 headings")
    if not headings or headings[0] != "h1":
        failures.append("does not begin its heading outline with h1")
    labels = [label for _, label in shape.section_links]
    duplicates = sorted({label for label in labels if labels.count(label) > 1})
    if duplicates:
        failures.append("has indistinguishable section links: "
                        + ", ".join(repr(label) for label in duplicates))
    if source is not None:
        expected = ordered_markers(source.read_text())
        if shape.ordered_items != expected:
            failures.append("renumbers ordered items: source %s, page %s"
                            % (expected, shape.ordered_items))
    if failures:
        print(f"  {out.name}: " + "; ".join(failures))
    return not failures


def body_region(page_html):
    """The part of a page that is the document, and not the furniture."""
    found = MAIN.search(page_html)
    return ASIDE.sub(" ", found.group(1) if found else page_html)


def page_words(raw):
    """A page region as the text a reader sees.

    Inside a listing a span sits between the halves of one name, so tags
    go without a space there and with one everywhere else.
    """
    return html.unescape("\n".join(
        TAG.sub("", part) if part.startswith("<pre") else TAG.sub(" ", part)
        for part in PRE.split(raw)))


def verify(src: Path, out: Path):
    """Nothing may be lost on the way to the page.

    Both sides are reduced to a multiset of words, which survives rewrapping
    prose and dropping the '--' that carried it. A word that comes out fewer
    times than it went in means a line went missing.
    """
    from collections import Counter

    #  A fence's info string names the language of the block; it is markup
    #  and not content, so it is not on the page and must not be counted as
    #  missing from it.  `landin` appears 145 times in the tour as a tag.
    text = re.sub(r"(?m)^```\S*$", "```", src.read_text())
    want = Counter(WORD.findall(text))
    #  A link's target lives in an attribute rather than in the text, and
    #  stripping tags takes it with them, so the targets are collected and
    #  counted alongside what a reader sees.
    #  Only the document's own region counts.  Reduced over the whole
    #  page, the sidebar's 15 document names, every section title in the
    #  navigation, the meta description and the og tags all counted as
    #  content -- so a heading that vanished from the body still balanced
    #  against the copy of it in the navigation, and this said "every word
    #  is on the page" while 79 citations had gone inert.
    raw = SCRIPTY.sub(" ", body_region(out.read_text()))
    # Count each source link's original target once, replacing its rendered
    # destination only in this verification copy. Do not count both paths.
    raw = re.sub(r'(<a href=")[^"]*" data-source-href="([^"]*)"',
                 r'\1\2"', raw)
    #  A heading set in sentence case, a caption or a label said in the
    #  site's own words is counted in the source's spelling, which it
    #  carries for exactly this.
    raw = re.sub(r'<(\w+)\b[^>]*? data-source-text="([^"]*)"[^>]*>.*?</\1>',
                 r"<\1>\2</\1>", raw, flags=re.S)
    targets = " ".join(ATTR.findall(raw))
    got = Counter(WORD.findall(page_words(raw) + " " + targets))
    lost = {w: (n, got.get(w, 0)) for w, n in want.items() if got.get(w, 0) < n}
    if lost:
        print(f"  {out.name}: {len(lost)} words come out short")
        for w, (a, b) in sorted(lost.items())[:20]:
            print(f"    {w!r}: {a} in the file, {b} on the page")
    else:
        print(f"  {out.name}: every word of {src.name} is on the page")
    return not lost


def verify_front(out: Path, pieces, docs):
    """The front page holds no document of its own, so it is checked
    against the pieces it was built from.

    It was the one page with no check at all: the pitch, the status line,
    the roadmap window and the program are lifted out of their source
    documents, and any reader could quietly return nothing -- a renamed
    status line, a moved rule, a construct that lost its fence -- leaving a
    blank section that no word count would notice.
    """
    from collections import Counter
    got = Counter(WORD.findall(page_words(body_region(out.read_text()))))
    short = []
    for what, text in pieces:
        for word, n in Counter(WORD.findall(text)).items():
            if got.get(word, 0) < n:
                short.append((what, word))
                break
    if short:
        print(f"  {out.name}: {len(short)} of its pieces are not on the page")
        for what, word in short:
            print(f"    {what}: {word!r} is missing")
    else:
        print(f"  {out.name}: all {len(pieces)} source pieces are on the page")

    want_shelf = Counter([d["out"] for d in docs] + [LIBRARY_CARD["out"]])
    got_shelf = Counter(page_shape(out).shelf)
    shelf_ok = got_shelf == want_shelf
    if not shelf_ok:
        missing = list((want_shelf - got_shelf).elements())
        extra = list((got_shelf - want_shelf).elements())
        print(f"  {out.name}: its document shelf does not match its pages")
        if missing:
            print("    missing: " + ", ".join(missing))
        if extra:
            print("    extra: " + ", ".join(extra))
    return not short and shelf_ok


USAGE = """render the documentation as HTML

    python3 render_html.py                      render every document
    python3 render_html.py --verify             and check nothing was lost
    python3 render_html.py --from DIR           read the documents from DIR
    python3 render_html.py --to DIR             isolate generated output in DIR
    python3 render_html.py tour.md spec.md      render only those

An unrecognised argument is refused rather than ignored: '--verfiy' used to
render all sixteen pages without checking one of them."""


def main(argv):
    global SITE
    #  main() is handed argv without the program name, so every element
    #  here is an argument the caller meant.
    expecting = False
    named = []
    for arg in argv:
        if expecting:                       # the directory after --from
            expecting = False
            continue
        if arg in ("--help", "-h"):
            print(USAGE)
            return 0
        if arg in ("--from", "--to"):
            expecting = True
            continue
        if arg == "--verify":
            continue
        why = ("no such option" if arg.startswith("-") else "not a document")
        if arg.startswith("-") or not arg.endswith(".md"):
            print(f"render_html: {why}: {arg}\n\n{USAGE}", file=sys.stderr)
            return 2
        named.append(Path(arg).name)

    check = "--verify" in argv

    source = HERE
    if "--from" in argv:
        at = argv.index("--from") + 1
        if at >= len(argv):
            print("render_html: --from wants a directory", file=sys.stderr)
            return 2
        source = Path(argv[at]).resolve()

    if "--to" in argv:
        at = argv.index("--to") + 1
        if at >= len(argv):
            print("render_html: --to wants a directory", file=sys.stderr)
            return 2
        SITE = Path(argv[at]).resolve()

    docs = [d for d in DOCS if not named or d["src"] in named
            or d["src"].split("/")[-1] in named]
    guides = [g for g in GUIDES if not named or g["src"] in named
              or g["src"].split("/")[-1] in named]
    if not docs and not guides:
        print("nothing to render; the documents are "
                + ", ".join(d["src"] for d in DOCS + GUIDES))
        return 1
    SITE.mkdir(exist_ok=True)
    counts = {}
    dangling = []

    #  Every document is Markdown, so all of them render through the one
    #  reader and the tour- and prototype-specific ones are gone.  A
    #  construct's page is where it is DEFINED, read off the headings
    #  rather than assumed: the kernel's rules moved to spec.md and 872
    #  citations outside the documents name the construct and not the file.
    construct_page, finding_page, construct_title = {}, {}, {}
    for entry in DOCS:
        held = (source / entry["src"]).read_text()
        for found, named in re.findall(r"^### \[(\d{4})\] (.*)$", held, re.M):
            construct_page[found] = entry["out"]
            construct_title[found] = named
        for found in re.findall(r"^([XYZW]\d+)\s", held, re.M):
            finding_page[found] = entry["out"]
    says = construct_says(source, DOCS)

    for d in docs:
        text = (source / d["src"]).read_text()
        symbols = collect_symbols(text.split("\n"))

        def links(ref, _here=d["out"]):
            where = construct_page.get(ref) or finding_page.get(ref)
            if where is None:
                #  A construct id is a multiple of ten, so [4096] in
                #  "[4096]f32 + [4096]f32" is an array size and not a
                #  citation that failed.  A finding reference has no such
                #  ambiguity and is always reported -- which is the class
                #  the old guard could never see.
                if not ref.isdigit() or ref.endswith("0"):
                    dangling.append(ref)
                return None
            return f"#{ref}" if where == _here else f"{where}#{ref}"

        title, hero, body, nav_sections = render_guide(
            text, links, guide_targets(DOCS + GUIDES, d["src"]),
            Highlighter(*symbols, links=links),
            lead_paras=d.get("lead_paras", 1),
            wrap_opening=d.get("wrap_opening", False))
        body += next_card(d["key"], DOCS + GUIDES)
        if not d.get("nest"):
            nav_sections = [entry[:3] for entry in nav_sections]
        nav = nav_html(DOCS + GUIDES, d["out"], nav_sections,
                       d.get("reference_after"))
        out = page(tab_title(title, d["nav"]), d["nav"],
                   title or d["nav"], hero, body, nav, d["src"],
                   out=d["out"], description=d["blurb"], says=says,
                   banner=d.get("banner", False))
        (SITE / d["out"]).write_text(out)
        counts[d["out"]] = shelf_count(
            sum(1 for c, w in construct_page.items() if w == d["out"]),
            sum(1 for f, w in finding_page.items() if w == d["out"]),
            len(nav_sections))
        print(f"{SITE.name}/{d['out']:<20} {len(out) // 1024:4d} KB  "
              f"{len(nav_sections)} sections")

    guide_symbols = collect_symbols(
        (source / DOCS[0]["src"]).read_text().split("\n"))

    for g in guides:
        text = (source / g["src"]).read_text()

        #  The same resolver the documents use.  This used to read a set
        #  built from DOCS[0] -- spec.md, not the tour -- through the
        #  pre-Markdown reader, so it was empty and every citation on
        #  every guide page rendered as text.  79 of them on the roadmap.
        def links(ref, _here=g["out"]):
            where = construct_page.get(ref) or finding_page.get(ref)
            if where is None:
                dangling.append(ref)
                return None
            return f"#{ref}" if where == _here else f"{where}#{ref}"

        title, hero, body, nav_sections = render_guide(
            text, links, guide_targets(DOCS + GUIDES, g["src"]),
            Highlighter(*guide_symbols, links=links),
            captions=g.get("captions", False))
        if g["key"] == "examples":
            body = with_uses(body, source, construct_title, construct_page)
        body += next_card(g["key"], DOCS + GUIDES)
        if not g.get("nest"):
            nav_sections = [entry[:3] for entry in nav_sections]
        nav = nav_html(DOCS + GUIDES, g["out"], nav_sections)
        out = page(tab_title(title, g["nav"]), g["nav"], title or g["nav"],
                   hero, body, nav, g["src"],
                   out=g["out"], description=g["blurb"], says=says)
        (SITE / g["out"]).write_text(out)
        counts[g["out"]] = shelf_count(0, 0, len(nav_sections))
        print(f"{SITE.name}/{g['out']:<20} {len(out) // 1024:4d} KB  "
              f"{len(nav_sections)} sections")

    front = []
    if len(docs) == len(DOCS) and len(guides) == len(GUIDES):
        tour_text = (source / "tour.md").read_text()
        intro = tour_intro(tour_text)[:2]
        footnote = fine_print(tour_intro(tour_text))
        missing = [name for name in PITCH_LINKS
                   if not any(name in para for para in intro)]
        if missing:
            raise SystemExit("render_html: the tour's opening no longer names "
                             + ", ".join(missing) + "; update PITCH_LINKS")
        readme_text = (source / "README.md").read_text()
        status = readme_status(readme_text)
        context = readme_status_context(readme_text)
        progress = roadmap_progress((source / "ROADMAP.md").read_text())
        program = landing_program(source, construct_title, construct_page)
        hello = hello_program(source)

        #  Each reader must have found something.  Failing loudly here is
        #  the contract this renderer keeps everywhere else: refuse what
        #  you cannot read rather than publishing a hole.
        if not intro:
            raise SystemExit("render_html: tour.md has no opening prose "
                             "for the front page")
        if (FINE_PRINT_MARK in " ".join(intro)) != bool(footnote):
            raise SystemExit("render_html: the tour's pitch and its fine "
                             "print must come together: an asterisk "
                             "with nothing under it, or the other way round")
        if not status:
            raise SystemExit("render_html: README.md has no **Status:** "
                             "line for the front page")
        if f'id="{INSTALL_ANCHOR}"' not in (SITE / "readme.html").read_text():
            raise SystemExit("render_html: README.md has no section the "
                             "front page's install link can reach, #"
                             + INSTALL_ANCHOR)
        if not program[2]:
            raise SystemExit("render_html: " + LANDING_PROGRAM
                             + " declares no construct the tour defines")

        (SITE / "index.html").write_text(
            index_page(DOCS + GUIDES, counts, intro, status, progress, program,
                       guide_symbols, says, footnote, hello, context))
        print(f"{SITE.name}/index.html")
        (SITE / "404.html").write_text(not_found_page(DOCS + GUIDES))
        print(f"{SITE.name}/404.html")
        library_pages = library.write(source, SITE, SimpleNamespace(
            DOCS=DOCS, GUIDES=GUIDES, WORD=WORD, page=page,
            render_guide=render_guide, guide_targets=guide_targets,
            inline=inline,
            Highlighter=Highlighter, listing_of=listing_of,
            render_landin=render_landin, linked_assets=linked_assets))
        print(f"{SITE.name}/library.html  {len(library_pages)} reference and source pages")
        for name in write_resources(DOCS + GUIDES, library_pages):
            print(f"{SITE.name}/{name}")
        for name in llms.write(SITE, source, DOCS + GUIDES, SITE_URL):
            print(f"{SITE.name}/{name}"
                  f"{(SITE / name).stat().st_size / 1024:>10.0f} KB")
        #  The status in the words the page shows: the version, then the
        #  headline and detail; the "Status:" prefix and the period after
        #  the version are the README's punctuation, which status_parts
        #  has already held it to.
        front = ([("the pitch", " ".join(intro)),
                  ("the status", " ".join(status_parts(status))),
                  ("the fine print", footnote)]
                 + [(f'roadmap {item["key"]}', item["title"])
                    for item in (progress["recent"]
                                 + [one for one in (progress["current"],
                                                    progress["following"],
                                                    progress.get("endpoint"))
                                    if one])]
                 + [("the first program", "\n".join(hello[1])),
                    ("what it prints", hello[2])]
                 + [("the program", "\n".join(program[1]))]
                 + [(f"uses [{cid}]", label) for cid, label, _ in program[2]])

    if check:
        print("checking that nothing was dropped:")
        ok = all([verify(source / d["src"], SITE / d["out"])
                  for d in docs + guides])
        structure = all([verify_structure(SITE / d["out"],
                                          source / d["src"])
                         for d in docs + guides])
        if front:
            structure = verify_structure(SITE / "index.html") and structure
            #  The not-found page reads no document, so there is no word
            #  of one to lose; its outline is still held to the others'.
            structure = verify_structure(SITE / "404.html") and structure
            ok = verify_front(SITE / "index.html", front,
                              DOCS + GUIDES) and ok
        ok = structure and ok
        if not ok:
            print("some content is missing from the pages")
            return 1
    if dangling:
        print(f"warning: {len(set(dangling))} citations point nowhere: "
              f"{', '.join(sorted(set(dangling)))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
