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
| `docs/site/render_html.py` | the reading copies at www.701.dev, as HTML spans | imports the scanner |
| `textmate/` | VS Code, VSCodium, Cursor, Windsurf, TextMate, Shiki and `bat`; importable by JetBrains IDEs | generated grammar plus extension |
| `tree-sitter/` | the incremental concrete-syntax grammar and canonical queries | generated C parser and corpus |
| `nvim/`, `helix/`, `zed/` | tree-sitter editor packages | ready-to-install adapters |
| `vim/`, `emacs/` | native Vim and Emacs packages, including Emacs tree-sitter mode | ready-to-install adapters |
| `sublime/`, `visual-studio/`, `jetbrains/` | TextMate consumers with native packaging or installation instructions | ready-to-install adapters |
| `eclipse/` | Eclipse Generic Editor through its TM4E integration | importable adapter |
| `notepad-plus-plus/`, `nano/`, `kate/` | widely used and lightweight native syntax definitions | generated adapters |

The two grammars are the reason this directory exists rather than the
scanner living under `docs/site/`: the reading copies are a consumer of
the language's highlighting, not the owner of it.

## Installing editor and IDE support

Clone or download the repository, then use the package for the editor in the
table. Every package associates the `.ldn` suffix with Landin; the structural
packages also provide editor features such as indentation, folds, text
objects or an outline where their host supports them.

| editor or tool | package | installation |
|---|---|---|
| Zed | `highlight/zed` | Open Extensions, choose **Install Dev Extension**, and select this directory. |
| VS Code, VSCodium, Cursor, Windsurf | `highlight/textmate` | Run `npm install`, `npm run package:check`, and `npx vsce package`; then choose **Install from VSIX** in the editor. |
| Neovim | `highlight/nvim` | Run `make -C highlight/nvim`, then add the directory to `runtimepath` or use it as a local plugin. |
| Helix | `highlight/helix` | Merge `languages.toml`, copy the query directory into the matching runtime directory, then run `hx --grammar fetch` and `hx --grammar build`. |
| Vim | `highlight/vim` | Copy the directory to `~/.vim/pack/landin/start/landin`, or point a package manager at it. |
| Emacs | `highlight/emacs` | Put the directory on `load-path` and require `landin-mode`; on Emacs 29+, run `M-x landin-ts-install-grammar` to enable the tree-sitter mode. |
| Sublime Text | `highlight/sublime` | Copy the directory to `Packages/Landin`. |
| Visual Studio | `highlight/visual-studio` | Run `install.ps1` in PowerShell, then reopen the file or restart Visual Studio. |
| JetBrains IDEs | `highlight/textmate` | Enable **TextMate Bundles**, import this directory as a bundle, and map `*.ldn` if necessary. |
| Eclipse | `highlight/textmate` | With TM4E installed, import `syntaxes/landin.tmLanguage.json` and open `.ldn` files in the Generic Editor. |
| Notepad++ | `highlight/notepad-plus-plus` | From **Language**, open **User Defined Language** and import `Landin.xml`, or copy it to the user-defined-language directory. |
| Kate | `highlight/kate/landin.xml` | Install the XML file as a user syntax-highlighting definition. |
| Nano | `highlight/nano/landin.nanorc` | Include the syntax file from the user's `nanorc`. |
| Pygments, Sphinx, MkDocs | `highlight` | Run `pip install ./highlight`; the lexer registers the `landin` and `ldn` aliases and the `.ldn` suffix. |

The TextMate grammar can also be loaded directly by TextMate, Shiki and
`bat`. The package-specific README in each directory records any additional
host details. These are repository packages rather than editor-marketplace
releases, so installation is deliberately local for now.

## What the scanner is not

It is not a parser. It is a token scanner with a symbol table collected
from the file itself, which is how a name the file declares reads the same
everywhere it is used — the whole reason the Pygments lexer takes a file
rather than a line.

What it cannot do is tell the `set` of `[0410]` from a variable called
`set`. The contextual words — `from`, `of`, `at`, `set`, `range`, `option`,
`link`, `align` — are coloured by position, and some of them will be
coloured wrongly. A regex cannot fix that. The tree-sitter grammar handles
the enabled structural surface, including contextual `lenof` and `of`, while
remaining deliberately non-normative and tolerant enough for incomplete
editor buffers.

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

## Generating and checking packages

The TextMate, Vim, Nano, Kate and copied query files are deterministic
renderings. Regenerate or verify them with:

```sh
python3 highlight/generate.py
python3 highlight/generate.py --check
./highlight/test.sh                 # isolated: only highlight/ fixtures
./highlight/test.sh --integration   # also parse compiler and core fixtures
```

The default test never builds or invokes the compiler. Its mandatory path is
standard-library-only: it scans the lexical fixture, exercises the TextMate
patterns, parses every manifest and generated format, checks file associations
and verifies copied artifacts byte for byte. If Pygments, tree-sitter, Vim,
Neovim, Emacs, Lua or PowerShell are installed, it also runs their native
smoke checks; absent optional tools are reported and skipped. Neovim's parser
is compiled into a temporary directory rather than the product tree. With
`npm install` run in `highlight/textmate`, the suite also tokenizes the fixture
through VS Code's actual TextMate engine and builds a temporary valid VSIX.

To exercise Pygments without installing anything into the repository, create
a temporary virtual environment, `pip install -e ./highlight`, and run the
suite with that environment's `python3` first on `PATH`.

`--integration` adds the 392 positive, runtime and `core/*` sources to the
tree-sitter pass. It remains useful as language-wide evidence, but is not
needed to test or package the highlighters themselves. Each editor directory
contains the shortest installation path for that editor.
