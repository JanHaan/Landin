# tree-sitter-landin

This is the incremental concrete-syntax grammar for Landin editor tooling. It
is a checked transcription of the enabled kernel in `../../spec.md`, not a
second language authority. The parser intentionally accepts a little extra
around contextual `lenof` and `of` so an incomplete editor buffer remains
useful; the compiler and normative grammar decide legality.

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
