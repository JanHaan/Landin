# The open buffer replaces a saved main.ldn in workspace/app.
# Where a name is declared: a routine in the same file, a local, a
# parameter, a type in an imported module found under the roots, and a
# declaring name, which is its own declaration.  A predeclared type, a
# keyword and a literal name nothing declared in source. rootUri may end in '/'.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file:///workspace/"}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\n--- The larger of two counts.\n--- Equal counts give the first.\nlarger: (a: u32, b: u32) -> (c: u32) =\n    c = if a < b then b else a end if\nend larger\n\nmain: () -> (status: i32) =\n    count := larger (2, 40)\n    corner: shapes.point = (x: 1, y: 2)\n    status = i32 (count + corner.x)\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":9,"character":13}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":11,"character":18}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":5,"character":11}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":10,"character":19}}}
-> {"jsonrpc":"2.0","id":6,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":4,"character":2}}}
-> {"jsonrpc":"2.0","id":7,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":4,"character":13}}}
-> {"jsonrpc":"2.0","id":8,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":5,"character":8}}}
-> {"jsonrpc":"2.0","id":9,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":9,"character":21}}}
-> {"jsonrpc":"2.0","id":10,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":4,"character":0},"end":{"line":4,"character":6}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":9,"character":4},"end":{"line":9,"character":9}}}}
<- {"jsonrpc":"2.0","id":4,"result":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":4,"character":9},"end":{"line":4,"character":10}}}}
<- {"jsonrpc":"2.0","id":5,"result":{"uri":"file:///workspace/lib/shapes/shapes.ldn","range":{"start":{"line":1,"character":7},"end":{"line":1,"character":12}}}}
<- {"jsonrpc":"2.0","id":6,"result":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":4,"character":0},"end":{"line":4,"character":6}}}}
<- {"jsonrpc":"2.0","id":7,"result":null}
<- {"jsonrpc":"2.0","id":8,"result":null}
<- {"jsonrpc":"2.0","id":9,"result":null}
<- {"jsonrpc":"2.0","id":10,"result":null}
exit: 0
