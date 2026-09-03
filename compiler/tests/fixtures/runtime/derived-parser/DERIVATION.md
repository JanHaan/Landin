# Prototype 2 derivation

This fixture is the executable R3.70 derivative of `prototype-2-parser.md`.
The original remains the design record; the compiled implementation lives in
`examples/config_parser/lexer` and `examples/config_parser/parser`, while this
directory supplies the host boundary, input, expected diagnostics, and exit
oracle.

| Prototype evidence | Executable evidence |
|---|---|
| Y1: syntax faults are handled, world-dependent failures use the error channel | Three syntax faults are logged and recovered in order; a one-byte arena produces `mem.out_of_memory`, and a logger aimed at a closed descriptor produces `io.io_failed`. |
| Y4: the parser does not require loop labels or value breaks | R4.10 still owns loops, so scanner, recovery, and sequence walks use recursion without changing the workload's control boundaries. |
| Y5: variant cases are constructors | `parser.value` constructs text, integer and group cases, and the runtime exhaustively matches all three. |
| Y6: a recovery arm may produce a value or leave | Numeric overflow leaves its value arm after reporting, while the outer sequence resumes and retains later valid nodes. |
| Y7: allocated nodes are initialized through pointer `.val` | `parser.value` contains a recursive pointer list; each arena allocation is converted to `ptr mut value` and filled through `item.val`. |
| `config/lex` retains bad input and source positions | `lexer.next` emits bad-character and unterminated-string tokens with opaque `text.position` bounds. |
| The parser accepts an erased diagnostic capability | The identical parse body runs once with `diag.bounded(8)` and once with `diag.streaming`, both through `any diag.log`. |
| Nesting cleanup survives failure | The group arm registers `defer lower_depth(parser)` before recursive descent. |
