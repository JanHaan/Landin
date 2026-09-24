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
from urllib.parse import quote, unquote, urlsplit, urlunsplit

HERE = Path(__file__).resolve().parent
SITE = HERE / "site"

VERSION_LINE = "specification 0.2.1"
REPO = "https://github.com/JanHaan/Landin"
#  The canonical host.  The pages are served from GitHub Pages under
#  the CNAME the publishing workflow writes; every page still says
#  which of 701.dev and www.701.dev it wants to be found at, because a
#  reader who arrives at the other one should be told, not guessed at.
SITE_URL = "https://www.701.dev"
OG_IMAGE = "og.png"

DOCS = [
    dict(key="spec", src="spec.md", out="spec.html", kind="document",
         nav="the specification", group="the specification",
         blurb="The grammar of the enabled kernel, and the rules the tour "
               "left unsaid. Normative."),
    dict(key="tour", src="tour.md", out="tour.html", kind="document",
         nav="the tour", group="the specification",
         blurb="The language explained, construct by numbered construct. "
               "It teaches; the specification decides."),
    dict(key="p1", group="the prototypes", src="prototype-1-driver.md", out="prototype-1.html", kind="document",
         nav="prototype 1 — driver",
         blurb="A driver from an ugly vendor SVD: GPIO, an interrupt-driven "
               "DMA UART, a vector table, and not one hand-written bitmask."),
    dict(key="p2", group="the prototypes", src="prototype-2-parser.md", out="prototype-2.html", kind="document",
         nav="prototype 2 — parser",
         blurb="A parser that recovers, because a real one must not stop at "
               "the first mistake."),
    dict(key="p3", group="the prototypes", src="prototype-3-containers.md", out="prototype-3.html", kind="document",
         nav="prototype 3 — containers",
         blurb="A generic container library: growing array, small vector, "
               "hash map, arena-backed tree."),
    dict(key="p4", group="the prototypes", src="prototype-4-app.md", out="prototype-4.html", kind="document",
         nav="prototype 4 — application",
         blurb="A hosted application whose shape is decided by its command "
               "line, so it cannot be written without runtime dispatch."),
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

#  Nor are the two files an agent asks for.  They are a reading of the
#  grammar, the compiler's refusal tables and the catalogue rather than
#  anything about a page, so they live beside this and not inside it.

sys.path.insert(0, str(HERE))

import llms  # noqa: E402

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
    --accent:oklch(0.76 0.12 40); --accent-soft:oklch(0.6 0.1 40);
    --accent-bg:oklch(0.28 0.04 40);
    --code-bg:oklch(0.175 0.012 255);
    --k:oklch(0.8 0.09 350); --t:oklch(0.8 0.08 195); --f:oklch(0.8 0.08 255);
    --n:oklch(0.8 0.09 305); --q:oklch(0.8 0.09 135); --b:oklch(0.82 0.1 75);
    --cd:oklch(0.74 0.06 140);
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
  --ink-faint:oklch(0.53 0.015 250);
  --rule:oklch(0.88 0.012 85); --rule-soft:oklch(0.92 0.01 85);
  --accent:oklch(0.5 0.15 30); --accent-soft:oklch(0.66 0.1 30);
  --accent-bg:oklch(0.95 0.02 30);
  --code-bg:oklch(0.985 0.005 85); --code-rule:var(--rule);
  --k:oklch(0.48 0.1 350); --t:oklch(0.48 0.1 190); --f:oklch(0.48 0.1 260);
  --n:oklch(0.48 0.1 300); --q:oklch(0.48 0.1 130); --b:oklch(0.48 0.1 60);
  --cd:oklch(0.48 0.06 140);
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
@media (prefers-reduced-motion: reduce){
  html{scroll-behavior:auto}
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
a.skip:focus{top:.5rem}
html{-webkit-text-size-adjust:100%; scroll-behavior:smooth}
body{
  margin:0; background:var(--bg); color:var(--ink);
  font-family:var(--ui); font-size:16px; line-height:1.6;
  font-feature-settings:"kern" 1,"liga" 1;
}
/*  The code face's four features: calt, liga and dlig draw `->`, `<>`
    and `:=` as one shape each, and zero slashes the digit.  */
code,pre,.mono,.tag,.cite,.label{
  font-family:var(--mono);
  font-feature-settings:"kern" 1,"calt" 1,"liga" 1,"dlig" 1,"zero" 1;
}
code{
  font-size:.85em; padding:.05rem .28rem; color:var(--ink);
  background:var(--panel-2); border-radius:2px;
}
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
  background:color-mix(in oklch, var(--bg) 90%, transparent);
  backdrop-filter:saturate(1.3) blur(10px);
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
  text-decoration:none; border:1px solid var(--rule);
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
input.theme-x, input.menu-x{
  position:absolute; width:1px; height:1px; margin:-1px; padding:0;
  border:0; overflow:hidden; clip-path:inset(50%); white-space:nowrap;
}
input.theme-x:focus-visible + label, input.menu-x:focus-visible + label{
  outline:2px solid var(--accent); outline-offset:2px;
}
@media (max-width:35rem){
  :root{--bar:3.75rem}
  header.bar{gap:.45rem; padding:0 .65rem}
  header.bar .where{display:none}
  header.bar .src, header.bar label{
    width:2.75rem; height:2.75rem; justify-content:center; gap:0; padding:0;
  }
  header.bar .src span, header.bar label span{
    position:absolute; width:1px; height:1px; margin:-1px; padding:0;
    border:0; overflow:hidden; clip-path:inset(50%); white-space:nowrap;
  }
}
header.bar label[for="menu"]{display:none}

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
nav.side a{display:block; color:var(--ink-soft); text-decoration:none; line-height:1.35}
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
    so the list of them is set in one.  */
nav.side a.sect{
  padding:.2rem .75rem .2rem .8rem; margin-left:-1px;
  border-left:1px solid transparent;
  font-size:.72rem; letter-spacing:.035em; text-transform:uppercase;
  color:var(--ink-faint);
}
nav.side a.sect:hover{color:var(--ink)}
nav.side a.sect.here{color:var(--ink); border-left-color:var(--accent)}

main{padding:2.75rem 3rem 6rem; min-width:0; max-width:62rem}

/* ---- hero ---- */
.hero{border-bottom:1px solid var(--rule); padding-bottom:2rem; margin-bottom:.5rem}
.hero .logo{
  float:right; width:5.25rem; height:5.25rem; margin:0 0 1rem 1.5rem;
  border:1px solid var(--rule); border-radius:1.15rem;
}
.hero .logo rect{fill:var(--panel)}
.hero .logo path{fill:var(--accent)}
.hero.wide::after{content:""; display:block; clear:both}
/* On a phone the bar already carries the mark, and a float beside the
   opening line only breaks it into a ragged first few words.  */
@media (max-width:35rem){ .hero .logo{display:none} }
.hero h1{
  margin:.45rem 0 1rem; font-size:clamp(1.8rem, 1.3rem + 1.9vw, 2.6rem);
  line-height:1.08; letter-spacing:-.025em; font-weight:650; text-wrap:balance;
}
.hero p{margin:.6rem 0; max-width:42rem; color:var(--ink-soft)}
.hero p:first-of-type{color:var(--ink); font-size:1.1rem; line-height:1.55}
.hero pre{
  margin:.7rem 0; padding:.7rem .9rem; overflow-x:auto;
  background:var(--code-bg); border:1px solid var(--rule);
  font-size:.8rem; line-height:1.55; color:var(--ink-soft);
}
.hero blockquote{
  margin:.7rem 0; padding:.1rem 0 .1rem 1rem;
  border-left:2px solid var(--rule); color:var(--ink-soft); max-width:42rem;
}

/* ---- sections ---- */
section{padding-top:3rem; scroll-margin-top:var(--bar)}
section > h2{
  margin:0 0 1.2rem; font-size:.9rem; font-weight:750;
  letter-spacing:.08em; text-transform:uppercase; color:var(--ink);
  display:flex; align-items:center; gap:.8rem;
}
section > h2::after{content:""; flex:1; height:1px; background:var(--rule)}

/* ---- one construct ---- */
.item{position:relative; padding:0 0 1.6rem 0;
      scroll-margin-top:calc(var(--bar) + .6rem)}
.item .tag{
  display:inline-block; font-size:.75rem; color:var(--ink-faint);
  text-decoration:none; margin-bottom:.2rem;
}
.item .tag:hover{color:var(--accent)}
.item:target .tag, .item.lit .tag{color:var(--accent); font-weight:700}
/*  Arriving at a construct draws a brick rule down its left edge.  */
.item:target::before, .item.lit::before{
  content:""; position:absolute; left:-1.1rem; top:.3rem; bottom:1.4rem;
  width:2px; background:var(--accent);
}
.item p{margin:0 0 .75rem; max-width:42rem}
.item p:last-child{margin-bottom:0}
@media (min-width:70rem){
  .item{padding-left:4.2rem}
  .item .tag{position:absolute; left:0; top:.3rem; margin:0}
}

/* ---- code ---- */
.listing{position:relative; margin:.4rem 0 1.1rem}
.listing pre{
  margin:0; padding:.85rem 1rem; overflow-x:auto;
  background:var(--code-bg); border:1px solid var(--code-rule);
  font-size:.82rem; line-height:1.6; tab-size:4;
}
.listing .copy{
  position:absolute; top:.45rem; right:.45rem; opacity:0;
  display:inline-flex; align-items:center; justify-content:center;
  min-width:2rem; min-height:2rem; padding:0;
  font:inherit; font-size:.8rem; line-height:1;
  color:var(--ink-faint); background:var(--panel); cursor:pointer;
  border:1px solid var(--rule);
  transition:opacity .12s;
}
.listing .copy:hover{color:var(--accent); border-color:var(--accent-soft)}
.listing .copy .done{display:none}
.listing .copy.done .i{display:none}
.listing .copy.done .done{display:inline-block; color:var(--q)}
.listing:hover .copy, .listing .copy:focus{opacity:1}
@media (hover:none), (pointer:coarse){
  .listing .copy{opacity:1}
  .listing pre{padding-right:2.8rem}
}
pre.sample:not(.listing > pre){
  margin:.15rem 0 .85rem; padding:.55rem .85rem; overflow-x:auto;
  background:var(--code-bg); border:1px solid var(--rule);
  font-size:.8rem; line-height:1.55;
}
.k{color:var(--k)} .t{color:var(--t)} .f{color:var(--f)} .d{color:var(--d); font-weight:650}
.n{color:var(--n)} .q{color:var(--q)} .v{color:var(--b)} .b{color:var(--b); font-weight:600}
.s{color:var(--ink)} .o{color:var(--o)}
.c{color:var(--c); font-style:italic} .cd{color:var(--cd)}
pre a.cite, pre a.cite:hover{color:inherit; text-decoration-style:dotted}

/* ---- citations ---- */
a.cite{font-size:.9em; text-decoration:none; border-bottom:1px dotted var(--accent-soft)}
a.cite:hover{background:var(--accent-bg)}
#pop{
  position:absolute; z-index:60; max-width:29rem; display:none;
  padding:.65rem .8rem; font-size:.86rem; line-height:1.5;
  color:var(--ink); background:var(--panel); box-shadow:var(--sh);
  border:1px solid var(--rule);
}
#pop .tag{font-size:.72rem; color:var(--accent); display:block; margin-bottom:.2rem}

footer{
  grid-column:2; justify-self:start;
  margin:0 0 4rem; padding:1.25rem 3rem 0;
  border-top:1px solid var(--rule);
  color:var(--ink-faint); font-size:.78rem; line-height:1.7; max-width:56rem;
}
footer code{font-size:.9em; color:var(--ink-soft)}
.anchor{position:absolute; scroll-margin-top:calc(var(--bar) + .6rem)}

@media (max-width:60rem){
  .wrap{grid-template-columns:minmax(0,1fr)}
  footer{grid-column:1; padding-left:1.15rem; padding-right:1.15rem}
  nav.side{
    position:fixed; inset:var(--bar) 0 auto 0; height:auto; max-height:78vh;
    background:var(--bg); border-right:0; border-bottom:1px solid var(--rule);
    box-shadow:var(--sh); z-index:35; display:none;
  }
  /*  A checkbox rather than a button, so the drawer opens without a
      script; the script only closes it again after a link is followed.  */
  :root:has(#menu:checked) nav.side{display:block}
  header.bar label[for="menu"]{display:inline-flex}
  main{padding:1.75rem 1.15rem 5rem}
}
@media print{
  header.bar, nav.side, .listing .copy{display:none}
  .wrap{display:block}
  main{max-width:none; padding:0}
  .listing pre, pre.sample{white-space:pre-wrap}
  a{color:inherit}
}
"""
CSS = CSS.replace("{DARK}", DARK)

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
    "b.addEventListener('change',function(){"
    "try{if(b.checked)localStorage.setItem('landin-theme',d?'light':'dark');"
    "else localStorage.removeItem('landin-theme');}catch(e){}});})();")

#  How much of a paragraph a citation preview shows.  The longest
#  construct opens with four thousand characters, which is a page and not
#  a preview; the median is under three hundred and is shown whole.
PREVIEW = 400

JS = """
(function(){
  var PREVIEW=%d;
  var side=document.querySelector('nav.side');
  var menu=document.getElementById('menu');
  function closeMenu(focus){
    if(!menu || !menu.checked) return;
    menu.checked=false;
    if(focus) menu.focus();
  }
  if(side) side.addEventListener('click',function(e){
    if(e.target.closest('a')) closeMenu(false);
  });
  document.addEventListener('keydown',function(e){
    if(e.key==='Escape') closeMenu(true);
  });

  /* copy a listing */
  document.addEventListener('click',function(e){
    var b=e.target.closest('.copy'); if(!b) return;
    var pre=b.parentNode.querySelector('pre');
    navigator.clipboard.writeText(pre.innerText).then(function(){
      b.classList.add('done');
      setTimeout(function(){ b.classList.remove('done'); },1100);
    });
  });

  /* which section am I in */
  var where=document.getElementById('where');
  var links={}, sections=[].slice.call(document.querySelectorAll('main section'));
  document.querySelectorAll('nav.side a.sect').forEach(function(a){
    links[a.getAttribute('href').slice(1)]=a;
  });
  /* Which one is decided by where the sections are, not by which ones a
     margin happens to overlap.  An observer band starting above the
     landing point meant the tail of the previous section was still inside
     it, and the first intersecting section in document order won -- so
     clicking a section highlighted the one before it. */
  if(sections.length){
    var bar=document.querySelector('header.bar');
    /*  The bar says which document you are reading until a titled section
        takes over, so the top of the page keeps its label. */
    var kind=where?where.textContent:'';
    var last=0;
    function current(){
      /*  A section lands with its top at the bar's bottom edge, so
          the line that decides which one you are in has to be a
          hair below that and not above it.  */
      var line=(bar?bar.getBoundingClientRect().bottom:48)+8;
      var best=sections[0];
      sections.forEach(function(s){
        if(s.classList.contains('hide')) return;
        if(s.getBoundingClientRect().top<=line) best=s;
      });
      return best;
    }
    function mark(){
      var now=current();
      if(!now) return;
      if(where) where.textContent=now.dataset.title||kind;
      Object.keys(links).forEach(function(k){
        var on=(k===now.id);
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
  function hide(){ if(pop) pop.style.display='none'; }
  /* A citation of another page cannot read its paragraph out of this
     one, so the page carries what each of those says; before it did,
     only the specification's own citations of itself had a preview. */
  var says=null;
  function brief(text){
    if(text.length<=PREVIEW) return text;
    var cut=text.lastIndexOf(' ',PREVIEW);
    return text.slice(0,cut>0?cut:PREVIEW)+'\u2026';
  }
  function said(id){
    if(says===null){
      var s=document.getElementById('says');
      try{ says=s?JSON.parse(s.textContent):{}; }catch(e){ says={}; }
    }
    return says[id];
  }
  function show(a){
    if(!a||!pop) return;
    var href=a.getAttribute('href'), text;
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
    }
    pop.innerHTML='<span class="tag mono">['+a.dataset.cite+']</span>';
    pop.appendChild(document.createTextNode(text));
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
  document.addEventListener('mouseover',function(e){ show(e.target.closest(CITED)); });
  document.addEventListener('focusin',function(e){ show(e.target.closest(CITED)); });
  function drop(e){
    var a=e.target.closest(CITED);
    if(a){ a.removeAttribute('aria-describedby'); hide(); }
  }
  document.addEventListener('mouseout',drop);
  document.addEventListener('focusout',drop);
  document.addEventListener('keydown',function(e){ if(e.key==='Escape') hide(); });
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
""" % PREVIEW


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


def listing(code_html, label=""):
    return listing_of(f"<pre>{code_html}</pre>", label)


def listing_of(pre_html, label=""):
    """The frame around a listing whose <pre> is already built.

    A <pre> may not contain a <pre>, and render_sample returns one of its
    own; wrapping that in another produced markup no parser is obliged to
    read the same way.
    """
    #  138 buttons on the tour all read "copy" and nothing else, which is
    #  what a screen reader announces, one after another.  The construct
    #  the listing belongs to is the only thing that tells them apart.
    says = (f'copy the code for [{label}]' if label else "copy the code")
    return (f'<div class="listing">{pre_html}'
            f'<button class="copy" type="button" aria-label="{says}" '
            f'title="{says}">' + icons.use("copy") + icons.use("check", "i done")
            + "</button></div>")


def render_landin(lines, hl):
    """A block tagged `landin` is Landin, and every line of it is highlighted.

    Nothing is guessed here, because the fence already said what the block
    is.  render_sample below has to guess, because it reads an indented
    block from the .txt era that carried no tag; run over a tagged block it
    asks `known_only` of each line and leaves as plain text every line
    holding an ordinary name — which was most of them.  Fifty-eight blocks
    across the tour and the four prototypes rendered with no highlighting
    at all, and every word was on the page, so the gate saw nothing.
    """
    return ('<pre class="sample">'
            + "\n".join(hl.line(l) if l.strip() else "" for l in lines)
            + "</pre>")


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
         blurb="Eleven complete programs the compiler emits and the Linux "
               "gate runs, from a sensor poll and Euclid to three Benchmark "
               "Game correctness workloads."),
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
         blurb="Pinned QEMU CPU probes and a deterministic Renode peripheral lane, "
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
               "Vim, Emacs, Helix and the other major editor families."),
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
.guide h3.sub{font:600 15px/1.4 var(--ui);color:var(--ink);margin:26px 0 10px}
.guide p{margin:0 0 12px}
.guide ul,.guide ol{margin:0 0 14px;padding-left:22px}
.guide li{margin:0 0 6px}
.guide blockquote{margin:0 0 14px;padding:2px 0 2px 14px;
  border-left:2px solid var(--accent-soft);color:var(--ink-soft)}
/*  A table with a long path in a cell cannot fit a phone, and nothing
    scrolled: it simply overflowed the page.  */
.scroller{overflow-x:auto; margin:0 0 16px}
.guide table{width:100%;border-collapse:collapse;
  font:400 14px/1.5 var(--ui)}
.guide th{text-align:left;font-weight:600;color:var(--ink-soft);
  border-bottom:1px solid var(--rule);padding:7px 10px 7px 0;
  vertical-align:top}
.guide td{border-bottom:1px solid var(--rule-soft);padding:7px 10px 7px 0;
  vertical-align:top}
.guide tr:last-child td{border-bottom:0}
.guide td code,.guide th code{white-space:nowrap}

/* ---- the front page ---- */
.hero.wide h1{font-size:clamp(2rem, 1.4rem + 2.4vw, 3rem)}
.hero.wide p:first-of-type{font-size:1.15rem; text-wrap:pretty}
.hero-actions{display:flex; flex-wrap:wrap; gap:.6rem; margin:1.4rem 0 0}
.hero-actions a{
  display:inline-flex; align-items:center; min-height:2.5rem;
  padding:.45rem .95rem; border:1px solid var(--rule);
  font-size:.9rem; font-weight:600; text-decoration:none; color:var(--ink);
}
.hero-actions a.primary{color:var(--bg); background:var(--accent); border-color:var(--accent)}
.hero-actions a:hover{border-color:var(--accent)}
.hero-actions a.primary:hover{background:color-mix(in oklch, var(--accent) 88%, var(--ink))}

/*  The status: what the README says on the left, where the roadmap is on
    the right.  */
.hero .status{
  display:grid; grid-template-columns:2fr 1fr; margin-top:2.2rem;
  border:1px solid var(--rule); background:var(--panel);
  color:var(--ink-soft); font-size:.92rem;
}
.hero .status > .said{padding:1.1rem 1.25rem 1.25rem}
.hero .status .said p.status-meta{margin:0 0 .5rem; font-family:var(--mono);
  font-size:.72rem; line-height:1.4; color:var(--accent)}
.hero .status h2{margin:0 0 .6rem; color:var(--ink); font-size:1.05rem;
  line-height:1.4; font-weight:650; text-wrap:balance}
.hero .status .said p:not(.status-meta){margin:0; color:var(--ink-soft); font-size:.92rem; line-height:1.6}
.roadmap-track{border-left:1px solid var(--rule); background:var(--bg-soft);
  padding:.9rem 1.1rem 1rem}
.roadmap-track > div{margin-bottom:.8rem}
.roadmap-track > div:last-child{margin-bottom:0}
.roadmap-label{display:block; margin-bottom:.3rem; font-family:var(--mono);
  font-size:.7rem; color:var(--ink-faint)}
.roadmap-item{display:grid; grid-template-columns:3.2rem 1fr; gap:.5rem;
  padding:.15rem 0; color:var(--ink-soft); text-decoration:none;
  line-height:1.35; font-size:.82rem}
.roadmap-item strong{font-family:var(--mono); font-weight:500;
  font-size:.75rem; color:var(--ink-faint)}
.roadmap-item:hover span{color:var(--accent)}
.roadmap-now .roadmap-item strong{color:var(--accent)}
.roadmap-now .roadmap-item span{color:var(--ink); font-weight:600}

section.landing{padding-top:4rem}
section.landing > p.lead{max-width:42rem; color:var(--ink-soft); margin:-.2rem 0 1.4rem}

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
figure.panel figcaption .grow, figure.panel .foot .grow{flex:1}
figure.panel .foot{border-top:1px solid var(--rule)}
figure.panel .foot code{background:none; padding:0; font-size:1em; color:var(--ink-soft)}
figure.panel .foot a{white-space:nowrap}
figure.panel .listing{margin:0}
figure.panel .listing pre{border:0; padding:1rem 1.1rem; font-size:.8rem}
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

/*  Four ways in, as one block of four cells split by hairlines.  */
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
.shelf{border-top:1px solid var(--ink)}
.shelf .group{display:grid; grid-template-columns:10.5rem minmax(0,1fr);
  border-bottom:1px solid var(--rule)}
.shelf .group > h3{margin:0; padding:.8rem 1rem .8rem 0; font-family:var(--mono);
  font-weight:500; font-size:.75rem; color:var(--ink-faint)}
.card{display:grid; grid-template-columns:12rem minmax(0,1fr) auto; gap:1.25rem;
  padding:.72rem 0; text-decoration:none; color:inherit;
  border-bottom:1px solid var(--rule-soft); align-items:baseline}
.shelf .group .card:last-child{border-bottom:0}
.card strong{font-weight:600; font-size:.92rem; color:var(--ink)}
.card span{color:var(--ink-soft); font-size:.86rem; line-height:1.5}
.card em{font-style:normal; font-family:var(--mono); font-size:.7rem;
  color:var(--ink-faint); text-align:right; white-space:nowrap}
.card:hover strong{color:var(--accent)}
.card.retired strong{color:var(--ink-faint); font-weight:500}

@media (max-width:70rem){
  .uses{position:static}
  .card{grid-template-columns:minmax(0,1fr) auto}
  .card span{grid-column:1/-1; grid-row:2}
}
@media (max-width:48rem){
  .hero .status{grid-template-columns:1fr}
  .roadmap-track{border-left:0; border-top:1px solid var(--rule)}
  .routes{grid-template-columns:1fr}
  .shelf .group{grid-template-columns:1fr}
  .shelf .group > h3{padding-bottom:0}
  figure.panel .foot code{display:none}
}
@media (max-width:35rem){
  figure.panel .listing pre{font-size:.74rem}
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
MD_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


class GuideTargets:
    """Resolve source links from the document that contains them."""

    def __init__(self, docs, source):
        self.pages = {d["src"]: d["out"] for d in docs}
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
    head = cells(rows[0])
    out = ['<div class="scroller">', "<table>", "<thead><tr>"]
    for cell in head:
        out.append(f'<th scope="col">{inline(cell, links, targets)}</th>')
    out.append("</tr></thead><tbody>")
    for row in rows[2:]:
        got = cells(row)
        if len(got) != len(head):
            #  A row that does not match its header renders lopsided, and
            #  a table read as a row of pipes is what this reader exists
            #  to refuse.
            raise SystemExit(
                "render_html: a table row has %d cells and its header %d:\n  %s"
                % (len(got), len(head), row.strip()))
        out.append("<tr>")
        for cell in got:
            out.append(f"<td>{inline(cell, links, targets)}</td>")
        out.append("</tr>")
    out.append("</tbody></table></div>")
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
    open_item = False
    inside = ""
    for kind, payload in blocks:
        if kind == "para":
            #  A finding opens a paragraph flush left -- "Z7  A pattern
            #  binding needs..." -- and 26 citations across the prototypes
            #  link to it.  Nothing emitted the anchor, so every one of
            #  those links went nowhere.
            found = FINDING.match(payload[0])
            anchor = (f'<span class="anchor" id="{found.group(1)}"></span>'
                      if found else "")
            out.append(f"<p>{anchor}{inline(payload[0], links, targets)}</p>")
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
                out.append(f'<div class="item" id="{cid}">')
                open_item, inside = True, cid
                #  The number, as its own anchor.  The stylesheet reserves
                #  a gutter for it and lights it up when a citation
                #  arrives; without it the gutter was empty on every
                #  construct and arriving at one highlighted nothing.
                out.append(f'<a class="tag" href="#{cid}">{cid}</a>')
                rest = payload[len(cid) + 2:].strip() or payload
                out.append(f'<h3 class="sub">{inline(rest, links, targets)}</h3>')
            else:
                out.append(f'<h3 class="sub" id="{slug(payload)}">'
                           f"{inline(payload, links, targets)}</h3>")
        elif kind == "quote":
            out.append(f"<blockquote>{inline(payload[0], links, targets)}"
                       "</blockquote>")
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
                        f"<li{value}>{inline(item, links, targets)}</li>")
                    expected = marker + 1
                out.append(f"<ol{start}>{''.join(rendered)}</ol>")
            else:
                body = "".join(
                    f"<li>{inline(item, links, targets)}</li>"
                    for _, item in items)
                out.append(f"<ul>{body}</ul>")
        elif kind == "table":
            out.append(guide_table(payload, links, targets))
        elif kind == "code":
            language, body = payload
            if language in ("ldn", "landin"):
                out.append(listing_of(render_landin(body, hl), inside))
            else:
                #  A shell or text block is a listing too, and used to be
                #  built by hand here -- which is why it was the one kind
                #  of block with no copy button.
                out.append(listing(esc("\n".join(body)), inside))
        else:
            raise SystemExit(f"render_html: unknown guide block {kind!r}")
    if open_item:
        out.append("</div>")
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
            f'data-title="{attr(sec["title"])}">\n'
            f'<h2>{inline(sec["title"], links, targets)}</h2>\n'
            + render_guide_blocks(sec["blocks"], links, targets, hl)
            + "\n</section>")

    return title, hero, "\n".join(body), nav_sections


#  The sidebar's groups, in reading order.  A reader looking for the
#  language should not have to scan past fifteen implementation guides, so
#  the documents are grouped by who they are for, numbered so a group can
#  be named in conversation, and only the groups that matter to the page
#  being read start open.  The front page's shelf uses the same table, so
#  the two cannot disagree about where a document lives.
NAV_GROUPS = [
    ("the language", ["tour", "spec", "examples", "documents"]),
    ("the prototypes", ["p1", "p2", "p3", "p4"]),
    ("the project", ["readme", "roadmap", "handoff"]),
    ("the compiler", ["compiler", "ir", "targets", "core", "toolchain",
                      "editors"]),
    ("tests and evidence", ["fixtures", "registers", "harness", "process",
                            "environments", "devices", "driver",
                            "cortex-m", "native-ci"]),
]
RETIRED = {"native-ci"}


def nav_groups(docs):
    """The documents in NAV_GROUPS order, each exactly once."""
    by_key = {d["key"]: d for d in docs}
    listed = [k for _, keys in NAV_GROUPS for k in keys]
    if sorted(listed) != sorted(by_key):
        raise SystemExit("render_html: NAV_GROUPS and the documents differ: "
                         + ", ".join(sorted(set(listed) ^ set(by_key))))
    return [(f"{i:02d}", name, [by_key[k] for k in keys])
            for i, (name, keys) in enumerate(NAV_GROUPS, 1)]


def nav_html(docs, current, sections):
    def toc():
        if not sections:
            return ""
        #  Module-like headings use "name  —  purpose".  The compact name
        #  is enough until it repeats: prototype 3 has four core/mem
        #  sections, and reducing all four to CORE/MEM made the navigation
        #  indistinguishable.  Keep unique compact labels and disambiguate
        #  only the collisions with the full heading.
        compact = [title.split("  —  ")[0] for _, title, _ in sections]
        repeats = {label for label in compact if compact.count(label) > 1}
        out = ['<div class="toc">']
        for sid, title, _ in sections:
            short = title.split("  —  ")[0]
            label = esc(title if short in repeats else short)
            out.append(f'<a class="sect" href="#{sid}">{label}</a>')
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


def page(title, kind, heading, hero, body, nav, docname, logo=False,
         out="index.html", description="", extra="", says=None):
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
<style>{FONT_CSS}{CSS}{GUIDE_CSS}</style>
</head>
<body>
{icons.symbols()}
<a class="skip" href="#document">skip to the document</a>
<header class="bar">
  <a class="brand" href="index.html">{landin_icon.inline("mark")}<span>Landin</span></a>
  <span class="where" id="where">{esc(kind)}</span>
  <span class="grow"></span>
  <a class="src" href="{REPO}">{icons.use("git-branch")}<span>source</span></a>
  <input class="menu-x" id="menu" type="checkbox" autocomplete="off"
         aria-label="documents and sections" aria-controls="side">
  <label for="menu">{icons.use("menu")}<span>menu</span></label>
  <input class="theme-x" id="theme" type="checkbox">
  <script>{THEME_JS}</script>
  <label for="theme">{icons.use("moon", "i light-only")}{icons.use("sun", "i dark-only")}<span>theme</span></label>
</header>
<div class="wrap">
<nav class="side" id="side" aria-label="documents and sections">
{nav}
</nav>
<main id="document">
<div class="hero{' wide' if logo else ''}" id="{slug(heading)}">
  {landin_icon.inline("light", classes="logo") if logo else ''}
  <h1>{esc(heading)}</h1>
  {hero}
</div>
{body}
</main>
<footer>
Generated from <code>{esc(docname)}</code> by <code>render_html.py</code>.
The text file is the specification; this page is a reading of it.
The repository is at <a href="{REPO}">github.com/JanHaan/Landin</a>.
<br>Copyright &#169; 2026 Jan Haan.
Licensed under <a href="{REPO}/blob/main/LICENSE-MIT">MIT</a> or
<a href="{REPO}/blob/main/LICENSE-APACHE">Apache-2.0</a>, at your option.
</footer>
</div>
<div id="pop"></div>
{says_json(hero + body, says or {})}
<script>{JS}</script>
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
LANDING_PROGRAM = "compiler/tests/fixtures/runtime/sensors"

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
    # Roadmap order selects the next item when a phase opens parallel work.
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


def fixture_meta(where):
    return dict(line.split(": ", 1) for line in
                (where / "fixture.meta").read_text().splitlines()
                if ": " in line)


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
        f'<span class="tag">{cid}</span><span>{esc(label)}</span></a></li>'
        for cid, label, where in uses)


#  A running example names its fixture in one line of prose, and the
#  fixture says which constructs it exercises.  The strip goes at the end
#  of the example's section, under its listing.
FIXTURE_SOURCE = re.compile(
    r'Fixture source: <code>(compiler/tests/fixtures/runtime/[\w-]+)/'
    r'main\.ldn</code>')


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
                 f'<ul>{uses_list(uses)}</ul></aside>')
        end = part.rindex("</section>")
        parts[at] = part[:end] + strip + part[end:]
    return "".join(parts)


def write_resources(docs):
    """The files a crawler asks for, and the card a chat window shows.

    A sitemap is worth more here than on most sites: almost nothing links
    in yet, so there is little for a crawler to follow.  It is generated
    with the pages rather than kept beside them, because a hand-written
    list written by hand is a list that goes stale on the next document.
    """
    pages = ["index.html"] + [d["out"] for d in docs]
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


def shelf_count(constructs, findings, sections):
    """What a contents card says a document holds.

    Every DOCS card used to say "N constructs in M sections", so the four
    prototypes -- which carry findings and not constructs -- advertised
    themselves as "0 constructs in 4 sections", and a document with no
    headings at all as "0 sections".
    """
    if constructs:
        held = f"{constructs} constructs"
    elif findings:
        held = f"{findings} findings"
    else:
        held = ""
    where = f"{sections} sections" if sections else "one page"
    return f"{held} in {where}" if held else where


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


def pitch_html(text):
    out = esc(text)
    for name, href in PITCH_LINKS.items():
        out = out.replace(esc(name), f'<a href="{esc(href)}">{esc(name)}</a>', 1)
    return out


def index_page(docs, counts, intro, status, progress, program, symbols,
               says):
    """The front door: what the language is, what it looks like, where to go.

    The contents remain, at the bottom, because a reader who came back for
    one document should not have to read the introduction again.
    """
    body = []

    #  What it looks like: one whole program the gate runs, not a handful
    #  of lines chosen to fit.  It is read from its fixture, so what is
    #  shown is what compiles; beside it, the constructs it leans on, each
    #  a link to where the language explains it.
    path, lines, uses = program
    hl = Highlighter(*collect_symbols(lines), links=lambda ref: None)
    used = uses_list(uses)
    body.append(
        '<section class="landing" id="what-it-looks-like">'
        '<h2>what it looks like</h2>'
        '<p class="lead">Sensors of two kinds behind one concept, polled '
        'through runtime dispatch. The poll is generic over its allocator, '
        'which the caller lends as an arena over a stack buffer; each '
        'failure is declared in a signature and either skipped or passed '
        'on at the call. This is the whole file, as the Linux gate compiles '
        'and runs it.</p>'
        '<div class="program">'
        '<figure class="panel">'
        f'<figcaption><span class="dot"></span><span class="path">{esc(path)}</span>'
        f'<span class="grow"></span><span>{len(lines)} lines</span></figcaption>'
        f'{listing(hl.block(lines))}'
        '<div class="foot"><code>$ refine --emit=exe -o sensors … '
        '&amp;&amp; ./sensors; echo $?</code><span class="grow"></span>'
        '<a href="examples.html">more programs →</a></div>'
        '</figure>'
        '<aside class="uses" aria-label="Constructs the program uses">'
        '<span class="label">what it uses</span>'
        f'<ul>{used}</ul>'
        '<p>The source above is what refine accepts today. The '
        '<a href="tour.html">tour</a> teaches the whole designed language.'
        '</p></aside></div></section>')

    #  Four ways in, because the documents answer different questions and
    #  a reader who starts in the wrong one finds it slow going.
    routes = [
        ("tour.html", "learn the language",
         "The tour teaches it in numbered constructs, from comments to "
         "runtime dispatch. Start at the top and read down."),
        ("spec.html", "see what is decided",
         "The specification is normative: the grammar of the kernel the "
         "compiler accepts today, the rules the tour left unsaid, and why "
         "each decision went the way it did."),
        ("handoff.html", "understand the design",
         "The design in one page, the principles behind it, and which "
         "decisions must not be quietly reversed."),
        ("examples.html", "run real programs",
         "The sensors above, FizzBuzz, Euclid, searching, a prime sieve, "
         "run-length encoding and sorting, plus fannkuch-redux, Mandelbrot "
         "and FASTA: complete sources the Linux gate builds and executes."),
    ]
    cards = "".join(
        f'<a class="route" href="{href}"><span class="label">{"abcd"[i]} · '
        f'{href}</span><strong>{esc(head)}</strong>'
        f'<span class="text">{esc(text)}</span></a>'
        for i, (href, head, text) in enumerate(routes))
    body.append('<section class="landing" id="start-here">'
                f'<h2>start here</h2><div class="routes">{cards}</div>'
                '</section>')

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
                f'<span>{esc(d["blurb"])}</span><em>{esc(n)}</em></a>')
        rows.append("</div></div>")
    body.append('<section class="landing" id="every-document">'
                '<h2>every document</h2>'
                f'<div class="shelf">{"".join(rows)}</div>'
                '</section>')

    hero = "".join(f"<p>{pitch_html(t)}</p>" for t in intro)
    hero += ('<div class="hero-actions">'
             '<a class="primary" href="tour.html">read the tour</a>'
             '<a href="spec.html">browse the specification</a></div>')
    if status:
        version, headline, detail = status_parts(status)
        hero += ('<aside class="status" aria-label="Project status">'
                 '<div class="said">'
                 f'<p class="status-meta">Status · {esc(version)}.</p>'
                 f'<h2>{prose_html(headline, lambda ref: None)}</h2>')
        if detail:
            hero += f'<p>{prose_html(detail, lambda ref: None)}</p>'
        hero += '</div>'
        if progress:
            def progress_item(item):
                heading = f'{item["key"]} — {item["title"]}'
                return (f'<a class="roadmap-item" '
                        f'href="roadmap.html#{slug(heading)}">'
                        f'<strong>{esc(item["key"])}</strong>'
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
            hero += ('<div class="roadmap-track">'
                     f'{recent_lane}'
                     f'{current_lane}'
                     '<div><span class="roadmap-label">'
                     f'{last_label}</span>'
                     f'{last_item}</div></div>')
        hero += '</aside>'

    nav = nav_html(docs, "index.html", [
        ("what-it-looks-like", "what it looks like", 0),
        ("start-here", "start here", 0),
        ("every-document", "every document", 0)])
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

    want_shelf = Counter(d["out"] for d in docs)
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
            Highlighter(*symbols, links=links))
        nav = nav_html(DOCS + GUIDES, d["out"], nav_sections)
        out = page(tab_title(title, d["nav"]), d["nav"],
                   title or d["nav"], hero, body, nav, d["src"],
                   out=d["out"], description=d["blurb"], says=says)
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
            Highlighter(*guide_symbols, links=links))
        if g["key"] == "examples":
            body = with_uses(body, source, construct_title, construct_page)
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
        missing = [name for name in PITCH_LINKS
                   if not any(name in para for para in intro)]
        if missing:
            raise SystemExit("render_html: the tour's opening no longer names "
                             + ", ".join(missing) + "; update PITCH_LINKS")
        status = readme_status((source / "README.md").read_text())
        progress = roadmap_progress((source / "ROADMAP.md").read_text())
        program = landing_program(source, construct_title, construct_page)

        #  Each reader must have found something.  Failing loudly here is
        #  the contract this renderer keeps everywhere else: refuse what
        #  you cannot read rather than publishing a hole.
        if not intro:
            raise SystemExit("render_html: tour.md has no opening prose "
                             "for the front page")
        if not status:
            raise SystemExit("render_html: README.md has no **Status:** "
                             "line for the front page")
        if not program[2]:
            raise SystemExit("render_html: " + LANDING_PROGRAM
                             + " declares no construct the tour defines")

        (SITE / "index.html").write_text(
            index_page(DOCS + GUIDES, counts, intro, status, progress, program,
                       guide_symbols, says))
        print(f"{SITE.name}/index.html")
        for name in write_resources(DOCS + GUIDES):
            print(f"{SITE.name}/{name}")
        for name in llms.write(SITE, source, DOCS + GUIDES, SITE_URL):
            print(f"{SITE.name}/{name}"
                  f"{(SITE / name).stat().st_size / 1024:>10.0f} KB")
        front = ([("the pitch", " ".join(intro)), ("the status", status)]
                 + [(f'roadmap {item["key"]}', item["title"])
                    for item in (progress["recent"]
                                 + [one for one in (progress["current"],
                                                    progress["following"],
                                                    progress.get("endpoint"))
                                    if one])]
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
