# Highlighting Landin

One scanner, several renderings. `landin_highlight.py` holds the lexical
surface of the language — the reserved words, the token shapes, and the
little state a line cannot decide on its own — and everything that colours
Landin is a rendering of that file rather than another scanner that drifts
away from it.

| artifact | feeds | state |
|---|---|---|
| `landin_highlight.py` | the scanner itself; standard library only, no output format | here |
| `landin_pygments.py` | Pygments: sourcehut's blob view, Sphinx, MkDocs, `pygmentize` | here |
| `docs/site/render_html.py` | the reading copies at sinnfrei.srht.site, as HTML spans | imports the scanner |
| a TextMate grammar | VS Code and its forks, Sublime Text, `bat` and other syntect tools, Shiki | planned |
| a tree-sitter grammar | Neovim, Helix, Zed, Emacs 29+, and folds, indent and textobjects | planned |

The two grammars are the reason this directory exists rather than the
scanner living under `docs/site/`: the reading copies are a consumer of
the language's highlighting, not the owner of it.

## What the scanner is not

It is not a parser. It is a token scanner with a symbol table collected
from the file itself, which is how a name the file declares reads the same
everywhere it is used — the whole reason the Pygments lexer takes a file
rather than a line.

What it cannot do is tell the `set` of `[0410]` from a variable called
`set`. The contextual words — `from`, `of`, `at`, `set`, `range`, `option`,
`link`, `align` — are coloured by position, and some of them will be
coloured wrongly. A regex cannot fix that; a tree-sitter grammar can, and
an editor talking to `refine` eventually will. Until then the scanner is
deliberately the cheap answer, and being wrong about `at` in an unusual
position is a smaller cost than a second scanner to maintain.

`check.py` keeps its own list of reserved words on purpose. That one is
about legality and this one is about colour, they have drifted apart
before, and the comment at the top of `check.py` explains why they are
allowed to.

## The Pygments lexer

Installed, it registers itself so Pygments finds it by name, by alias, and
by the `.ldn` suffix:

```sh
pip install ./highlight
pygmentize -l landin file.ldn
python3 -m landin_pygments file.ldn     # or straight to the terminal
```

Pygments is a dependency of the lexer, never of the scanner, so
`docs/site/render_html.py` keeps rendering the documentation with nothing
but the standard library.

Nothing installs this automatically, and the package is unreleased: the
version in `pyproject.toml` says only that, and `ROADMAP.md` decides when
it becomes a claim.
