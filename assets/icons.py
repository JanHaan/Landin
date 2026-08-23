"""The small icons a page uses, vendored rather than fetched.

Six of them come from Lucide and one from sourcehut.  They are copied in
here as their own shapes rather than pulled from a package or a CDN, for
the reasons everything else in this directory is: a page that carries its
drawing needs no request to show it, and a build that reads a file in this
repository needs no dependency to run.  `landin_icon.py` holds the mark
itself; this holds the furniture around it.

Both sources permit the copy and both ask to be named, which is what the
notices below are for.  Their terms are recorded here rather than in a
NOTICE file nobody opens, because the place to say where a drawing came
from is next to the drawing.

Standard library only, like the rest of the site build.
"""

#  Lucide, https://lucide.dev -- ISC.
#
#      Copyright (c) 2026 Lucide Icons and Contributors
#
#      Permission to use, copy, modify, and/or distribute this software
#      for any purpose with or without fee is hereby granted, provided
#      that the above copyright notice and this permission notice appear
#      in all copies.
#
#  Taken from lucide-static v1.33.0, shape for shape.  Every Lucide icon
#  is drawn on a 24 grid with a 2-unit round-capped stroke and no fill,
#  which is why STROKE below is one set of attributes for all of them.
LUCIDE_VERSION = "1.33.0"

#  sourcehut, https://sourcehut.org/logo/ -- CC0.  Their own page: "A
#  circle is not copyrightable.  But, if you insist, you may consider
#  these CC-0."  Trademark rights are reserved there and not waived, so
#  this is used to point at sourcehut and nothing else.
SRHT_VERSION = "logo.svg as served, 2026-08"

STROKE = ('fill="none" stroke="currentColor" stroke-width="2" '
          'stroke-linecap="round" stroke-linejoin="round"')

#  name -> (viewBox, attributes for the group, the shapes)
ICONS = {
    "search": ("0 0 24 24", STROKE,
               '<path d="m21 21-4.34-4.34"/>'
               '<circle cx="11" cy="11" r="8"/>'),
    "copy": ("0 0 24 24", STROKE,
             '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/>'
             '<path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>'),
    "check": ("0 0 24 24", STROKE,
              '<path d="M20 6 9 17l-5-5"/>'),
    "sun": ("0 0 24 24", STROKE,
            '<circle cx="12" cy="12" r="4"/>'
            '<path d="M12 2v2"/><path d="M12 20v2"/>'
            '<path d="m4.93 4.93 1.41 1.41"/>'
            '<path d="m17.66 17.66 1.41 1.41"/>'
            '<path d="M2 12h2"/><path d="M20 12h2"/>'
            '<path d="m6.34 17.66-1.41 1.41"/>'
            '<path d="m19.07 4.93-1.41 1.41"/>'),
    "moon": ("0 0 24 24", STROKE,
             '<path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46'
             '.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401"/>'),
    "menu": ("0 0 24 24", STROKE,
             '<path d="M4 5h16"/><path d="M4 12h16"/><path d="M4 19h16"/>'),
    #  The whole of it: a ring, on the 128 grid sourcehut draws it on.
    "sourcehut": ("0 0 128 128",
                  'fill="none" stroke="currentColor" stroke-width="10"',
                  '<circle cx="64" cy="64" r="50"/>'),
}

WHY = {
    "search": "the filter field",
    "copy": "a listing's copy button",
    "check": "the same button, having copied",
    "sun": "the theme toggle, offering the light one",
    "moon": "the theme toggle, offering the dark one",
    "menu": "the sidebar drawer, below 60rem",
    "sourcehut": "the link to the repository",
}


def symbols(names=None):
    """The icons as one sprite, to be dropped in once per page.

    A page carries 140 copy buttons, so the shapes are defined once and
    referenced with <use> rather than repeated: as inline copies the
    tour's buttons alone came to 40 KB of identical path data.
    """
    wanted = list(ICONS) if names is None else list(names)
    out = ['<svg class="sprite" aria-hidden="true" focusable="false" '
           'style="display:none" xmlns="http://www.w3.org/2000/svg">']
    for name in wanted:
        box, attrs, shapes = _icon(name)
        out.append(f'<symbol id="i-{name}" viewBox="{box}" {attrs}>'
                   f"{shapes}</symbol>")
    out.append("</svg>")
    return "".join(out)


def use(name, classes="i"):
    """One reference to a sprite symbol.

    aria-hidden, because every place one of these appears has a text
    label or an aria-label of its own: an icon that repeats the word
    beside it should not be read out twice.
    """
    _icon(name)
    return (f'<svg class="{classes}" aria-hidden="true" focusable="false">'
            f'<use href="#i-{name}"/></svg>')


def _icon(name):
    if name not in ICONS:
        raise SystemExit(
            "assets/icons.py: no such icon: %s (have %s)"
            % (name, ", ".join(sorted(ICONS))))
    return ICONS[name]


def main(argv):
    print("%d icons, Lucide %s and sourcehut's own"
          % (len(ICONS), LUCIDE_VERSION))
    for name in ICONS:
        print("  %-10s %s" % (name, WHY[name]))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv))
