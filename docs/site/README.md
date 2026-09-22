# The reading copies

`render_html.py` renders the language documents and the guides selected in
its `DOCS` and `GUIDES` lists as self-contained HTML pages. `scripts/site.sh`
renders and packages them. The Markdown files are the rendering sources;
publication does not change their authority. The specification remains
normative, and derived guides such as [the IR explanation](../ir.md) remain
non-authoritative.

## What it renders

| kind | sources | how it is read |
|---|---|---|
| the tour | `tour.md` | as a literate document: every `[NNNN]` construct becomes a block holding its prose and the code that follows, and every citation becomes a link to the construct it names |
| the prototypes | `prototype-{1..4}-*.md` | as listings, because in those the code is the argument, with the closing findings pulled out as entries |
| the guides | the Markdown documents named in `GUIDES`, including `examples.md` | as ordinary prose, with `[NNNN]` citations linked into the tour and links between documents rewritten to the pages they name |

Nothing here is a parser, and the highlighting is not written here. It comes
from [`highlight/landin_highlight.py`](../../highlight/README.md), the one
scanner the Pygments lexer reads as well, so the pages cannot colour the
language differently from every other tool that highlights it; this file
turns the classes it emits into spans and links the citations in comments.

Source links resolve relative to the document that contains them, so different
files named `README.md` keep their own destinations. A selected document links
to its rendered page; other repository files, including editor-specific and
binding-generator guides, link to their canonical source view. URL queries,
fragments, external links and page-local anchors retain their meaning.

The faces are not chosen here. They come from
[`assets/fonts.py`](../../assets/fonts/README.md), which is every rendering
of the two families — `Nunito Sans` for prose, vendored, and `MonoLisaCode`
for code, from a private checkout its licence requires — so `--ui` and
`--mono` cannot name a face the site does not ship beside the pages. The
`@font-face` rules are read out of each family's own stylesheet rather
than transcribed, because what they carry is thirty `unicode-range` lists
and a mistyped range is not a build failure but a paragraph quietly set in
a fallback.

The mark is not drawn here either. It comes from
[`assets/icon.svg`](../../assets/README.md) through `landin_icon.py`, which
is what every rendering of it goes through: the favicon carries a
`prefers-color-scheme` query so a tab follows the reader's own setting,
Safari's pinned tab gets the mark alone with no plate, the top bar takes it
inline in `currentColor` so it follows the theme with no second drawing,
the front page wears the plated one, and the social card is that same
drawing rastered. The favicon and the two inline ones are `data:` URLs or
fragments; the pinned tab and the card are files, for the readers that
cannot take a `data:` URL.
The Markdown reader covers the subset the repository uses, and refuses a
construct it does not recognise rather than passing it through as text,
because a table that renders as a row of pipes is worse than a build that
stops. So it stops on a fence that is never closed, a table row whose cell
count does not match its header, and a nested list — each of which it used to
absorb silently, losing structure that no word count could miss.

## Building and publishing

```sh
./scripts/site.sh              # render, verify, package
```

`.github/workflows/pages.yml` publishes on every push to main. It renders with
the same `--verify` pass, fetches the licensed code face from object storage
because that face is not in this repository, writes the `www.701.dev` CNAME and
deploys to GitHub Pages. It is not a gate and runs no compiler test.
`scripts/site.sh` renders and packages and does not publish; the `--publish`
that uploaded to pages.sr.ht went with the SourceHut gate. Native
acceptance and evidence export happen before promotion; see
[`environments/native-ci/README.md`](../../environments/native-ci/README.md).
Non-publishing renders remain available for previews.
Publication is [`.github/workflows/pages.yml`](../../.github/workflows/pages.yml)
and nothing else. It runs on every push to `main`, renders with the same
`--verify` pass, writes the `www.701.dev` CNAME and deploys to GitHub Pages.
Its `concurrency` group serializes publications and never cancels one in
flight, because a cancelled deploy can leave the site half-replaced.

The site is served at `www.701.dev`, and GitHub redirects `701.dev` to it.
That is the one thing the move simplified: pages.sr.ht served one site per
domain and could not redirect between them, so both had to be published
separately and either could go stale. Every page still declares which of the
two it wants to be found at, because a reader who arrives at the other one
should be told rather than guessed at.

The licensed code face is not in this repository and the workflow fetches it
from object storage before rendering. That fetch is fatal rather than
best-effort: a silent fallback publishes a site set in the wrong face, which
no word count can see.

The Pages job's existing SSH identity must be allowed to write the lock tag in
canonical `git.sr.ht`; read access to private fonts and write access to the
GitHub mirror do not by themselves establish that permission. Manual publishers
need the same canonical write permission and their configured Pages token.
The lock carries a unique owner object, candidate commit and job identifier; it
is operational coordination, never an acceptance tag or release designation.
A busy job waits up to five minutes plus bounded Git calls, then refuses.
Git calls, rendering and uploads have explicit timeouts.

Before activating this protocol, finish or cancel every older Pages job and
switch manual publishers to the new wrapper. Older scripts do not participate
in the lock. R4.91 records activation separately from local protocol tests.

A render or pre-upload approval failure releases its own lock with an exact
Git lease. An upload failure or timeout retains it: the client cannot prove
that the server stopped processing the request. A killed worker also leaves
its lock in place. Do not remove a lock merely because it is old. Inspect the
owning job and establish that no upload can still complete before recovering.
Fetch the current lock to inspect its owner and copy its full object identity:

```sh
git fetch git@git.sr.ht:~sinnfrei/landin refs/tags/ci/publication-lock
git cat-file tag FETCH_HEAD
```

After resolving that job and any uncertain server outcome, replace
`EXPECTED_LOCK_OBJECT` below with the inspected object's identity. The exact
lease prevents removal of a different worker's replacement lock. Then rerun
publication from current approved canonical main, repairing both domains.

```sh
git push --force-with-lease=refs/tags/ci/publication-lock:EXPECTED_LOCK_OBJECT \
    git@git.sr.ht:~sinnfrei/landin :refs/tags/ci/publication-lock
```

The rendered pages and the tarball are not committed: they are generated,
and a generated file in the history is a file that goes stale in the
history. `docs/site/site/` and the tarball are ignored.

## Verification

`--verify` reduces the source and the page to a multiset of words and reports
anything that comes out short, counting link targets as well as visible text.
A page that quietly lost a paragraph fails the build rather than going up.
`scripts/site.sh` always passes it.
Rewritten links retain their written source target in `data-source-href`.
Verification counts that target once in place of its rendered destination;
link-resolution tests independently check the destination. Missing visible
link text still fails the word check.

It reads the document's own region — `<main>` without the navigation, the bar
or the footer. Over the whole page it counted the furniture as content: the
sidebar names all sixteen documents and repeats every section title, so a
heading deleted from the body still balanced against the copy of it in the
navigation. It reported every word present while 79 citations had gone inert.

The front page holds no document, so it is checked against the pieces it is
built from instead: the tour's opening prose, the README's status line and the
three constructs it shows. Each of those readers now fails loudly rather than
returning nothing, because a blank section is exactly what a word count cannot
see.

## What a page carries, and what it fetches

The stylesheet, the script, the highlighting and the favicon are inlined, so
a page still reads when it is opened from disk or mailed. Four kinds of
resource sit beside the pages instead: three because they are read by
something other than the browser showing the document, and the faces
because of what they weigh.

| file | who asks for it | why not inlined |
|---|---|---|
| `og.png` | crawlers, and any chat window a link is pasted into | `og:image` is fetched by things that do not render SVG, and a `data:` URL is not a URL they can fetch |
| `icon-mono.svg` | Safari, for a pinned tab | Safari has never accepted a `data:` URL for `mask-icon`, so as one it simply did not appear |
| `apple-touch-icon.png` | iOS, for a home-screen icon | wants a raster |
| `fonts/*.woff2` | the browser's font loader, once for the whole site | thirty subsets are close to a megabyte, and a page carrying even the three an English reader needs would be 140 KB heavier for glyphs the next page would carry again |

The icons in the bar, the filter field and the copy buttons come from
[`assets/icons.py`](../../assets/README.md) as one inline `<symbol>` sprite
per page, referenced with `<use>`: a page carries 140 copy buttons, and as
inline copies their identical path data came to tens of kilobytes.

The faces are the one row of that table the page cannot do without and
still look like itself, so the declarations travel in the page even though
the files do not: `font-display:swap` is what makes a page whose faces
never arrived show the fallback stack immediately rather than after three
seconds of invisible text. Which of the thirty subsets a reader fetches is
the browser's decision, from each face's `unicode-range` — the tour asks
for three of them. `check.py` holds the other end of that: a document that
drifts outside the ranges fails the build rather than the page. A host
without the private checkout the code face lives in renders in the
fallback stack and says so. What refuses to publish that way is the
workflow: its font fetch is fatal rather than best-effort, because a
silent fallback ships a site set in the wrong face.

`llms.txt`, `llms-primer.txt` and `llms-full.txt` sit beside them for a
reader that is a program. The index is the `llms.txt` convention: a title, a
summary and annotated links, built from the same `DOCS` and `GUIDES` lists
the pages are, so a renamed page cannot leave a stale entry. The primer is
what the convention does not cover — the documents are a poor brief for
writing Landin, because the tour teaches a language wider than the kernel
the compiler enables and an agent reading only the tour writes programs
refused by name. It is generated by [`llms.py`](llms.py) from the sources
that decide each answer: the vocabulary and the grammar out of `spec.md`'s
own `landin-grammar` fences, every refused spelling out of the two tables
the compiler dispatches on, the codes out of the catalogue `check.py`
generates, and the invocation out of `examples.md`. Nothing in it is
transcribed, so nothing in it can disagree with what it describes. The full
file is the primer followed by the tour, the specification and the worked
programs; it is over a megabyte and mostly register, which is why the
primer is also written on its own.

`sitemap.xml` and `robots.txt` are written beside them, for the same kind of
reader. All five are generated by `render_html.py` from `assets/icon.svg` and
the document list — the rasteriser is in `assets/landin_icon.py`, which keeps
the build's one rule: nothing beyond the Python standard library. So does
`assets/fonts.py`, which reads each family's stylesheet and copies the
files it found in them.

The site has no separate build system or asset pipeline. The shared scanner is
a file in this repository rather than a package, and Pygments is a dependency
of the lexer that wraps it rather than of anything the pages need.
