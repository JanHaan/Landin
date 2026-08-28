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
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
SITE = HERE / "site"

VERSION_LINE = "specification 0.1.0"
LANDING_LINE = "built from scratch"
REPO = "https://git.sr.ht/~sinnfrei/landin"
#  The canonical host.  pages.sr.ht serves 701.dev as well and
#  cannot redirect between the two, so every page says which of
#  them it wants to be found at.
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

CSS = """
:root{
  color-scheme: light;
  --bg:#f7f6f2; --bg-soft:#efece5; --panel:#fffefb; --panel-2:#f2efe8;
  --ink:#1c2128; --ink-soft:#5a6270; --ink-faint:#6b7178;
  --rule:#dedad0; --rule-soft:#e9e5dc;
  --accent:#a03526; --accent-soft:#c4705f; --accent-bg:#f6ece9;
  --code-bg:#fbfaf6; --code-rule:#e4e0d5;
  --k:#9a2f6b; --t:#0f6f68; --f:#2c4c8c; --d:#243b6b; --n:#7a4bab;
  --q:#4a6a1f; --c:#72716a; --cd:#5f6f4a; --o:#6d7179; --b:#8a5a12;
  --sh:0 1px 2px rgba(20,20,20,.05), 0 6px 20px rgba(20,20,20,.04);
  /*  The two faces, named so a `font:` shorthand can reach them.  The
      interface one was used in three of those and defined in none, and a
      shorthand whose family does not resolve is thrown away whole: every
      construct heading and every table rendered at inherited body size.

      Both stacks come from assets/fonts.py, which is the only place that
      knows which faces are vendored -- so a page cannot ask for a family
      the site does not ship beside it, and neither can a rule below.  */
  /*  The sticky bar's height.  Four rules used to clear it with
      four different numbers, so landing on a section stopped half
      a rem higher than landing on a construct.  */
  --bar:3.1rem;
  --ui:{UI_STACK};
  --mono:{MONO_STACK};
}
/*  The switch is a checkbox, and it inverts: checked means the theme the
    system did not ask for.  CSS cannot read which theme that is, only
    match on it, so the dark variables are written under both halves of
    the question -- system dark and not inverted, system light and
    inverted.  Nothing here needs a script, which is the point: with
    scripting off the switch still works, it just does not outlive the
    page.  There is no script half at all: the choice is the box's,
    it is not stored anywhere, and it lasts as long as the page does.  */
@media (prefers-color-scheme: dark){
  :root:not(:has(#theme:checked)){
    color-scheme: dark;
    --bg:#12161c; --bg-soft:#171c24; --panel:#161b23; --panel-2:#1b212b;
    --ink:#dfe4ec; --ink-soft:#9aa3b1; --ink-faint:#7c8593;
    --rule:#2a313c; --rule-soft:#222933;
    --accent:#e2705c; --accent-soft:#b6543f; --accent-bg:#241a17;
    --code-bg:#0f1319; --code-rule:#232a34;
    --k:#f0919d; --t:#6fd3c2; --f:#93bcff; --d:#b9cdf5; --n:#cbaaf2;
    --q:#b3d178; --c:#7a828f; --cd:#a9bd93; --o:#8b93a1; --b:#e0ae6a;
    --sh:0 1px 2px rgba(0,0,0,.3), 0 8px 26px rgba(0,0,0,.28);
  }
}
@media (prefers-color-scheme: light), (prefers-color-scheme: no-preference){
  :root:has(#theme:checked){
    color-scheme: dark;
    --bg:#12161c; --bg-soft:#171c24; --panel:#161b23; --panel-2:#1b212b;
    --ink:#dfe4ec; --ink-soft:#9aa3b1; --ink-faint:#7c8593;
    --rule:#2a313c; --rule-soft:#222933;
    --accent:#e2705c; --accent-soft:#b6543f; --accent-bg:#241a17;
    --code-bg:#0f1319; --code-rule:#232a34;
    --k:#f0919d; --t:#6fd3c2; --f:#93bcff; --d:#b9cdf5; --n:#cbaaf2;
    --q:#b3d178; --c:#7a828f; --cd:#a9bd93; --o:#8b93a1; --b:#e0ae6a;
    --sh:0 1px 2px rgba(0,0,0,.3), 0 8px 26px rgba(0,0,0,.28);
  }
}

*{box-sizing:border-box}
/*  Every citation click and every '/' jump animated, with nothing asking
    whether the reader wanted motion.  */
@media (prefers-reduced-motion: reduce){
  html{scroll-behavior:auto}
  *{transition-duration:.01ms !important; animation-duration:.01ms !important}
}
a:focus-visible, button:focus-visible, input:focus-visible, summary:focus-visible{
  outline:2px solid var(--accent-soft); outline-offset:2px; border-radius:3px;
}
/*  The keyboard route past a sidebar that is ~200 links deep on the tour. */
a.skip{
  position:absolute; left:.5rem; top:-3rem; z-index:60;
  padding:.45rem .7rem; background:var(--panel); color:var(--ink);
  border:1px solid var(--accent-soft); border-radius:5px; font-size:.85rem;
}
a.skip:focus{top:.5rem}
/*  The offset lives on the targets, as scroll-margin-top.  Setting
    scroll-padding-top here as well made the two add up, so a section
    landed 130px down the page instead of just under the bar.  */
html{-webkit-text-size-adjust:100%; scroll-behavior:smooth}
body{
  margin:0; background:var(--bg); color:var(--ink);
  font-family:var(--ui);
  font-size:16.5px; line-height:1.62;
  font-feature-settings:"kern" 1,"liga" 1;
}
/*  The code face was customised with four features and no others:
    calt, liga and dlig draw `->`, `<>` and `:=` as one shape each,
    and zero slashes the digit so `0` and `O` cannot be read for each
    other in a fixture.  Named here because the body's own settings
    would otherwise decide for the code, and the body is set in a
    different family with different features.  */
code,pre,.mono,.tag,.cite{
  font-family:var(--mono);
  font-feature-settings:"kern" 1,"calt" 1,"liga" 1,"dlig" 1,"zero" 1;
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
  display:inline-flex; align-items:center; gap:.5rem;
}
/*  The mark is assets/icon.svg inlined, taking the colour of the word
    beside it, which is how it follows the theme without a second drawing
    and without a request.  */
header.bar .brand svg{height:.82rem; width:auto; fill:currentColor; display:block}
header.bar .where{
  font-size:.74rem; color:var(--ink-faint); letter-spacing:.06em;
  text-transform:uppercase; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
}
header.bar .grow{flex:1}
/*  Everything in the bar is the same control: the source link sat beside
    the theme button at a different size, in a different case and with
    different padding, because it was added with a rule of its own.  */
/*  An icon is 1em of the label beside it, so the two scale together and
    the control keeps the bar's rhythm.  */
svg.i{width:1em; height:1em; flex:none; vertical-align:-.12em}
header.bar button, header.bar .src, header.bar label[for="theme"]{
  display:inline-flex; align-items:center; gap:.4rem;
  font:inherit; font-size:.72rem; letter-spacing:.08em; text-transform:uppercase;
  color:var(--ink-soft); background:var(--panel); cursor:pointer;
  text-decoration:none; border:1px solid var(--rule); border-radius:5px;
  padding:.3rem .55rem; white-space:nowrap;
}
header.bar button:hover, header.bar .src:hover, header.bar label[for="theme"]:hover{
  color:var(--ink); border-color:var(--ink-faint);
}
/*  The toggle offers the theme you are not in: a moon on a light page,
    a sun on a dark one.  Both are in the markup and CSS picks, so no
    script is needed to draw the right one.  */
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
/*  The box itself is never seen, but it is what is focused and what is
    typed at, so it is clipped rather than `display:none` -- which would
    take it out of the tab order and leave the label unreachable by
    keyboard.  The ring is drawn on the label instead.  */
input.theme-x{
  position:absolute; width:1px; height:1px; margin:-1px; padding:0;
  border:0; overflow:hidden; clip-path:inset(50%); white-space:nowrap;
}
input.theme-x:focus-visible + label{outline:2px solid var(--accent); outline-offset:2px}
/*  A phone has room for the actions, but not for three copies of what their
    icons already say.  Keep every action and its accessible name, collapse
    only the visible labels, and give the resulting icon controls a useful
    touch target.  The changing document/section label is expendable here;
    the page heading says the same thing below the bar.  */
@media (max-width:35rem){
  :root{--bar:3.75rem}
  header.bar{gap:.45rem; padding:.45rem .65rem}
  header.bar .where{display:none}
  header.bar .src, header.bar button, header.bar label[for="theme"]{
    width:2.75rem; height:2.75rem; justify-content:center; gap:0; padding:0;
  }
  header.bar .src span, header.bar button span,
  header.bar label[for="theme"] span{
    position:absolute; width:1px; height:1px; margin:-1px; padding:0;
    border:0; overflow:hidden; clip-path:inset(50%); white-space:nowrap;
  }
}
#menu{display:none}

/* ---- layout ---- */
.wrap{display:grid; grid-template-columns:17rem minmax(0,1fr); gap:0; align-items:start}
nav.side{
  position:sticky; top:var(--bar); align-self:start;
  height:calc(100vh - var(--bar)); overflow:auto;
  padding:1.4rem 1rem 3rem 1.4rem; border-right:1px solid var(--rule);
}
nav.side .nav-group{
  margin:1.4rem 0 .45rem; font-size:.66rem; letter-spacing:.14em;
  text-transform:uppercase; color:var(--ink-faint); font-weight:600;
}
nav.side .nav-group:first-child{margin-top:0}
nav.side a{
  display:block; padding:.22rem .45rem; margin-left:-.45rem;
  color:var(--ink-soft); text-decoration:none; font-size:.86rem;
  border-radius:4px; line-height:1.35;
}
nav.side a:hover{background:var(--panel-2); color:var(--ink)}
nav.side a.here{color:var(--accent); background:var(--accent-bg); font-weight:600}
nav.side a.doc{font-size:.88rem}
/*  The icon sits in the field rather than beside it, so the field is
    still the full width of the column.  */
.finder{position:relative; display:flex; align-items:center}
.finder .i{position:absolute; left:.55rem; color:var(--ink-faint);
  pointer-events:none}
#find{
  width:100%; font:inherit; font-size:.85rem;
  padding:.4rem .55rem .4rem 1.9rem;
  color:var(--ink); background:var(--panel); border:1px solid var(--rule); border-radius:5px;
}
#find:focus{outline:2px solid var(--accent-soft); outline-offset:1px}
#find:focus + .i, .finder:focus-within .i{color:var(--accent)}
#found{font-size:.72rem; color:var(--ink-faint); padding:.35rem .1rem 0}

main{padding:2.2rem 2.4rem 6rem; min-width:0; max-width:64rem}

/* ---- hero ---- */
.hero{border-bottom:1px solid var(--rule); padding-bottom:1.6rem; margin-bottom:.6rem}
/*  The front door wears the plated icon.  It is the same drawing the tab
    carries, at the one size where the plate is worth having.  */
.hero .logo{
  float:right; width:5.5rem; height:5.5rem; margin:0 0 1rem 1.4rem;
  border:1px solid var(--rule); border-radius:1.2rem;
}
/*  Inline, so the stylesheet can reach into it: the drawing carries the
    light colours as attributes for anything that renders it alone, and
    here the page's own two variables win and it follows the theme.  */
.hero .logo rect{fill:var(--panel)}
.hero .logo path{fill:var(--accent)}
.hero.wide::after{content:""; display:block; clear:both}
@media (max-width:35rem){ .hero .logo{width:3.6rem; height:3.6rem; border-radius:.8rem} }
.hero .kind{font-size:.7rem; letter-spacing:.16em; text-transform:uppercase; color:var(--accent)}
.hero h1{
  margin:.5rem 0 .9rem; font-size:clamp(1.5rem, 1.1rem + 1.6vw, 2.1rem);
  line-height:1.15; letter-spacing:-.015em; font-weight:700;
}
.hero p{margin:.55rem 0; max-width:44rem; color:var(--ink-soft)}
.hero p:first-of-type{color:var(--ink); font-size:1.06rem}
.hero pre{
  margin:.7rem 0; padding:.7rem .85rem; overflow-x:auto;
  background:var(--panel-2); border-left:2px solid var(--rule);
  font-size:.82rem; line-height:1.5; color:var(--ink-soft);
}
.hero blockquote{
  margin:.7rem 0; padding:.1rem 0 .1rem .95rem;
  border-left:2px solid var(--rule); color:var(--ink-soft); max-width:44rem;
}

/* ---- sections ---- */
section{padding-top:2.4rem; scroll-margin-top:var(--bar)}
section > h2{
  margin:0 0 1.1rem; font-size:.82rem; font-weight:700;
  letter-spacing:.13em; text-transform:uppercase; color:var(--ink);
  display:flex; align-items:center; gap:.7rem;
}
section > h2::after{content:""; flex:1; height:1px; background:var(--rule)}

/* ---- one construct ---- */
.item{position:relative; padding:0 0 1.5rem 0;
      scroll-margin-top:calc(var(--bar) + .6rem)}
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
.listing .copy{
  position:absolute; top:.4rem; right:.4rem; opacity:0;
  display:inline-flex; align-items:center; justify-content:center;
  min-width:2rem; min-height:2rem; padding:0;
  font:inherit; font-size:.8rem; line-height:1;
  color:var(--ink-faint); background:var(--panel); cursor:pointer;
  border:1px solid var(--rule); border-radius:4px;
  transition:opacity .12s;
}
.listing .copy:hover{color:var(--ink); border-color:var(--ink-faint)}
/*  Having copied, the tick replaces the sheets for a moment. */
.listing .copy .done{display:none}
.listing .copy.done .i{display:none}
.listing .copy.done .done{display:inline-block; color:var(--q)}
.listing:hover .copy, .listing .copy:focus{opacity:1}
@media (hover:none), (pointer:coarse){
  .listing .copy{opacity:1}
  .listing pre{padding-right:2.8rem}
}
/*  A sample inside a listing is a listing: .listing pre and pre.sample
    have the same specificity, so this rule used to win and the
    highlighted Landin blocks -- the ones that carry the argument -- got
    the muted treatment while the plain shell blocks got the accented
    one.  Only a sample standing on its own in prose keeps this.  */
pre.sample:not(.listing > pre){
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
@media (min-width:70rem){
    }

/* ---- index page ---- */
.cards{display:grid; gap:1rem; grid-template-columns:repeat(auto-fit,minmax(17rem,1fr)); margin:2rem 0}
/*  One card.  .card and .route were the same nine declarations twice,
    differing only in an accent border and an accent title.  */
.card, .route{
  display:block; padding:1rem 1.1rem; text-decoration:none; color:inherit;
  background:var(--panel); border:1px solid var(--rule); border-radius:8px;
}
.card:hover, .route:hover{border-color:var(--accent-soft); box-shadow:var(--sh)}
.card strong, .route strong{display:block; font-size:.95rem; margin-bottom:.3rem}
.card span, .route span{display:block; color:var(--ink-soft); font-size:.87rem;
  line-height:1.5}
.card em{display:block; margin-top:.5rem; font-style:normal; font-size:.7rem;
  letter-spacing:.1em; text-transform:uppercase; color:var(--ink-faint)}

/*  The footer sits outside <main> so it is a landmark of its own, which
    put it in the grid's next cell -- under the sidebar, in a 17rem column,
    wrapping after four words.  It belongs in the content column, aligned
    with the document it describes.  */
footer{
  grid-column:2; justify-self:start;
  margin:0 0 4rem; padding:1.2rem 2.4rem 0;
  border-top:1px solid var(--rule);
  color:var(--ink-faint); font-size:.8rem; max-width:44rem;
}
footer code{font-size:.9em; color:var(--ink-soft)}
.hide{display:none !important}
/*  The body uppercases every section heading, so the list of them does
    too: the documents write their own titles in three different cases --
    THE GRAMMAR OF THE ENABLED KERNEL, chip/vendor/gpio, Canonical
    release -- and untransformed they read as three different lists.  */
nav.side a.sect{display:flex; gap:.55rem; align-items:baseline}
nav.side a.sect span:last-child{text-transform:uppercase; letter-spacing:.04em;
  font-size:.8rem}
nav.side a.sect .num{
  font-size:.66rem; color:var(--ink-faint); min-width:1.5rem;
  text-align:right; font-variant-numeric:tabular-nums;
  font-family:var(--mono);
}
.anchor{position:absolute; scroll-margin-top:calc(var(--bar) + .6rem)}

@media (max-width:60rem){
  .wrap{grid-template-columns:minmax(0,1fr)}
  footer{grid-column:1; padding-left:1.2rem; padding-right:1.2rem}
  nav.side{
    position:fixed; inset:var(--bar) 0 auto 0; height:auto; max-height:75vh;
    background:var(--bg); border-right:0; border-bottom:1px solid var(--rule);
    z-index:35; display:none;
  }
  nav.side.open{display:block}
  #menu{display:inline-flex}
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

JS = """
(function(){
  var side=document.querySelector('nav.side');
  var menu=document.getElementById('menu');
  function closeMenu(focus){
    if(!side || !menu) return;
    side.classList.remove('open');
    menu.setAttribute('aria-expanded','false');
    if(focus) menu.focus();
  }
  if(menu) menu.addEventListener('click',function(){
    var open=side.classList.toggle('open');
    menu.setAttribute('aria-expanded',open?'true':'false');
  });
  if(side) side.addEventListener('click',function(e){
    if(e.target.closest('a')) closeMenu(false);
  });
  document.addEventListener('keydown',function(e){
    if(e.key==='Escape' && side && side.classList.contains('open')){
      closeMenu(true);
    }
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
        stays set, so the highlight stopped updating for good.  */
    function schedule(){
      var now=Date.now();
      if(now-last<50) return;
      last=now;
      mark();
    }
    addEventListener('scroll',schedule,{passive:true});
    addEventListener('resize',schedule,{passive:true});
    addEventListener('hashchange',schedule);
    mark();
  }

  /* filter

     What a page is made of differs: the tour and the specification are
     constructs, a prototype is its findings, the front page is cards, and
     a guide is only its sections.  The filter takes the first of those it
     actually finds, so the box does something on every page rather than
     on two of them. */
  var find=document.getElementById('find'), count=document.getElementById('found');
  var UNITS=['.item', '.route, .card, figure.shown', 'main section'];
  function scope(){ return document.querySelector('.doc.on') || document; }
  function pick(here){
    for(var i=0;i<UNITS.length;i++){
      var l=[].slice.call(here.querySelectorAll(UNITS[i]));
      if(l.length) return {sel:UNITS[i], list:l};
    }
    return {sel:'', list:[]};
  }
  /* A link to a section the filter has hidden is a control that does
     nothing, so it is hidden with it -- and shown again when cleared. */
  function syncNav(){
    document.querySelectorAll('nav.side a.sect').forEach(function(a){
      var t=document.getElementById(a.getAttribute('href').slice(1));
      a.classList.toggle('hide',!!t&&t.classList.contains('hide'));
    });
  }
  function filter(){
    var here=scope(), chosen=pick(here), units=chosen.list;
    var secs=[].slice.call(here.querySelectorAll('main section'));
    var q=find.value.trim().toLowerCase();
    if(!q){
      units.forEach(function(u){ u.classList.remove('hide'); });
      secs.forEach(function(s){ s.classList.remove('hide'); });
      syncNav();
      count.textContent=''; return;
    }
    var hits=0;
    units.forEach(function(u){
      if(!u.dataset.text) u.dataset.text=(u.textContent||'').toLowerCase();
      var ok=u.dataset.text.indexOf(q)>=0 || (u.id||'').indexOf(q)===0;
      u.classList.toggle('hide',!ok); if(ok) hits++;
    });
    /*  A section that held units and now shows none goes too -- unless the
        sections are themselves what is being filtered. */
    if(chosen.sel && chosen.sel.indexOf('section')<0){
      var vis=chosen.sel.split(',').map(function(x){
        return x.trim()+':not(.hide)'; }).join(',');
      secs.forEach(function(s){
        s.classList.toggle('hide', !s.querySelector(vis)
                                   && !!s.querySelector(chosen.sel));
      });
    }
    syncNav();
    count.textContent=hits+(hits===1?' match':' matches')
      +(q?' for “'+q+'”':'');
  }
  window.landinFilter=filter;
  if(find){
    find.addEventListener('input',filter);
    find.addEventListener('keydown',function(e){
      if(e.key==='Escape'){
        e.stopPropagation(); find.value=''; filter(); find.blur();
      }
    });
  }
  /* A bare '/' used to be swallowed anywhere on the page, which breaks
     speech input and anything else that emits one (WCAG 2.1.4).  It now
     only reaches the filter when no field has focus. */
  document.addEventListener('keydown',function(e){
    if(e.key!=='/'||!find) return;
    var on=document.activeElement;
    if(on&&on!==document.body&&/^(INPUT|TEXTAREA|SELECT)$/.test(on.tagName)) return;
    if(on===find) return;
    e.preventDefault(); find.focus();
  });

  /* what a citation says, without leaving the line */
  var pop=document.getElementById('pop');
  function hide(){ if(pop) pop.style.display='none'; }
  function show(a){
    if(!a||!pop) return;
    var href=a.getAttribute('href');
    if(href.charAt(0)!=='#') return;
    var t=document.getElementById(href.slice(1)); if(!t) return;
    /* A construct whose body is only code has no paragraph -- [0010] is
       one line of comment and a fence -- and the preview used to show
       nothing at all for those.  Its heading says what it is. */
    var p=t.querySelector('p')||t.querySelector('h3'); if(!p) return;
    pop.innerHTML='<span class="tag mono">['+a.dataset.cite+']</span>';
    pop.appendChild(document.createTextNode(p.textContent));
    pop.style.display='block';
    var r=a.getBoundingClientRect(), w=pop.offsetWidth, h=pop.offsetHeight;
    var left=Math.min(r.left+window.scrollX, window.scrollX+innerWidth-w-16);
    var top=r.top+window.scrollY-h-8;
    if(top<window.scrollY+8) top=r.bottom+window.scrollY+8;
    pop.style.left=Math.max(window.scrollX+8,left)+'px';
    pop.style.top=top+'px';
    a.setAttribute('aria-describedby','pop');
  }
  /* A citation is a link, so it is already in the tab order; hovering was
     the only way to read what it says, which left the keyboard and every
     touch device out. */
  document.addEventListener('mouseover',function(e){ show(e.target.closest('a.cite')); });
  document.addEventListener('focusin',function(e){ show(e.target.closest('a.cite')); });
  function drop(e){
    var a=e.target.closest('a.cite');
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
"""


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
    dict(key="examples", src="examples.md", out="examples.html",
         nav="running examples", group="the language",
         blurb="Four complete programs the compiler emits and the Linux "
               "gate runs: recursive Fibonacci and three sorting algorithms."),
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
.cards h3.group{grid-column:1/-1;font:600 13px/1 var(--ui);
  letter-spacing:.08em;text-transform:uppercase;color:var(--ink-faint);
  margin:18px 0 2px}
.cards h3.group:first-child{margin-top:0}

/* ---- the front page ---- */
.hero.wide h1{
  font-size:clamp(1.75rem, 1.35rem + 1.8vw, 2.5rem); text-wrap:balance;
}
.hero.wide p:first-of-type{font-size:1.125rem; text-wrap:pretty}
.hero-actions{display:flex; flex-wrap:wrap; gap:.65rem; margin:1.15rem 0}
.hero-actions a{
  display:inline-flex; align-items:center; justify-content:center;
  min-height:2.5rem; padding:.45rem .8rem; border:1px solid var(--rule);
  border-radius:5px; background:var(--panel); font-size:.88rem;
  font-weight:600; text-decoration:none;
}
.hero-actions a.primary{
  color:var(--panel); background:var(--accent); border-color:var(--accent);
}
.hero-actions a:hover{border-color:var(--accent-soft); box-shadow:var(--sh)}
.hero .status{
  max-width:52rem; margin-top:1.8rem; padding:1rem 1.1rem 1.15rem;
  border-left:2px solid var(--accent-soft); background:var(--panel-2);
  color:var(--ink-soft); font-size:.93rem;
}
.hero .status p{margin:0 0 .65rem; color:var(--ink-soft); font-size:1em}
.hero .status p.brief{color:var(--ink); font-weight:600}
.hero .status p:last-of-type{margin-bottom:0}
.roadmap-track{
  display:grid; grid-template-columns:1.4fr 1fr 1fr; gap:1.35rem;
  margin-top:1.25rem; padding-top:1.2rem; border-top:1px solid var(--rule);
}
.roadmap-label{
  display:block; margin-bottom:.55rem; color:var(--ink-faint);
  font-size:.66rem; font-weight:700; letter-spacing:.11em;
  text-transform:uppercase;
}
.roadmap-item{
  display:block; margin:.45rem 0 0; padding-left:.65rem;
  border-left:2px solid var(--rule); color:var(--ink-soft);
  text-decoration:none; line-height:1.35;
}
.roadmap-item:first-of-type{margin-top:0}
.roadmap-item strong{color:var(--ink); font-size:.75rem}
.roadmap-item span{display:block; margin-top:.08rem; font-size:.78rem}
.roadmap-item:hover{border-color:var(--accent-soft)}
.roadmap-now .roadmap-item{border-color:var(--accent); color:var(--ink)}
section.landing{padding-top:4.25rem}
figure.shown{margin:0 0 1.7rem}
figure.shown figcaption{
  display:flex; align-items:baseline; gap:.6rem; margin:0 0 .4rem;
  color:var(--ink-soft); font-size:.9rem;
}
figure.shown figcaption .tag{
  font-size:.68rem; letter-spacing:.04em; color:var(--accent);
  text-decoration:none; border:1px solid var(--rule); border-radius:3px;
  padding:.05rem .3rem;
}
figure.shown figcaption .tag:hover{border-color:var(--accent-soft)}
section.landing p.more{
  margin-top:1.5rem; color:var(--ink-soft); font-size:.93rem; max-width:44rem;
}
.routes{display:grid; gap:1.35rem; margin:0;
  grid-template-columns:repeat(auto-fit,minmax(17rem,1fr))}
.route{border-left:2px solid var(--accent-soft)}
.route strong{color:var(--accent); text-wrap:balance}
@media (max-width:35rem){
  figure.shown .listing pre{white-space:pre-wrap; overflow-wrap:anywhere}
  .roadmap-track{grid-template-columns:1fr; gap:1.1rem}
}
"""

#  A hyphen is not \w, and the documents tag a fence `landin-grammar`.
#  With \w the opener never matched, so the CLOSING fence opened a block
#  that swallowed the next heading -- which showed up as every other
#  construct in spec.md losing its anchor.
FENCE = re.compile(r"^```([\w-]*)\s*$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
BULLET = re.compile(r"^[-*]\s+(.*)$")
NUMBER = re.compile(r"^\d+\.\s+(.*)$")
ROW = re.compile(r"^\|(.*)\|\s*$")
TABLE_RULE = re.compile(r"^\|[\s:|-]+\|\s*$")
QUOTE = re.compile(r"^>\s?(.*)$")
RULE_LINE = re.compile(r"^-{3,}\s*$")
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
                if bullet:
                    items.append(bullet.group(1))
                elif number:
                    items.append(number.group(1))
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
                    items[-1] += " " + rest
                elif not lines[index].strip() and items:
                    #  A blank line between items is a loose list, not the
                    #  end of one: three lettered alternatives spaced apart
                    #  for reading became three one-item lists.
                    ahead = index + 1
                    while ahead < len(lines) and not lines[ahead].strip():
                        ahead += 1
                    if ahead < len(lines) and (BULLET.match(lines[ahead])
                                               or NUMBER.match(lines[ahead])):
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
            #  is the thing a reader filters for and the thing a citation
            #  quotes.  With the id on a bare <h3> the filter had nothing to
            #  hide and the hover preview had no paragraph to read.
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
            tag = "ol" if ordered else "ul"
            body = "".join(f"<li>{inline(i, links, targets)}</li>"
                           for i in items)
            out.append(f"<{tag}>{body}</{tag}>")
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


def nav_html(docs, current, sections):
    out = ['<div class="nav-group">documents</div>']
    out.append(f'<a class="doc" href="index.html">the front page</a>')
    for d in docs:
        here = ' here' if d["out"] == current else ""
        now = ' aria-current="page"' if d["out"] == current else ""
        out.append(f'<a class="doc{here}"{now} href="{d["out"]}">'
                   f'{esc(d["nav"])}</a>')
    out.append('<div class="nav-group">filter this page</div>')
    out.append('<div class="finder">' + icons.use("search", "i")
               + '<input id="find" type="search" '
                 'placeholder="filter this page — press /" '
                 'aria-label="filter this page" '
                 'autocomplete="off" spellcheck="false"></div>')
    out.append('<div id="found" role="status" aria-live="polite"></div>')
    if sections:
        out.append('<div class="nav-group">in this document</div>')
        for sid, title, count in sections:
            label = esc(title.split("  —  ")[0])
            n = str(count) if count else ""
            out.append(f'<a class="sect" href="#{sid}">'
                       f'<span class="num">{n}</span><span>{label}</span></a>')
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


def page(title, kind, heading, hero, body, nav, docname, logo=False,
         out="index.html", description="", extra=""):
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
  <a class="src" href="{REPO}">{icons.use("sourcehut")}<span>source</span></a>
  <button id="menu" type="button" aria-label="documents and sections"
          aria-expanded="false" aria-controls="side">{icons.use("menu")}<span>menu</span></button>
  <input class="theme-x" id="theme" type="checkbox">
  <label for="theme">{icons.use("moon", "i light-only")}{icons.use("sun", "i dark-only")}<span>theme</span></label>
</header>
<div class="wrap">
<nav class="side" id="side" aria-label="documents and sections">
{nav}
</nav>
<main id="document">
<div class="hero{' wide' if logo else ''}" id="{slug(heading)}">
  {landin_icon.inline("light", classes="logo") if logo else ''}
  <div class="kind">{esc(kind)}</div>
  <h1>{esc(heading)}</h1>
  {hero}
</div>
{body}
</main>
<footer>
Generated from <code>{esc(docname)}</code> by <code>render_html.py</code>.
The text file is the specification; this page is a reading of it.
The repository is at <a href="{REPO}">git.sr.ht/~sinnfrei/landin</a>.
<br>Copyright &#169; 2026 Jan Haan.
Licensed under <a href="{REPO}/tree/main/item/LICENSE-MIT">MIT</a> or
<a href="{REPO}/tree/main/item/LICENSE-APACHE">Apache-2.0</a>, at your option.
</footer>
</div>
<div id="pop"></div>
<script>{JS}</script>
</body>
</html>
"""


#  The front page introduces the language rather than listing the files,
#  so it needs four things out of the sources: what the tour opens by
#  saying, what the README says the state of the work is, the roadmap items
#  surrounding active work, and a few constructs to show.  None of it is
#  written here -- a second copy is a copy that goes stale.

LANDING_IDS = ["0040", "0870", "0940"]

FENCE_OPEN = re.compile(r"^```landin\s*$")
ROADMAP_ITEM = re.compile(
    r"^### (R\d+\.\d+) — (.+)\n"
    r"Status: (planned|active|blocked|complete)$", re.M)


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
    """The lead and supporting sentences in the README's status."""
    prefix = f"Status: {VERSION_LINE}."
    if not text.startswith(prefix):
        raise SystemExit("render_html: README.md's status does not begin with "
                         f"{prefix!r}")
    remainder = text[len(prefix):].strip()
    if not remainder:
        return prefix, ""
    m = re.match(r"^(.+?\.)(?:\s+(.+))$", remainder)
    if m:
        return f"{prefix} {m.group(1)}", m.group(2)
    if remainder.endswith("."):
        return f"{prefix} {remainder}", ""
    raise SystemExit("render_html: status_parts cannot find a complete "
                     f"compiler-status sentence after {prefix!r} in README.md")


def roadmap_progress(text, recent_count=3):
    """The completed, active and next items around current roadmap work."""
    items = [dict(key=m.group(1), title=m.group(2), status=m.group(3))
             for m in ROADMAP_ITEM.finditer(text)]
    active = [i for i, item in enumerate(items) if item["status"] == "active"]
    if len(active) != 1:
        raise SystemExit("render_html: ROADMAP.md must have exactly one active "
                         "item for the front page")
    at = active[0]
    completed = [item for item in items[:at]
                 if item["status"] == "complete"][-recent_count:]
    following = items[at + 1] if at + 1 < len(items) else None
    return dict(recent=completed, current=items[at], following=following)


def landing_samples(text, ids=LANDING_IDS):
    """A few constructs, taken whole from the tour and kept citable.

    By id rather than by position: [NNNN] is stable and the order is not,
    which is what the tour says the numbering is for.
    """
    lines = text.split("\n")
    found = {}
    for i, line in enumerate(lines):
        m = re.match(r"^### \[(\d{4})\] (.*)$", line)
        if not m or m.group(1) not in ids:
            continue
        j = i + 1
        while j < len(lines) and not FENCE_OPEN.match(lines[j]):
            if lines[j].startswith("### "):
                j = len(lines)
                break
            j += 1
        if j >= len(lines):
            continue
        k = j + 1
        while k < len(lines) and not lines[k].startswith("```"):
            k += 1
        code = lines[j + 1:k]
        while code and not code[-1].strip():
            code.pop()
        found[m.group(1)] = (m.group(2), code)
    return [(i, *found[i]) for i in ids if i in found]


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


def index_page(docs, counts, intro, status, progress, samples, symbols):
    """The front door: what the language is, what it looks like, where to go.

    The contents remain, at the bottom, because a reader who came back for
    one document should not have to read the introduction again.
    """
    groups = []
    for d in docs:
        name = d.get("group", "the specification")
        if not groups or groups[-1][0] != name:
            groups.append((name, []))
        groups[-1][1].append(d)

    body = []

    #  What it looks like, in constructs taken from the tour itself.  Each
    #  keeps its number, and the number is the link back to the full entry.
    if samples:
        shown = []
        for cid, title, code in samples:
            hl = Highlighter(*symbols, links=lambda ref: None)
            shown.append(
                f'<figure class="shown">'
                f'<figcaption><a class="tag" href="tour.html#{cid}">{cid}</a>'
                f'<span>{esc(title)}</span></figcaption>'
                f'{listing(hl.block(code))}</figure>')
        body.append(
            '<section class="landing" id="what-it-looks-like">'
            '<h2>what it looks like</h2>'
            f'{chr(10).join(shown)}'
            '<p class="more">These samples come from the tour and show the '
            'designed language. The status above says which subset refine '
            'accepts today; <a href="examples.html">the running examples</a> '
            'show complete programs from that kernel. Every construct is '
            'numbered, and the numbers do not move. '
            '<a href="tour.html">Read the tour</a> for the rest.</p></section>')

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
         "Recursive Fibonacci, insertion sort, selection sort and merge "
         "sort: complete sources the Linux gate builds and executes."),
    ]
    cards = "".join(
        f'<a class="route" href="{href}"><strong>{esc(head)}</strong>'
        f'<span>{esc(text)}</span></a>' for href, head, text in routes)
    body.append('<section class="landing" id="start-here">'
                f'<h2>start here</h2><div class="routes">{cards}</div>'
                '</section>')

    #  The contents, as they were.
    cards = []
    for name, members in groups:
        cards.append(f'<h3 class="group">{esc(name)}</h3>')
        for d in members:
            n = counts.get(d["out"], "")
            cards.append(
                f'<a class="card" href="{d["out"]}"><strong>{esc(d["nav"])}'
                f'</strong><span>{esc(d["blurb"])}</span>'
                f'<em>{esc(n)}</em></a>')
    body.append('<section class="landing" id="every-document">'
                '<h2>every document</h2>'
                f'<div class="cards">{chr(10).join(cards)}</div>'
                '</section>')

    hero = "".join(f"<p>{esc(t)}</p>" for t in intro)
    hero += ('<div class="hero-actions">'
             '<a class="primary" href="tour.html">read the tour</a>'
             '<a href="spec.html">browse the specification</a></div>')
    if status:
        brief, detail = status_parts(status)
        hero += ('<aside class="status" aria-label="Project status">'
                 f'<p class="brief">{prose_html(brief, lambda ref: None)}</p>')
        if detail:
            hero += f'<p>{prose_html(detail, lambda ref: None)}</p>'
        if progress:
            def progress_item(item):
                heading = f'{item["key"]} — {item["title"]}'
                return (f'<a class="roadmap-item" '
                        f'href="roadmap.html#{slug(heading)}">'
                        f'<strong>{esc(item["key"])}</strong>'
                        f'<span>{esc(item["title"])}</span></a>')

            recent = "".join(progress_item(item)
                             for item in progress["recent"])
            current = progress_item(progress["current"])
            following = (progress_item(progress["following"])
                         if progress["following"] else "")
            hero += ('<div class="roadmap-track">'
                     '<div><span class="roadmap-label">recently completed</span>'
                     f'{recent}</div>'
                     '<div class="roadmap-now">'
                     '<span class="roadmap-label">in progress</span>'
                     f'{current}</div>'
                     '<div><span class="roadmap-label">up next</span>'
                     f'{following}</div></div>')
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
                LANDING_LINE, "Landin", hero, chr(10).join(body), nav,
                "the repository", logo=True, out="index.html",
                description=summary, extra=extra)


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

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if re.fullmatch(r"h[1-6]", tag):
            self.headings.append(tag)
        if tag == "section":
            self.sections.append(values.get("id") == "every-document")
        if (tag == "a" and any(self.sections)
                and "card" in values.get("class", "").split()):
            self.shelf.append(values.get("href", ""))

    def handle_endtag(self, tag):
        if tag == "section" and self.sections:
            self.sections.pop()


def page_shape(out):
    shape = PageShape()
    shape.feed(out.read_text())
    return shape


def verify_structure(out: Path):
    """A page title is the root of its heading outline, exactly once."""
    headings = page_shape(out).headings
    failures = []
    if headings.count("h1") != 1:
        failures.append(f"has {headings.count('h1')} h1 headings")
    if not headings or headings[0] != "h1":
        failures.append("does not begin its heading outline with h1")
    if failures:
        print(f"  {out.name}: " + "; ".join(failures))
    return not failures


def body_region(page_html):
    """The part of a page that is the document, and not the furniture."""
    found = MAIN.search(page_html)
    return ASIDE.sub(" ", found.group(1) if found else page_html)


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
    # inside a listing a span sits between the halves of one name, so tags
    # go without a space there and with one everywhere else
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


def verify_front(out: Path, pieces, docs):
    """The front page holds no document of its own, so it is checked
    against the pieces it was built from.

    It was the one page with no check at all: the pitch, the status line,
    the roadmap window and the three samples are lifted out of their source
    documents, and any reader could quietly return nothing -- a renamed
    status line, a moved rule, a construct that lost its fence -- leaving a
    blank section that no word count would notice.
    """
    from collections import Counter
    got = Counter(WORD.findall(html.unescape(
        TAG.sub(" ", body_region(out.read_text())))))
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
    python3 render_html.py tour.md spec.md      render only those

An unrecognised argument is refused rather than ignored: '--verfiy' used to
render all sixteen pages without checking one of them."""


def main(argv):
    #  main() is handed argv without the program name, so every element
    #  here is an argument the caller meant.
    expecting = False
    for arg in argv:
        if expecting:                       # the directory after --from
            expecting = False
            continue
        if arg in ("--help", "-h"):
            print(USAGE)
            return 0
        if arg == "--from":
            expecting = True
            continue
        if arg == "--verify":
            continue
        why = ("no such option" if arg.startswith("-") else "not a document")
        if arg.startswith("-") or not arg.endswith(".md"):
            print(f"render_html: {why}: {arg}\n\n{USAGE}", file=sys.stderr)
            return 2

    check = "--verify" in argv

    source = HERE
    if "--from" in argv:
        at = argv.index("--from") + 1
        if at >= len(argv):
            print("render_html: --from wants a directory", file=sys.stderr)
            return 2
        source = Path(argv[at]).resolve()

    named = [Path(a).name for a in argv if a.endswith(".md")]
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
    construct_page, finding_page = {}, {}
    for entry in DOCS:
        held = (source / entry["src"]).read_text()
        for found in re.findall(r"^### \[(\d{4})\] ", held, re.M):
            construct_page[found] = entry["out"]
        for found in re.findall(r"^([XYZW]\d+)\s", held, re.M):
            finding_page[found] = entry["out"]

    link_targets = guide_targets(DOCS + GUIDES)

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
            text, links, link_targets,
            Highlighter(*symbols, links=links))
        nav = nav_html(DOCS + GUIDES, d["out"], nav_sections)
        out = page(tab_title(title, d["nav"]), d["nav"],
                   title or d["nav"], hero, body, nav, d["src"],
                   out=d["out"], description=d["blurb"])
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
            text, links, link_targets,
            Highlighter(*guide_symbols, links=links))
        nav = nav_html(DOCS + GUIDES, g["out"], nav_sections)
        out = page(tab_title(title, g["nav"]), g["nav"], title or g["nav"],
                   hero, body, nav, g["src"],
                   out=g["out"], description=g["blurb"])
        (SITE / g["out"]).write_text(out)
        counts[g["out"]] = shelf_count(0, 0, len(nav_sections))
        print(f"{SITE.name}/{g['out']:<20} {len(out) // 1024:4d} KB  "
              f"{len(nav_sections)} sections")

    front = []
    if len(docs) == len(DOCS) and len(guides) == len(GUIDES):
        tour_text = (source / "tour.md").read_text()
        intro = tour_intro(tour_text)[:2]
        status = readme_status((source / "README.md").read_text())
        progress = roadmap_progress((source / "ROADMAP.md").read_text())
        samples = landing_samples(tour_text)

        #  Each reader must have found something.  Failing loudly here is
        #  the contract this renderer keeps everywhere else: refuse what
        #  you cannot read rather than publishing a hole.
        if not intro:
            raise SystemExit("render_html: tour.md has no opening prose "
                             "for the front page")
        if not status:
            raise SystemExit("render_html: README.md has no **Status:** "
                             "line for the front page")
        if len(samples) != len(LANDING_IDS):
            missing = set(LANDING_IDS) - {cid for cid, _, _ in samples}
            raise SystemExit("render_html: the front page shows "
                             + ", ".join(sorted(missing))
                             + ", which tour.md does not define with a "
                               "landin fence")

        (SITE / "index.html").write_text(
            index_page(DOCS + GUIDES, counts, intro, status, progress, samples,
                       guide_symbols))
        print(f"{SITE.name}/index.html")
        for name in write_resources(DOCS + GUIDES):
            print(f"{SITE.name}/{name}")
        front = ([("the pitch", " ".join(intro)), ("the status", status)]
                 + [(f'roadmap {item["key"]}', item["title"])
                    for item in (progress["recent"]
                                 + [progress["current"]]
                                 + ([progress["following"]]
                                    if progress["following"] else []))]
                 + [(f"sample [{cid}]", "\n".join(code))
                    for cid, _, code in samples])

    if check:
        print("checking that nothing was dropped:")
        ok = all([verify(source / d["src"], SITE / d["out"])
                  for d in docs + guides])
        structure = all([verify_structure(SITE / d["out"])
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
