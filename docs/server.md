# What `refine lsp` answers

`refine lsp` is a language server: an editor starts it, talks to it over
standard input and output, and gets back what `refine` would say about the
program a file belongs to, as the editor's own diagnostics, navigation, hover
text, formatting and quick fixes. It is the compiler's own stages, the same
loader and the same checks, so an editor never says something a build will
not. This page is derived: D253 in `spec.md` records the one way the server
reports more than `refine` does and what it was chosen over, and
`Landin.Server` is the implementation. Every capability below is pinned by a
scripted session under `compiler/tests/server/`, which the test program runs
against the server in-process and `native_session.py` runs through the
executable.

`refine lsp --stdio` is the same: an editor's language client often adds
`--stdio`, and the server accepts it. Any other argument after `lsp` is a
misuse, refused with status 2.

## Where a file belongs

A module is a directory [1410], so a file is analysed with every other `.ldn`
file in its own directory, as the entry module, and its imports are found
under the server's roots [1420] in order. The roots are, in this order of
preference:

| given | roots |
|---|---|
| `initializationOptions.roots`, a list of `file:` URIs | those, in order |
| the editor's workspace folders | each folder, in order |
| the editor's root URI | that directory |

The three sources accept a folder URI with or without a trailing slash;
both forms name the same root.

For this repository the root is the checkout, which is how the examples and
`core` are compiled: `refine --root=. examples/derived_hosted`.

A buffer the editor has not saved is read in place of the file: what the
server checks is what is on the screen, and the files around it are what is
on disk. A buffer with no file at all, such as an editor's untitled one, is
analysed alone, as `refine FILE` would analyse it, and so is every file when
there are no roots. `fixture.meta` means nothing to the server: a fixture
directory is analysed as the module its files make, which is not always what
the test program compiles.

Three more options choose what `--target=`, `--level=` and `--option=`
choose:

```json
{"roots": ["file:///home/me/landin"],
 "target": "cortex-m0",
 "level": "armv7-m",
 "options": {"board": "rp2040"}}
```

`target` is any name `--target=` takes: `linux-x86-64`, `linux-arm64`,
`darwin-arm64`, `cortex-m0` or `synthetic-32`. Both read one mapping, and
both default to the compiler's own host (D257). A server built for a host no
target describes checks for `synthetic-32` and says, through
`window/showMessage`, that a target has to be named.
`level` is a CPU feature level of that target's family, read after it as
`refine` reads it, and the target's default when absent. An
option is named in lowercase letters, digits and underscores. A value the
server refuses is reported once, through `window/showMessage`, and the rest
are used.

## What it answers

| request | answer |
|---|---|
| `textDocument/publishDiagnostics` | every diagnostic of each source of the module, after every change |
| `textDocument/definition` | where the name under the cursor is declared |
| `textDocument/hover` | what the name or expression under the cursor is, and its doc comment |
| `textDocument/formatting` | D252's layout, as edits |
| `textDocument/codeAction` | each fix of a diagnostic the range touches, as a quick fix |

A diagnostic carries its catalogue code, a link to its explanation on the
reading copy of [`docs/diagnostics.md`](diagnostics.md), every secondary
label as related information, and each note at the end of its message. A
warning is a warning, and an error an error. A report with no place in any
source, such as a refused option, goes to `window/showMessage`.

Every source the module reads is published, so an error in a file the editor
has not opened is still shown, and one that is fixed is cleared. Closing the
last open file of a module clears sources only that module reported. Sources
also reported by another open module are reanalysed through that module.

A quick fix is preferred when it is exact: its rule decides the replacement,
and applying it keeps what the program means, so an editor may apply it
unasked. A likely fix, such as a respelling, is offered and not preferred.
The edits are the ones `refine`'s report carries, and one fix may change more
than one file.

Formatting ignores the editor's tab size and indentation preference: there is
one layout, D252's. A source that does not parse is not formatted, and the
answer is null; its diagnostics already say why.

Definitions and hover answer from the names and types the module was checked
with. A definition is the declared name itself, wherever it is written, and a
name with no declaration in source, such as a predeclared type, a keyword
or a literal, has none. Hover shows a routine, type or atom as its first line is
written, and any other name with its type as the checker's reports spell it,
then its doc comment: the run of `---` lines directly above a declaration
that begins its line [2000]. Over an expression, hover shows its type. Inside
a routine body that does not parse, both answer nothing.

Anything else is refused as the protocol says: a request the server does not
offer with MethodNotFound, one before `initialize` with ServerNotInitialized,
one after `shutdown` with InvalidRequest, and one `$/cancelRequest` named
before it was answered with RequestCancelled. A notification the server does
not know is ignored.

## Past a syntax error

`refine` stops after the parse when a source does not parse. The server does
too, with one exception, D253's: when every error lies inside the bodies of
routines whose name and signature parsed, those bodies are stood in for and
the rest of the module is checked. So while a body is half written, a type
error in the routine below it is still reported, and hover and definitions
work everywhere else. Nothing is reported inside the broken body except its
own syntax errors, and no warning is given until it parses. Any other syntax
error, such as one in a signature, a type or a binding, leaves the module
reported exactly as `refine` reports it.

## Positions

A position is a line and a character within it, and the server counts
characters in UTF-8 bytes when the editor offers that, and in UTF-16 code
units otherwise, as the protocol's default. Lines end at LF, CR LF or a lone
CR [1750]. A byte that is not part of well-formed UTF-8 counts as one
character, as an editor that shows it as a replacement character counts it.
A position past the end of its line is the line's end.

## When it analyses

After every change, but only once the editor has stopped sending: a burst of
edits is analysed once, when no more input is waiting, and a request is
answered from the documents as they stand when it arrives. One compilation is
alive at a time and is given back whole before the next is made, so a long
session holds no more memory than a short one; the `memory` suite holds a
session of twenty edits to that.

## Limits

| | bound |
|---|---|
| a message's header block | 4 KiB |
| a message's body | 64 MiB; a longer one is skipped |
| JSON nesting | 64 levels |
| an integer in a message | within 2^53 - 1 |

A header that cannot be read, or input that ends inside a message, ends the
server with status 1, because there is no way to find where the next message
starts. A message that is not JSON is answered with ParseError and the server
goes on. `exit` after `shutdown` is status 0, and any other end is 1.

## In an editor

The packages under `highlight/` start the server, each where its editor
makes that a matter of configuration; [`highlight/README.md`](../highlight/README.md)
says how to install each. `refine` must be on the editor's path, as
`nix build .#refine` or a release asset puts it.

| editor | how it starts `refine lsp` |
|---|---|
| Neovim 0.11+ | `highlight/nvim/lsp/refine.lua`, enabled by the package when `refine` is on the path |
| Helix | `highlight/helix/languages.toml` names `refine` as Landin's language server |
| Emacs | `highlight/emacs/landin-mode.el` registers it with Eglot; `M-x eglot` starts it |
| Zed | `highlight/zed` names it as Landin's language server and finds `refine` on the path |
| VS Code and its descendants | `highlight/textmate`'s client starts it; `landin.server.path` names another compiler |
| Vim | `highlight/vim` registers it with vim-lsp when vim-lsp is installed |
| Sublime Text | `highlight/sublime/LSP-refine.sublime-settings`, for the LSP package |
| Kate | `highlight/kate/lsp-client.json`, for the LSP Client plugin |

`highlight/test_adapters.py` holds every one of these to `refine lsp`, and
`highlight/test.sh` starts the server through Neovim and Emacs when
`LANDIN_REFINE` names a compiler. Nano and Notepad++ have no language
client, and JetBrains IDEs and Eclipse load the TextMate grammar alone.
