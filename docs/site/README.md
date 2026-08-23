# The reading copies

`render_html.py` renders every document in the repository as a
self-contained HTML page and packages them for pages.sr.ht. The text files
are the specification; these pages are a reading of them.

## What it renders

| kind | sources | how it is read |
|---|---|---|
| the tour | `tour.md` | as a literate document: every `[NNNN]` construct becomes a block holding its prose and the code that follows, and every citation becomes a link to the construct it names |
| the prototypes | `prototype-{1..4}-*.txt` | as listings, because in those the code is the argument, with the closing findings pulled out as entries |
| the guides | the Markdown documents named in `GUIDES` | as ordinary prose, with `[NNNN]` citations linked into the tour and links between documents rewritten to the pages they name |

Nothing here is a parser, and the highlighting is not written here. It comes
from [`highlight/landin_highlight.py`](../../highlight/README.md), the one
scanner the Pygments lexer reads as well, so the pages cannot colour the
language differently from every other tool that highlights it; this file
turns the classes it emits into spans and links the citations in comments.

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
./scripts/site.sh --publish    # and upload to pages.sr.ht
```

The CI gate runs the second command itself, as its last task and only from
`main`: every push that changes a document republishes the pages it is read
on. `.build.yml` asks builds.sr.ht for a `pages.sr.ht/PAGES:RW` token for
that one job, so no long-lived credential is stored anywhere. Publishing by
hand is for a preview, or for putting the site back after something went out
that should not have.

Publishing by hand needs [`hut`](https://sr.ht/~emersion/hut/) configured
with a token that has the `PAGES:RW` scope. The site goes to
`www.701.dev` and then to `701.dev`: pages.sr.ht serves one site per domain
and cannot redirect between them, so both are published rather than one of
them going stale. `LANDIN_PAGES_DOMAIN` and `LANDIN_PAGES_ALIAS` override
each, and an empty `LANDIN_PAGES_ALIAS` publishes only the first.
`hut pages publish -s //some/path` moves the site into a subdirectory if
the root is wanted for something else.

The rendered pages and the tarball are not committed: they are generated,
and a generated file in the history is a file that goes stale in the
history. `docs/site/site/` and the tarball are ignored.

## Verification

`--verify` reduces the source and the page to a multiset of words and reports
anything that comes out short, counting link targets as well as visible text.
A page that quietly lost a paragraph fails the build rather than going up.
`scripts/site.sh` always passes it.

It reads the document's own region — `<main>` without the navigation, the bar
or the footer. Over the whole page it counted the furniture as content: the
sidebar names all fifteen documents and repeats every section title, so a
heading deleted from the body still balanced against the copy of it in the
navigation. It reported every word present while 79 citations had gone inert.

The front page holds no document, so it is checked against the pieces it is
built from instead: the tour's opening prose, the README's status line and the
three constructs it shows. Each of those readers now fails loudly rather than
returning nothing, because a blank section is exactly what a word count cannot
see.

## What a page carries, and what it fetches

The stylesheet, the script, the highlighting and the favicon are inlined, so
a page still reads when it is opened from disk or mailed. Three resources sit
beside the pages instead, because they are read by something other than the
browser showing the document:

| file | who asks for it | why not inlined |
|---|---|---|
| `og.png` | crawlers, and any chat window a link is pasted into | `og:image` is fetched by things that do not render SVG, and a `data:` URL is not a URL they can fetch |
| `icon-mono.svg` | Safari, for a pinned tab | Safari has never accepted a `data:` URL for `mask-icon`, so as one it simply did not appear |
| `apple-touch-icon.png` | iOS, for a home-screen icon | wants a raster |

`sitemap.xml` and `robots.txt` are written beside them, for the same kind of
reader. All five are generated by `render_html.py` from `assets/icon.svg` and
the document list — the rasteriser is in `assets/landin_icon.py`, which keeps
the build's one rule: nothing beyond the Python standard library.

There is still no build system and no asset pipeline. The shared scanner is a
file in this repository rather than a package, and Pygments is a dependency of
the lexer that wraps it rather than of anything the pages need.
