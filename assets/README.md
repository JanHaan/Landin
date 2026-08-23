# The mark

One drawing, several renderings, and a few borrowed ones beside it. `icon.svg` holds the geometry and the
site's own two colours, and everything that shows a Landin mark is a
rendering of that file rather than another copy of it that drifts away —
the same arrangement as [`highlight/`](../highlight/README.md), for the
same reason.

| artifact | is | state |
|---|---|---|
| `icon.svg` | the drawing: a plate, the mark, and the light palette as presentation attributes | here |
| `icons.py` | the small icons around the mark: six from Lucide (ISC) and sourcehut's ring (CC0), copied in as shapes with their notices | here |
| `landin_icon.py` | every rendering of it — the variants, the inline fragment, the `data:` URL, and the raster: a scanline fill and a PNG encoder, standard library only | here |
| `docs/site/render_html.py` | the reading copies: the favicon, Safari's pinned tab, the top bar, the front page, the social card | imports the module |
| `og.png`, `apple-touch-icon.png` | rastered by `card()` at render time, never committed | generated |
| a `.ico`, a README badge | the same call at another size | not needed yet |

The mark is `701` set in Futura Bold, converted to a path. As text it was
Futura on a Mac and whatever the fallback chose on the Linux gate, which
is to say it was not one drawing; as a path it needs no font, no
`shape-inside`, and no Inkscape to open it. Redraw it and nothing else
here has to change: `landin_icon.py` reads the path and the colours out of
the file rather than repeating either.

## The variants

```sh
python3 assets/landin_icon.py                    # list them
python3 assets/landin_icon.py dark > dark.svg    # write one
python3 assets/landin_icon.py --write out/       # write all of them
```

| variant | plate | mark | for |
|---|---|---|---|
| `light` | paper | accent | the master; a light page |
| `dark` | ink | the lighter accent | the dark stylesheet |
| `contrast` | accent | paper | inverted, which is what stays legible at 16 pixels and on a background you do not control |
| `mark` | none | `currentColor` | inlining next to text, where it takes the colour it is set in |
| `mono` | none | black | masks, stencils, single-colour print |
| `auto` | either | either | the favicon: one file carrying a `prefers-color-scheme` query, because a tab has no stylesheet of ours to inherit |

Every variant is the same 256 square, so they overlay. A plateless one can
be cropped to the mark's own box instead, which is what the inline
fragment and the pinned-tab icon do — next to a line of text the square's
empty margin is the difference between a mark and a gap. The box is read
off the path rather than measured, and `bounds()` says why that is exact
for this drawing.

Nothing here is written to disk by a build. `--write` is for a one-off
export; the pages carry the icon as a `data:` URL, so a page that is
mailed or opened from disk is still one file with its mark on it, which is
the same rule the inlined stylesheet and the inlined highlighting keep.

## Why this directory

`assets/` is where a tool looks without being told — `t3code` picks the
icon up from here by name — and where a person looks first. It is not
`docs/site/assets/`, because the reading copies are a consumer of the mark
and not the owner of it, in exactly the way they are a consumer of the
highlighter.

## The colours

The four are the stylesheet's, and `check.py` holds them to it: `PAPER`
and `ACCENT` are `--bg` and `--accent` in the light `:root`, `INK` and
`ACCENT_DARK` the same two in the dark one, and the drawing's own two
attributes are the light pair again. Change one in either place and the
check says which other place disagrees. It also refuses a drawing whose
mark has gone back to being text.
