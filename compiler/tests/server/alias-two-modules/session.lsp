# Two modules are each open under two URIs of one path, one text
# importing a module the other does not.  A module's report is settled
# once after each of its documents has published, so the import both
# share is not dropped and restored in turn, which made each module
# stale the other without end.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":["file:///workspace"]}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app1/main.ldn","languageId":"landin","version":1,"text":"one: u8 = 1\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://localhost/workspace/app1/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\nmain: () -> (status: i32) =\n    status = shapes.area (2, 3)\nend main\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app2/main.ldn","languageId":"landin","version":1,"text":"one: u8 = 1\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://localhost/workspace/app2/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\nmain: () -> (status: i32) =\n    status = shapes.area (2, 3)\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/app1/main.ldn","version":2},"contentChanges":[{"text":"two: u8 = 2\n"}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://localhost/workspace/app1/main.ldn"},"position":{"line":3,"character":21}}}
-> {"jsonrpc":"2.0","id":3,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app1/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file://localhost/workspace/app1/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app2/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file://localhost/workspace/app2/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app1/main.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file://localhost/workspace/app1/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\npublic area: (w: i32, h: i32) -> (r: i32) = w * h end area\n```"},"range":{"start":{"line":3,"character":20},"end":{"line":3,"character":24}}}}
<- {"jsonrpc":"2.0","id":3,"result":null}
exit: 0
