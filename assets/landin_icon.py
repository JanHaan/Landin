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
import struct
import zlib
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


# --------------------------------------------------------------------------
#  The mark as pixels.
#
#  A social card has to be a raster: og:image is fetched by crawlers that
#  do not render SVG, and a data: URL is not a URL they can fetch.  So the
#  drawing is rasterised here rather than by a dependency -- the path holds
#  only M, L, Q and Z, which is a scanline fill and a quadratic flattening,
#  and PNG is zlib plus four chunks.  Both are in the standard library, so
#  the site keeps its no-dependency build.
# --------------------------------------------------------------------------

def _subpaths(steps=24):
    """The path as closed polylines, with the quadratics flattened."""
    path, _, _ = geometry()
    parts = re.findall(r"[A-Za-z]|-?\d*\.?\d+", path)
    out, run = [], []
    x = y = 0.0
    i, cmd = 0, None

    def quad(x0, y0, cx, cy, x1, y1):
        for k in range(1, steps + 1):
            t = k / steps
            u = 1.0 - t
            run.append((u * u * x0 + 2 * u * t * cx + t * t * x1,
                        u * u * y0 + 2 * u * t * cy + t * t * y1))

    while i < len(parts):
        token = parts[i]
        if token.isalpha():
            cmd = token.upper()
            i += 1
            if cmd == "Z":
                if len(run) > 2:
                    out.append(run)
                run = []
            continue
        if cmd == "M":
            x, y = float(parts[i]), float(parts[i + 1])
            if len(run) > 2:
                out.append(run)
            run = [(x, y)]
            i += 2
        elif cmd == "L":
            x, y = float(parts[i]), float(parts[i + 1])
            run.append((x, y))
            i += 2
        elif cmd == "Q":
            cx, cy = float(parts[i]), float(parts[i + 1])
            nx, ny = float(parts[i + 2]), float(parts[i + 3])
            quad(x, y, cx, cy, nx, ny)
            x, y = nx, ny
            i += 4
        else:
            raise SystemExit("icon.svg: unsupported path command %r" % cmd)
    if len(run) > 2:
        out.append(run)
    return out


def _coverage(width, height, scale, dx, dy, rows=4):
    """How much of each pixel the mark covers, 0.0 to 1.0.

    Sampled `rows` times down each pixel and solved exactly across it: a
    span contributes its overlap with the pixel rather than a hit or a
    miss, which is what keeps a 24-pixel favicon legible.  The fill rule
    is nonzero, as SVG's own default is, so the counter of the 0 stays a
    hole.
    """
    edges = []
    for run in _subpaths():
        pts = run + [run[0]]
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            ax, ay = x0 * scale + dx, y0 * scale + dy
            bx, by = x1 * scale + dx, y1 * scale + dy
            if ay != by:
                edges.append((ax, ay, bx, by))

    cover = [[0.0] * width for _ in range(height)]
    for row in range(height * rows):
        y = (row + 0.5) / rows
        hits = []
        for ax, ay, bx, by in edges:
            if (ay <= y < by) or (by <= y < ay):
                hits.append((ax + (y - ay) * (bx - ax) / (by - ay),
                             1 if by > ay else -1))
        if not hits:
            continue
        hits.sort()
        line = cover[row // rows]
        wind = 0
        start = 0.0
        for x, direction in hits:
            if wind == 0:
                start = x
            wind += direction
            if wind != 0:
                continue
            left, right = max(0.0, start), min(float(width), x)
            if right <= left:
                continue
            first, last = int(left), min(width - 1, int(right - 1e-9))
            for px in range(first, last + 1):
                lo, hi = max(left, px), min(right, px + 1.0)
                if hi > lo:
                    line[px] += (hi - lo) / rows
    return cover


def _rgb(colour):
    colour = colour.lstrip("#")
    return tuple(int(colour[k:k + 2], 16) for k in (0, 2, 4))


def _png(pixels, width, height):
    """RGB8, one filter byte a row.  No dependency does this for us."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b in row:
            raw += bytes((r, g, b))

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def card(width=1200, height=630, plate=None, mark=None, share=0.44):
    """The social card: the mark on a plate, at the size a crawler wants.

    1200x630 is what og:image is read at, and the mark sits on its own
    box rather than the 256 square, so the margin here is this drawing's
    and not the icon's.
    """
    plate = _rgb(plate or PAPER)
    mark = _rgb(mark or ACCENT)
    bx, by, bw, bh = bounds()
    scale = min(width, height) * share / max(bw, bh)
    dx = (width - bw * scale) / 2.0 - bx * scale
    dy = (height - bh * scale) / 2.0 - by * scale

    cover = _coverage(width, height, scale, dx, dy)
    rows = []
    for line in cover:
        row = []
        for a in line:
            a = 0.0 if a < 0 else (1.0 if a > 1 else a)
            row.append(tuple(int(round(p + (m - p) * a))
                             for p, m in zip(plate, mark)))
        rows.append(row)
    return _png(rows, width, height)


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
