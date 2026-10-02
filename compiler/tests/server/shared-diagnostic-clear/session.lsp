# Two open entry modules read one broken import. Closing one must leave
# the shared diagnostic owned by the survivor, then closing it clears it.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":["file:///workspace"]}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/first/main.ldn","languageId":"landin","version":1,"text":"import shared\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/second/main.ldn","languageId":"landin","version":1,"text":"import shared\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/second/main.ldn"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/first/main.ldn"}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/first/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/shared/shared.ldn","diagnostics":[{"range":{"start":{"line":0,"character":16},"end":{"line":0,"character":25}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`undefined` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/second/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/shared/shared.ldn","diagnostics":[{"range":{"start":{"line":0,"character":16},"end":{"line":0,"character":25}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`undefined` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/second/main.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/first/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/shared/shared.ldn","diagnostics":[{"range":{"start":{"line":0,"character":16},"end":{"line":0,"character":25}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`undefined` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/first/main.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/shared/shared.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
