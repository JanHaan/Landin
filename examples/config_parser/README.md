# Derived configuration parser

A configuration lexer and parser that recovers from errors: the working
version of prototype 2, derived from `prototype-2-parser.md` without
changing that design record. This directory is the library; its hosted
entry, recorded input and expected output are in
`compiler/tests/fixtures/runtime/derived-parser`. From the repository root,
with `refine` installed:

```sh
refine run --root=. compiler/tests/fixtures/runtime/derived-parser \
    -- compiler/tests/fixtures/runtime/derived-parser/input.txt
```

It reports each syntax fault it recovered from, `E:36:expected '='` first,
and exits with status 42, the status the fixture expects.

`lexer/lexer.ldn` turns an ASCII configuration source into positioned tokens.
`parser/parser.ldn` builds an arena-backed recursive AST, reports recoverable
syntax faults through `any core/diag.log`, and propagates allocation or
diagnostic-delivery failures. Flat sequences, lexer byte scans and recovery
use loops; only bounded nested groups retain recursive walks.

`DERIVATION.md` in the fixture's directory maps the running evidence back to
prototype 2's findings. While working on the compiler,
`./scripts/dev-test.sh --fixture=runtime/derived-parser` builds it and runs
this fixture alone, checking the recorded output and the status; the run
reports `FILTERED` because it selects one fixture.

The complete program and its failure and recovery checks also run natively
on macOS arm64 in the six-profile hosted parity matrix, and native GDB and
LLDB inspect the same sources at none/off, size/auto and size/all; see the
[hosted parity guide](../../compiler/tests/darwin/README.md).
