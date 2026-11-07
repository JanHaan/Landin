# Derived configuration parser

This is the executable library portion of the first complete derived
program, derived from `prototype-2-parser.md` without changing that design
record.

`lexer/lexer.ldn` turns an ASCII configuration source into positioned tokens.
`parser/parser.ldn` builds an arena-backed recursive AST, reports recoverable
syntax faults through `any core/diag.log`, and propagates allocation or
diagnostic-delivery failures. Flat sequences, lexer byte scans and recovery
use loops; only bounded nested groups retain recursive walks.

The hosted entry, recorded input and exact output oracle are in
`compiler/tests/fixtures/runtime/derived-parser`. `DERIVATION.md` there maps
the running evidence back to prototype 2's findings.

This directory has no entry point of its own. To run the hosted entry over
its recorded input, use the pinned development environment at the
repository root:

```sh
./scripts/dev-test.sh --fixture=runtime/derived-parser
```

The harness builds the compiler, passes the fixture's `input.txt` as the
program's argument, and checks the recorded output and the expected
status, 42. The run reports `FILTERED` because it selects one fixture.

The complete derivative and its failure/recovery oracles also run on native
Darwin arm64 in the shared six-profile hosted parity runtime matrix. Native GDB and LLDB
inspect the same complete sources at none/off, size/auto and size/all; see the
[hosted parity guide](../../compiler/tests/darwin/README.md). The retired native acceptance
required the same committed source archive on both hosted targets; nothing
checks that now.
