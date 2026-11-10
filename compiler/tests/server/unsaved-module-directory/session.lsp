# A buffer in a directory that is not on disk yet is the first source
# of a new module: it is analysed as that module, and an import of the
# module finds it (D1070).
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":["file:///workspace"]}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/fresh/main.ldn","languageId":"landin","version":1,"text":"aa: u8 = missing\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lib/shapes/shapes.ldn","languageId":"landin","version":1,"text":"public area: (w: i32, h: i32) -> (r: i32) = w * h end area\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\nmain: () -> (status: i32) =\n    status = shapes.area (2, 3)\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/fresh/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":16}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`missing` is not declared in any scope this reaches\nnote: [1860]: a name used here needs a declaration in scope; check its spelling"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
