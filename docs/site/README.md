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
inline in `currentColor` so it follows the theme with no second drawing, and
the front page wears the plated one. All four are `data:` URLs or inline
fragments, because a page here has no external references.
The Markdown reader covers the subset the repository uses, and refuses a
construct it does not recognise rather than passing it through as text,
because a table that renders as a row of pipes is worse than a build that
stops.

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
with a token that has the `PAGES:RW` scope. `LANDIN_PAGES_DOMAIN` overrides the
domain; `hut pages publish -s //some/path` moves the site into a
subdirectory if the root is wanted for something else.

The rendered pages and the tarball are not committed: they are generated,
and a generated file in the history is a file that goes stale in the
history. `docs/site/site/` and the tarball are ignored.

## Verification

`--verify` reduces both the source and the page to a multiset of words and
reports anything that comes out short, counting link targets as well as
visible text. A page that quietly lost a paragraph fails the build rather
than going up. `scripts/site.sh` always passes it.

## What is deliberately not here

The pages have no external references at all: the stylesheet, the script, the
highlighting and the icon are inlined, so one file can be opened from disk,
mailed, or served as it is. There is no build system, no asset pipeline, and
no dependency beyond the Python standard library — the shared scanner is a file
in this repository, not a package, and Pygments is a dependency of the lexer
that wraps it rather than of anything the pages need.
