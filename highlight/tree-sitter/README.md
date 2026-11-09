# tree-sitter-landin

This is the incremental concrete-syntax grammar for Landin editor tooling. It
is a checked transcription of the enabled language in `../../spec.md`, not a
second language authority. The parser intentionally accepts a little extra
around contextual `lenof` and `of` so an incomplete editor buffer remains
useful; its C-boundary rules keep `c`, `layout`, `link`, and `symbol` as
identifiers outside their annotated positions. Where the lexer may offer a
contextual word as its own token, because a declaration, a label or a
parameter list could begin there, `distinct`, `link`, `option`, `as` and
`caller` are still read as names: in an expression, as a declaration's name, as a statement's label,
after `end` and as a field's or an argument's label. The language reserves
only the words [1760] lists. The compiler and normative grammar decide legality.

With Node.js available:

```sh
npm install
npm run generate
export TREE_SITTER_LIBDIR="$(mktemp -d)"   # a fresh parser library; see below
npm test
npx tree-sitter highlight ../tests/structural.ldn
```

A change to `grammar.js` or `queries/` takes two commits, because Helix, Zed
and Emacs fetch this grammar by commit: commit the change, then run
`python3 ../grammar_pin.py` and commit the three manifests it rewrites on
their own ([`../README.md`](../README.md#installing-editor-and-ide-support)).
Until then `../test.sh` gives its other verdicts and fails on the pins.

The generated C parser is checked in so consumers do not need Node.js. The
external scanner handles nested block comments and the three tokens beginning
with `-`. `queries/` is canonical; `../generate.py` copies the relevant
queries into each editor package and checks that they have not drifted.

The support headers under `src/tree_sitter/` are byte-identical copies from
the pinned Tree-sitter v0.26.9 sources: [`alloc.h`](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/crates/generate/src/templates/alloc.h),
[`array.h`](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/crates/generate/src/templates/array.h)
and [`parser.h`](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/lib/src/parser.h).
Their [MIT notice](src/tree_sitter/LICENSE) preserves the
[upstream license](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/LICENSE).
Keep that notice beside the headers when distributing this parser or
regenerating its support files. Landin-authored grammar, queries and scanner
retain the repository's dual license.

## The CLI runs a cached parser

`tree-sitter parse`, `test`, `highlight` and `query` do not run the parser in
`src/`. They compile `src/parser.c` and `src/scanner.c` into a shared library,
`$XDG_CACHE_HOME/tree-sitter/lib/landin.so` (`~/.cache/tree-sitter/lib/`
by default), and load that, compiling again only when a source file is newer
than the library. A grammar checked out, unpacked or copied with older
timestamps therefore runs whatever grammar was compiled there last, without a
word. `--rebuild` does not settle it: with the pinned 0.26.9 CLI and no C
compiler on `PATH`, `parse --rebuild` keeps the cached library and still exits
0, though a compiler named by `CC` that cannot run is an error. Give
each run a library directory of its own, which the CLI must compile into and
which fails when it cannot:

```sh
TREE_SITTER_LIBDIR="$(mktemp -d)" npx tree-sitter parse ../tests/structural.ldn
```

`../test.sh` does the same with a fresh `XDG_CACHE_HOME`, and refuses when
the CLI left no library there, so its verdicts are always about the parser in
this checkout. Run the CLI from this directory: it
finds the grammar in the current directory, since no parser directories are
configured.
