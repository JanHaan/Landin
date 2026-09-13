# tree-sitter-landin

This is the incremental concrete-syntax grammar for Landin editor tooling. It
is a checked transcription of the enabled kernel in `../../spec.md`, not a
second language authority. The parser intentionally accepts a little extra
around contextual `lenof` and `of` so an incomplete editor buffer remains
useful; its C-boundary rules keep `c`, `layout`, `link`, and `symbol` as
identifiers outside their annotated positions. The compiler and normative
grammar decide legality.

With Node.js available:

```sh
npm install
npm run generate
npm test
tree-sitter highlight ../tests/structural.ldn
```

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
