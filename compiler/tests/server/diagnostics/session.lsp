# Diagnostics: a type error with its related information and note, and
# every other file of the module published empty; fixed by a change, which
# clears it; three changes in one burst, analysed once; then closing the
# last document clears every file the module reported on.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace","name":"w"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/main.ldn","languageId":"landin","version":1,"text":"twice: (x: u8) -> (y: u8) =\n    w := x + x\n    y = w + true\nend twice\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/main.ldn","version":2},"contentChanges":[{"text":"twice: (x: u8) -> (y: u8) =\n    w := x + x\n    y = w + 1\nend twice\n"}]}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/main.ldn","version":3},"contentChanges":[{"text":"twice: (x: u8) -> (y: u8) =\n    w := x + x\n    y = w + t\nend twice\n"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/main.ldn","version":4},"contentChanges":[{"text":"twice: (x: u8) -> (y: u8) =\n    w := x + x\n    y = w + tw\nend twice\n"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/main.ldn","version":5},"contentChanges":[{"text":"twice: (x: u8) -> (y: u8) =\n    w := x + x\n    y = w + twic\nend twice\n"}]}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/main.ldn"}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/helper.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":2,"character":12},"end":{"line":2,"character":16}},"severity":1,"code":"L0301","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0301"},"source":"refine","message":"this is `bool` and `u8` belongs here\nnote: [1890]: two types that must agree, and [0310] converts nothing between them","relatedInformation":[{"location":{"uri":"file:///workspace/main.ldn","range":{"start":{"line":2,"character":8},"end":{"line":2,"character":16}}},"message":"required by this operator"}]}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/helper.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/helper.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":5,"diagnostics":[{"range":{"start":{"line":2,"character":12},"end":{"line":2,"character":16}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`twic` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/helper.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
