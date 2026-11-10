# A file name may hold a line feed.  The server keeps what a module
# published as whole paths, so closing such a buffer clears its own
# URI and nothing else, and the session goes on.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/a%0Ab.ldn","languageId":"landin","version":1,"text":"aa: u8 = missing\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/a%0Ab.ldn"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/plain.ldn","languageId":"landin","version":1,"text":"bb: u8 = 2\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/a%0Ab.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":16}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`missing` is not declared in any scope this reaches\nnote: [1860]: a name used here needs a declaration in scope; check its spelling"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/a%0Ab.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/plain.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
