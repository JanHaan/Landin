# The faces

Two webfont families, and one module through which every page uses them.
`Nunito Sans` sets the prose, `MonoLisaCode` sets the code, and nothing
outside [`../fonts.py`](../fonts.py) names either — the same arrangement
as [the mark](../README.md) and
[the highlighter](../../highlight/README.md), for the same reason.

They do not live in the same place, because their licences do not allow
it. Nunito Sans is vendored here. MonoLisa is under a EULA that forbids
passing the font data to anyone else, so its package is not in this
repository. No build can fetch it from the foundry, so the one licensed
copy the project uses sits in the maintainer's object storage, at the
address `fonts.py` names as `LICENSED_SOURCE`, and `licensed.sha256` here
pins it file by file (D1336). That storage is the family's source; a host
gets it with one command:

```sh
python3 assets/fonts.py --fetch
```

That fetches the pinned family into `~/.cache/landin/fonts`, or
`$XDG_CACHE_HOME/landin/fonts`, where `fonts.py`, `check.py` and the site
build find it, or into the directory `LANDIN_FONTS` names when it is set.
It replaces an earlier fetch there, and refuses a directory it did not
make.

| artifact | is | state |
|---|---|---|
| `nunito-sans/nunito-sans.css` | the roman and italic faces of the variable family, ten subsets, from the Google Fonts API | here |
| `nunito-sans/woff2/` | those ten subsets | here |
| `nunito-sans/OFL.txt` | the SIL Open Font License 1.1 it is under | here |
| `licensed.sha256` | the SHA-256 of MonoLisa's stylesheet and of each of its faces | here |
| `monolisa/monolisa.css` | the foundry's own stylesheet, verbatim: MonoLisa 3.000, twenty subsets, roman and italic | object storage, fetched |
| `monolisa/woff2/` | those twenty subsets | object storage, fetched |
| `monolisa/LICENSE.md` | what MonoLisa is licensed under, which is not open source | object storage, fetched |
| `../fonts.py` | the `@font-face` block, the `--ui` and `--mono` stacks, and the list of files to copy | here |
| `docs/site/render_html.py` | the reading copies | imports the module |
| `site/fonts/` | the thirty files, copied beside the pages at render time | generated |

```sh
python3 assets/fonts.py            # what is available, and what a page will ask for
python3 assets/fonts.py --require  # exit 1 naming any family this host lacks
python3 assets/fonts.py --fetch    # the pinned licensed family, from its storage
python3 assets/fonts.py --fetch BASE DEST  # the same from BASE, into a new DEST
python3 assets/fonts.py --pin      # record the licensed family's digests
```

## Why the declarations are read rather than written

Each family keeps its source's own stylesheet, and `fonts.py` reads the
`@font-face` rules out of it. What those rules say is which weights the
variable axis covers and which codepoints each subset carries: thirty
`unicode-range` lists, several of them a dozen ranges long. Transcribing
that into Python would be thirty chances to mistype a range, and a
mistyped range is not a build failure — it is one paragraph, on one page,
quietly set in a fallback face.

So the only thing rewritten is the `src` url, which named a path that
means nothing here, and the only thing added is `font-display:swap` to a
face that came without one. Re-vendoring a family is: replace its `woff2/`
and its `.css`, run the check.

## Read, not trusted

What `fonts.py` makes of a stylesheet is inlined into a `<style>` element
on every page, and the licensed stylesheet is fetched at publish time from
storage outside the repository. So no text of it is copied through. A rule
is rebuilt from the descriptors `fonts.py` lists in `DESCRIPTORS`, each
value made only of names, numbers, quotes and the punctuation of a range;
a face's file is a bare `NAME.woff2`; and a preserved header holding a `<`
is refused, since `</style` is the one thing that ends the element. A
stylesheet that says anything else stops the build with the declaration it
objected to.

`--fetch` applies the same to where files are written: it fetches a face
only when the stylesheet names it `woff2/FILE.woff2`, writes it only as
that file under a directory it created, reads the result as a render
will, and only then gives that directory the name it was asked to fill.

`licensed.sha256` in this directory pins the licensed stylesheet and each
face by SHA-256, in `sha256sum`'s format with paths relative to the
licensed root. A render or a fetch refuses a file that differs and a face
that is not pinned, so a copy changed in storage stops the publish rather
than reaching the pages. Replacing the foundry's package is: upload the
customiser's new `monolisa.css` and `woff2/` to the storage, fetch them
into a new directory with `--fetch BASE DEST`, read them, run
`LANDIN_FONTS=DEST python3 assets/fonts.py --pin` and commit the new
`licensed.sha256` with the change that needs it. Without the file the
licensed family would be held to its form only, and `--fetch` would say
so in a warning on the workflow run.

## Why the subsets are shipped whole

Thirty files is not thirty requests. `unicode-range` is what makes them
one family, and the browser fetches only the subsets the page actually
puts on screen — the tour, which is English prose and ASCII code, asks
for three of them.

Merging them into one file per family would make every reader pay for
Cyrillic and the private-use area. Subsetting them here instead — keeping
only the ranges the documents use today — would make the day a document
gains a Greek letter the day that letter silently comes out in a fallback
face. Shipping what the sources ship is the only one of the three that
neither charges for glyphs nobody reads nor loses one nobody was watching
for.

The code face is the one place the ranges were chosen rather than taken:
MonoLisa's customiser built it from the blocks the documents use and the
few they plausibly will — Latin, general punctuation, arrows, operators,
technical symbols and block elements — with the `calt`, `liga`, `dlig` and
`zero` features and no others. That is the foundry subsetting its own
font, which its EULA permits where subsetting it here would not be.

`check.py` holds the other end of it: every character in every rendered
document has to fall inside a subset of both families. A document that
drifts outside them fails the build rather than the page.

## A host without the code face

A checkout of this repository alone has one family. `fonts.py` renders
the pages without the other — `--mono` still names it, and the stack
behind it is what a reader sees — and `render_html.py` says so once on
stderr. `check.py` reports the family's coverage as not checked rather
than failed, because a host that has not fetched the family is an
ordinary host. What refuses is `.github/workflows/pages.yml`, whose fetch
of the family is fatal rather than best-effort: a page published in a
fallback face is the site quietly not being itself, which no word count
can see.

The family used to live in a private repository, `landin-fonts`, that a
developer checked out beside this one and a builds.sr.ht task cloned with
a deploy key. That repository is retired: it was a second copy for every
host to keep in step with the storage the publish fetched from, and the
storage, pinned here, is the one source (D1336).

## What is not inlined

The pages inline their stylesheet, their script, their highlighting and
their favicon, so one file can be mailed or opened from disk. The faces
are the exception, and it is not a close call: the thirty subsets are
close to a megabyte, and a page carrying even the three an English reader
needs would be 140 KB heavier for glyphs the next page would carry again.

So the declarations travel in the page and the faces sit beside it, under
`fonts/`, reached by a relative url. What that costs is a page mailed on
its own, which falls back to the stack behind each family —
`-apple-system` and `ui-monospace`, which is what the pages were set in
before either family was vendored. `font-display:swap` is what makes that
fallback show immediately rather than after three seconds of invisible
text.

## The licenses

They are not the same, and the difference decides where each family
lives.

Nunito Sans is under the SIL Open Font License 1.1 (`OFL.txt`). It may be
vendored, served, and redistributed with the repository.

MonoLisa is not open source. It is a purchased typeface under a EULA
whose web licence permits embedding it in one licensee's site and whose
prohibited-usage clause forbids supplying the font data to any other firm
or individual. Serving it from www.701.dev is the former; keeping it in a
public repository anyone can clone would be the latter, which is why it
is kept out of it and this repository holds only its digests. The terms are at <https://www.monolisa.dev/license>. The
foundry's `/*! @preserve */` header is carried through `fonts.py` into
every page, which is what it is for. The fetched `monolisa/LICENSE.md`
says the rest.
