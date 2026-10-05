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

Build settings choose what `--target=`, `--level=`, `--option=` and
`--firmware-entry=` choose:

```json
{"roots": ["file:///home/me/landin"],
 "target": "cortex-m0",
 "level": "armv7-m",
 "firmwareEntry": "start"}
```

`target` is any name `--target=` takes: `linux-x86-64`, `linux-arm64`,
`darwin-arm64`, `cortex-m0` or `synthetic-32`. Both read one mapping, and
both default to the compiler's own host (D257). A server built for a host no
target describes checks for `synthetic-32` and says, through
`window/showMessage`, that a target has to be named.
`level` is a CPU feature level of that target's family, read after it as
`refine` reads it, and the target's default when absent. An
option must be declared in a reached source and named in lowercase letters,
digits and underscores. For example, `option enabled: bool = true` can be
overridden with `"options": {"enabled": "false"}`. Option values are strings
containing `true`, `false`, or signed decimal integer text that fits the
declared type. A value the server refuses is reported once, through
`window/showMessage`, and the rest are used.

`firmwareEntry` is a nonempty routine name for `cortex-m0`. When selected,
analysis checks the same entry shape as a firmware build and publishes
`L0502` at an invalid candidate, or at the first entry-module source if it
is missing. With no selection, analysis makes no firmware entry claim.

When several settings are refused, each error appears on its own line
in that one notification.

## What it answers

| request | answer |
|---|---|
| `textDocument/publishDiagnostics` | every diagnostic of each source of the module, after every change |
| `textDocument/definition` | where the name under the cursor is declared |
| `textDocument/hover` | what the name or expression under the cursor is, and its doc comment |
| `textDocument/formatting` | D252's layout, as edits |
| `textDocument/codeAction` | each fix of a diagnostic the range touches, as a quick fix; ranges have exclusive ends, while an empty range acts as a cursor position |

A diagnostic carries its catalogue code, a link to its explanation on the
reading copy of [`docs/diagnostics.md`](diagnostics.md), every secondary
label as related information, and each note at the end of its message. A
warning is a warning, and an error an error. A report with no place in any
source, such as a refused option, goes to `window/showMessage`.

Every source the module reads is published, so an error in a file the editor
has not opened is still shown, and one that is fixed is cleared. Closing the
last open file of a module clears sources only that module reported. Sources
also reported by another open module are reanalysed through that module.

When the editor reports a disk change through
`workspace/didChangeWatchedFiles`, the server rechecks every open module
whose last report read that path, even if that file is not open. It asks
clients that support dynamic watched-file registration to watch `**/*.ldn`.
An open buffer still takes precedence over the file on disk. Editors that
do not send watched-file notifications must arrange that notification to
refresh diagnostics after an external write.

A quick fix is preferred when it is exact: its rule decides the replacement,
and applying it keeps what the program means, so an editor may apply it
unasked. A likely fix, such as a respelling, is offered and not preferred.
A repair of a line that does not parse is likely, however few were found,
except for removing one copy of a token written twice in a row (D261).
The edits are the ones `refine`'s report carries, and one fix may change more
than one file.

Formatting ignores the editor's tab size and indentation preference: there is
one layout, D252's. A source that does not parse is not formatted, and the
answer is null; diagnostics report why when the server checks the changed
module.

Definitions and hover answer from the names and types the module was checked
with. A definition is the declared name itself, wherever it is written, and a
name with no declaration in source, such as a predeclared type, a keyword
or a literal, has none. Hover shows a routine, type or atom as its first line is
written, and any other name with its type as the checker's reports spell it,
then its doc comment: the run of `---` lines directly above a declaration
that begins its line [2000]. Over an expression, hover shows its type. Inside
a routine body that does not parse, both answer nothing.

When the only resolution errors are unresolved names, the server keeps the
bindings of other names and checks for hover types. Definition and hover still
answer in unaffected code. The unresolved name has no definition or type, and
diagnostics remain the same as a build's resolution diagnostics; any type
errors found during this extra editor check are not published until the names
are resolved.

Anything else is refused as the protocol says: a request the server does not
offer with MethodNotFound, one before `initialize` with ServerNotInitialized,
and one after `shutdown` with InvalidRequest. The server answers each request
before reading the next message, so it ignores `$/cancelRequest` notifications;
a late cancellation cannot affect a later request that reuses the ID. A
notification the server does not know is ignored.

## Past a syntax error

`refine` stops after the parse when a source does not parse. The server does
too, with one exception, D253's: when every syntax error lies inside an
eligible module routine body, the server checks the rest of the module using
stand-ins for those bodies. The routine's name and signature must have parsed.
Its body is ineligible if it belongs to a generic or a routine with an
inferred error set, is not closed by the `end` the parser matched, contains a
line beginning in column one, or is too short to hold the stand-in. While an
eligible body is half written, a type error in the routine below it is still
reported, and hover and definitions work everywhere else. Nothing is reported
inside the broken body except its own syntax errors, and no warning is given
until it parses. Any error outside an eligible body, such as one in a
signature, a type or a binding, leaves the module reported exactly as `refine`
reports it.

## Positions

A position is a line and a character within it, and the server counts
characters in UTF-8 bytes when the editor offers that, and in UTF-16 code
units otherwise, as the protocol's default. Lines end at LF, CR LF or a lone
CR [1750]. A byte that is not part of well-formed UTF-8 counts as one
character, as an editor that shows it as a replacement character counts it.
A position past the end of its line is the line's end.

A change is incremental: the server applies each range to the text it holds
without copying the text around it. Until the next analysis, retained string
payloads occupy no more than twice the visible text bytes, excluding slice
metadata, allocator overhead, checked compilations and temporary copies: a
stale copy is dropped when the document changes, and the text is copied out
once deletions outweigh it. A notification with any malformed change, or a
range that ends before it starts, is ignored whole.

## When it analyses

After every buffer or reported disk change, but only once the editor has
stopped sending: a burst of edits is analysed once, when no more input is
waiting, and a request is answered from the documents as they stand when it
arrives. Formatting answers from the held text before analysis; diagnostics
follow when input is idle. Checked modules stay available for hover, definition
and code actions, even when queries alternate between open modules. An open,
change, close or watched disk change discards the checked modules; diagnostics
then rebuild those affected, and later queries rebuild any others they need.
Distinct file URIs naming one path retain separate buffers. A query selects its
URI's buffer; switching to different bytes also discards checked modules,
including those importing that path.
The cache holds at most one compilation per open module,
and discards all of them when the session ends. This is a compilation-count
bound, not a fixed byte limit: separate entries may duplicate imports.

A sound entry source is parsed once per analysis, even if another source has
a broken body. The stand-in compilation takes unchanged syntax trees and
spacing from the original, then parses the stand-in source. The original
is released after transfer; the checked result may remain cached. The
transfer temporarily holds both compilations and increases peak memory.
The `memory` suite checks repeated sessions and edits for accumulation.

On Linux/glibc, `compiler/tests/server/measure_memory.py` compares two built
compilers over four modules sharing an import, two with broken bodies. It
records live allocated bytes at idle, peak resident memory, repeated and
alternating queries, twenty edits, a 256-edit burst, import open/close and
session teardown. The burst uses ranges when advertised and equivalent full
replacements otherwise. Live allocation and peak RSS include slice metadata
and allocator overhead; neither isolates a single cache.
Pass `--baseline`, `--refine` and `--output` to retain the comparison. The
probe is a temporary host library; it does not alter either compiler.

During one publication round with several stale modules, previously
published paths identify shared imports. Only those paths enter an
exact-text syntax cache, with held editor bytes snapshotted after pending
edits are flushed. The syntax cache is released at the end of the round;
checked module compilations may remain cached. Name resolution and checking
still run per module because their answers depend on its whole program and
options. Shared parses and any stand-in transfer temporarily overlap those
checked compilations; neither cache has a fixed byte bound.

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
| VS Code and its descendants | `highlight/textmate`'s client starts it; `landin.server.path` names another compiler, and `landin.server.target`, `landin.server.level` and `landin.server.options` set the analysis target and build options |
| Vim | `highlight/vim` registers it with vim-lsp when vim-lsp is installed |
| Sublime Text | `highlight/sublime/LSP-refine.sublime-settings`, for the LSP package |
| Kate | `highlight/kate/lsp-client.json`, for the LSP Client plugin |

The shipped Neovim configuration uses the nearest `.git` directory as its
root. Without Git it uses Neovim's working directory for files beneath that
directory, or the opened file's directory otherwise. Start Neovim in a
Git-free project's root so imports in sibling modules are visible. Neovim's
`vim.lsp.config` can override `root_dir` when a project needs other roots.

`highlight/test_adapters.py` holds every one of these to `refine lsp`, and
`highlight/test.sh` starts the server through Neovim and Emacs when
`LANDIN_REFINE` names a compiler. Nano and Notepad++ have no language
client, and JetBrains IDEs and Eclipse load the TextMate grammar alone.
