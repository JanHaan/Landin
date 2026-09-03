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
