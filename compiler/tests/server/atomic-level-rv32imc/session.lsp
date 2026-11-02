# D690: the server's level decides RV32's read-modify-writes as `refine check`'s
# --level does: at rv32imc compiler.atomic_add is refused with the message
# negative/atomic-builtin-rv32imc pins, and the load and store beside it are not.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"target":"rv32","level":"rv32imc"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/main.ldn","languageId":"landin","version":1,"text":"f: (p: ptr mut u32) -> none =\n    compiler.atomic_store(p, compiler.atomic_load(p, compiler.acquire) +% 1,\n                          compiler.release)\n    _ = compiler.atomic_add(p, 1, compiler.relaxed)\nend f\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":8},"end":{"line":3,"character":27}},"severity":1,"code":"L0344","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0344"},"source":"refine","message":"memory operation unavailable at rv32imc; a build at rv32imac admits it\nnote: [1620]/D227: a memory intrinsic's arguments state its whole contract, and each must be one the intrinsic takes","relatedInformation":[{"location":{"uri":"file:///workspace/main.ldn","range":{"start":{"line":3,"character":8},"end":{"line":3,"character":51}}},"message":"this memory operation"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
