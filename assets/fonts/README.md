# The faces

Two vendored webfont families, and one module that is every rendering of
them. `Nunito Sans` sets the prose, `MonoLisaCode` sets the code, and
nothing outside [`../fonts.py`](../fonts.py) names either — the same
arrangement as [the mark](../README.md) and
[the highlighter](../../highlight/README.md), for the same reason.

| artifact | is | state |
|---|---|---|
| `nunito-sans/nunito-sans.css` | the roman and italic faces of the variable family, ten subsets, from the Google Fonts API | here |
| `nunito-sans/woff2/` | those ten subsets | here |
| `nunito-sans/OFL.txt` | the SIL Open Font License 1.1 it is under | here |
| `monolisa-code/monolisa-code.css` | the foundry's own stylesheet, verbatim: seventy subsets, roman and italic | here |
| `monolisa-code/woff2/` | those seventy subsets | here |
| `monolisa-code/LICENSE.md` | what MonoLisa is licensed under, which is not open source | here |
| `../fonts.py` | the `@font-face` block, the `--ui` and `--mono` stacks, and the list of files to copy | here |
| `docs/site/render_html.py` | the reading copies | imports the module |
| `site/fonts/` | the eighty files, copied beside the pages at render time | generated |

```sh
python3 assets/fonts.py     # what is vendored, and what a page will ask for
```

## Why the declarations are read rather than written

Each family keeps its source's own stylesheet, and `fonts.py` reads the
`@font-face` rules out of it. What those rules say is which weights the
variable axis covers and which codepoints each subset carries: eighty
`unicode-range` lists, several of them a dozen ranges long. Transcribing
that into Python would be eighty chances to mistype a range, and a
mistyped range is not a build failure — it is one paragraph, on one page,
quietly set in a fallback face.

So the only thing rewritten is the `src` url, which named a path that
means nothing here, and the only thing added is `font-display:swap` to a
face that came without one. Re-vendoring a family is: replace its `woff2/`
and its `.css`, run the check.

## Why the subsets are shipped whole

Eighty files is not eighty requests. `unicode-range` is what makes them
one family, and the browser fetches only the subsets the page actually
puts on screen — the tour, which is English prose and ASCII code, asks
for three of the eighty and 100 KB of the 965 KB.

Merging them into one file per family would make every reader pay for
Cyrillic, Hebrew, Thai, Braille and the private-use area. Subsetting them
here instead — keeping only the ranges the documents use today — would
make the day a document gains a Greek letter the day that letter silently
comes out in a fallback face. Shipping what the sources ship is the only
one of the three that neither charges for glyphs nobody reads nor loses
one nobody was watching for.

`check.py` holds the other end of it: every character in every rendered
document has to fall inside a vendored subset of both families. A
document that drifts outside them fails the build rather than the page.

## What is not inlined

The pages inline their stylesheet, their script, their highlighting and
their favicon, so one file can be mailed or opened from disk. The faces
are the exception, and it is not a close call: the eighty subsets are 965
KB, and a page carrying even the three an English reader needs would be
140 KB heavier for glyphs the next page would carry again.

So the declarations travel in the page and the faces sit beside it, under
`fonts/`, reached by a relative url. What that costs is a page mailed on
its own, which falls back to the stack behind each family —
`-apple-system` and `ui-monospace`, which is what the pages were set in
before either family was vendored. `font-display:swap` is what makes that
fallback show immediately rather than after three seconds of invisible
text.

## The licenses

They are not the same, and the difference matters more than the file
sizes.

Nunito Sans is under the SIL Open Font License 1.1 (`OFL.txt`). It may be
vendored, served, and redistributed with the repository.

MonoLisa is not open source. It is a purchased typeface under a EULA, and
the copy here is the licensed webfont package as the foundry delivers it —
the self-hosting form, which is what a web licence is for. The terms are
at <https://www.monolisa.dev/license>. The foundry's `/*! @preserve */`
header is carried through `fonts.py` into every page, which is what it is
for. `monolisa-code/LICENSE.md` says the rest.
