# The reading copies

`render_html.py` renders every document in the repository as a
self-contained HTML page and packages them for pages.sr.ht. The text files
are the specification; these pages are a reading of them.

## What it renders

| kind | sources | how it is read |
|---|---|---|
| the tour | `tour.txt` | as a literate document: every `[NNNN]` construct becomes a block holding its prose and the code that follows, and every citation becomes a link to the construct it names |
| the prototypes | `prototype-{1..4}-*.txt` | as listings, because in those the code is the argument, with the closing findings pulled out as entries |
| the guides | the Markdown documents named in `GUIDES` | as ordinary prose, with `[NNNN]` citations linked into the tour and links between documents rewritten to the pages they name |

Nothing here is a parser. The highlighter is a token scanner with a symbol
table collected from the document itself, and the Markdown reader covers the
subset the repository uses. It refuses a construct it does not recognise
rather than passing it through as text, because a table that renders as a row
of pipes is worse than a build that stops.

## Building and publishing

```sh
./scripts/site.sh              # render, verify, package
./scripts/site.sh --publish    # and upload to pages.sr.ht
```

Publishing needs [`hut`](https://sr.ht/~emersion/hut/) configured with a
token that has the `PAGES:RW` scope. `LANDIN_PAGES_DOMAIN` overrides the
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

The pages have no external references at all: the stylesheet, the script and
the highlighting are inlined, so one file can be opened from disk, mailed, or
served as it is. There is no build system, no asset pipeline, and no
dependency beyond the Python standard library.
