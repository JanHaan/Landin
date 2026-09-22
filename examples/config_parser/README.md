# Derived configuration parser

This is the executable library portion of ROADMAP R3.70, derived from
`prototype-2-parser.md` without changing that design record.

`lexer/lexer.ldn` turns an ASCII configuration source into positioned tokens.
`parser/parser.ldn` builds an arena-backed recursive AST, reports recoverable
syntax faults through `any core/diag.log`, and propagates allocation or
diagnostic-delivery failures. Its walks use recursion because loops and full
UTF-8 text remain R4.10 work.

The hosted entry, recorded input and exact output oracle are in
`compiler/tests/fixtures/runtime/derived-parser`. `DERIVATION.md` there maps
the running evidence back to prototype 2's findings.

The complete derivative and its failure/recovery oracles also run on native
Darwin arm64 in R5.50's shared six-profile runtime matrix. Native GDB and LLDB
inspect the same complete sources at none/off, size/auto and size/all; see the
[hosted parity guide](../../compiler/tests/darwin/README.md). The retired native acceptance
required the same committed source archive on both hosted targets; nothing
checks that now.
