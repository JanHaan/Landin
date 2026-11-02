# D690: the same program at rv32imac, whose `a` admits the read-modify-write,
# draws no diagnostic, so the refusal at rv32imc is the level's.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"target":"rv32","level":"rv32imac"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/main.ldn","languageId":"landin","version":1,"text":"f: (p: ptr mut u32) -> none =\n    compiler.atomic_store(p, compiler.atomic_load(p, compiler.acquire) +% 1,\n                          compiler.release)\n    _ = compiler.atomic_add(p, 1, compiler.relaxed)\nend f\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
