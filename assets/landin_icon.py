"""The mark, and every rendering of it.

One drawing, several renderings.  `icon.svg` holds the geometry — the
plate, the mark, and the two colours the site is already written in — and
everything that shows the icon is a rendering of that file rather than
another copy of it that drifts away.  The reading copies inline it as a
favicon, `t3code` picks it up from this directory by name, and a PNG for a
context that cannot take SVG is one export away.

Nothing here draws.  The geometry is read out of `icon.svg`; this file
knows only which colours a variant wears and how to wrap the result for a
consumer, so a redrawn mark needs no change here at all.

    python3 assets/landin_icon.py                    # list the variants
    python3 assets/landin_icon.py dark > dark.svg    # write one
    python3 assets/landin_icon.py --write out/       # write all of them

Standard library only, like everything else the site build imports: the
pages are rendered with no dependency and an icon is not the thing to
break that for.
"""

import os
import re
import sys
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "icon.svg")

#  The palette is the site's, and docs/site/render_html.py is where it is
#  written for the pages.  These four values are the ones an icon needs;
#  check.py holds them to the stylesheet so the tab cannot end up a
#  different red from the page it belongs to.
PAPER = "#f7f6f2"          # --bg, light
INK = "#12161c"            # --bg, dark
ACCENT = "#a03526"         # --accent, light
ACCENT_DARK = "#e2705c"    # --accent, dark

#  A variant is a plate colour and a mark colour, and nothing else.  None
#  as a plate means no plate: the mark alone, on whatever is behind it.
VARIANTS = {
    "light":    (PAPER, ACCENT),
    "dark":     (INK, ACCENT_DARK),
    "contrast": (ACCENT, PAPER),
    "mark":     (None, "currentColor"),
    "mono":     (None, "#000000"),
}

WHY = {
    "light":    "the master: accent on paper, for a light page",
    "dark":     "paper and accent swapped for the dark stylesheet",
    "contrast": "inverted, which is what stays legible at 16 pixels",
    "mark":     "no plate, currentColor: for inlining next to text",
    "mono":     "no plate, solid black: for masks and single-colour print",
    "auto":     "light or dark by prefers-color-scheme, for the favicon",
}


_HELD = None


def _source():
    #  Read once.  Every page asks for the mark and the box separately,
    #  and the drawing does not change while a build runs.
    global _HELD
    if _HELD is None:
        with open(SOURCE, encoding="utf-8") as handle:
            _HELD = handle.read()
    return _HELD


def geometry():
    """The mark's path data and the master's own two colours."""
    text = _source()
    path = re.search(r'class="mark"[^>]*?\sd="([^"]*)"', text, re.S)
    plate = re.search(r'class="plate"[^>]*?\sfill="([^"]*)"', text, re.S)
    mark = re.search(r'class="mark"[^>]*?\sfill="([^"]*)"', text, re.S)
    if not (path and plate and mark):
        raise SystemExit("assets/icon.svg: no plate and mark to read")
    return " ".join(path.group(1).split()), plate.group(1), mark.group(1)


def bounds():
    """The mark's own box, as `x y width height`.

    Read off the path's coordinates rather than measured: every extreme of
    this drawing is an on-curve point, so the control hull is the box.  A
    mark whose curve bulged past its handles would want a real sweep, and
    the two agree today to the third decimal.
    """
    path, _, _ = geometry()
    parts = re.findall(r"[A-Za-z]|-?\d*\.?\d+", path)
    arity = {"M": 1, "L": 1, "Q": 2, "C": 3}
    xs, ys, i, cmd = [], [], 0, None
    while i < len(parts):
        if parts[i].isalpha():
            cmd = parts[i].upper()
            i += 1
            continue
        for k in range(arity[cmd]):
            xs.append(float(parts[i + 2 * k]))
            ys.append(float(parts[i + 2 * k + 1]))
        i += 2 * arity[cmd]
    return (min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys))


def _box(crop):
    if not crop:
        return "0 0 256 256"
    return " ".join(("%.3f" % v).rstrip("0").rstrip(".") for v in bounds())


def svg(name="light", size=None, style="", crop=False):
    """One variant, as a whole SVG document.

    Every variant is the same 256 square, so they overlay: `crop` trims to
    the mark's own box instead, which is what a plateless one wants when
    something else supplies the padding.
    """
    if name == "auto":
        return _auto(size)
    if name not in VARIANTS:
        raise SystemExit("no such variant: %s" % name)
    plate, mark = VARIANTS[name]
    return _document(plate, mark, size, style, crop)


def _document(plate, mark, size, style, crop=False):
    path, _, _ = geometry()
    box = ' width="%d" height="%d"' % (size, size) if size else ""
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s"%s'
           ' role="img" aria-label="Landin">' % (_box(crop), box)]
    if style:
        out.append("<style>%s</style>" % style)
    if plate:
        out.append('<rect class="plate" width="256" height="256" rx="56" '
                   'fill="%s"/>' % plate)
    out.append('<path class="mark" fill="%s" d="%s"/>' % (mark, path))
    out.append("</svg>")
    return "".join(out)


def _auto(size):
    """The favicon: one file that answers to the reader's own setting.

    A tab has no stylesheet of ours to inherit from, so the answer travels
    inside the drawing.  Chrome and Firefox take an SVG favicon and honour
    a media query inside one; Safari does not take an SVG favicon at all,
    which is what the pinned-tab link beside it is for.  Anything else
    gets the light form, which the presentation attributes already carry.
    """
    dark = "@media(prefers-color-scheme:dark){.plate{fill:%s}.mark{fill:%s}}"
    return _document(PAPER, ACCENT, size, dark % (INK, ACCENT_DARK))


def inline(name="mark", classes="", size=None):
    """One variant as a fragment to drop into a page.

    No <style> and no id: an inline SVG shares the document's namespace,
    and a rule in here would colour anything else on the page that happened
    to be called a plate.  A plateless variant is cropped to the mark,
    because next to a line of text the square's empty margin is the
    difference between a mark and a gap.
    """
    if name not in VARIANTS:
        #  `auto` carries a <style>, which is the one thing a fragment
        #  must not: a page has its own stylesheet to do that with.
        raise SystemExit("no such inline variant: %s" % name)
    path, _, _ = geometry()
    plate, mark = VARIANTS[name]
    box = ' width="%d" height="%d"' % (size, size) if size else ""
    attr = ' class="%s"' % classes if classes else ""
    out = ['<svg%s viewBox="%s"%s aria-hidden="true" '
           'focusable="false">' % (attr, _box(plate is None), box)]
    if plate:
        out.append('<rect width="256" height="256" rx="56" fill="%s"/>'
                   % plate)
    out.append('<path fill="%s" d="%s"/>' % (mark, path))
    out.append("</svg>")
    return "".join(out)


def data_uri(name="auto", size=None, crop=False):
    """A variant as a `data:` URL, which is how a page carries it.

    Percent-encoded rather than base64: it is smaller for this drawing,
    and it stays readable in the source, which base64 does not.  Spaces
    are encoded too, though every browser would forgive them: a URL in an
    attribute is read by more than browsers.
    """
    return "data:image/svg+xml," + quote(svg(name, size, crop=crop),
                                         safe="/:=")


def main(argv):
    if "--write" in argv:
        at = argv.index("--write") + 1
        if at >= len(argv):
            raise SystemExit("--write wants a directory to write into")
        where = argv[at]
        os.makedirs(where, exist_ok=True)
        for name in list(VARIANTS) + ["auto"]:
            out = os.path.join(where, "icon-%s.svg" % name)
            with open(out, "w", encoding="utf-8") as handle:
                handle.write(svg(name) + "\n")
            print("%-24s %s" % (out, WHY[name]))
        return 0

    wanted = [a for a in argv[1:] if not a.startswith("-")]
    if wanted:
        print(svg(wanted[0]))
        return 0

    path, plate, mark = geometry()
    print("assets/icon.svg   plate %s   mark %s   %d bytes of path"
          % (plate, mark, len(path)))
    for name in list(VARIANTS) + ["auto"]:
        print("  %-9s %s" % (name, WHY[name]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
