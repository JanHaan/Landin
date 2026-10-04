# Past a broken body, names and types answer everywhere else: the call
# to the broken routine is defined and its signature described, while
# inside the body, where the stand-in is not what was written, definition
# and hover answer nothing.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/held.ldn","languageId":"landin","version":1,"text":"sum: (x: u8, y: u8) -> (z: u8) =\n    w := x\n    z = w +\nend sum\n\ntwice: (x: u8) -> (y: u8) =\n    y = sum (x, x)\nend twice\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/held.ldn"},"position":{"line":6,"character":9}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/held.ldn"},"position":{"line":6,"character":9}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/held.ldn"},"position":{"line":6,"character":4}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/held.ldn"},"position":{"line":2,"character":8}}}
-> {"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/held.ldn"},"position":{"line":1,"character":4}}}
-> {"jsonrpc":"2.0","id":7,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/held.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":3}},"severity":1,"code":"L0102","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0102"},"source":"refine","message":"an expression belongs after this operator\nnote: [1820]: every binary operator has a right operand","relatedInformation":[{"location":{"uri":"file:///workspace/held.ldn","range":{"start":{"line":2,"character":10},"end":{"line":2,"character":11}}},"message":"the operator"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":{"uri":"file:///workspace/held.ldn","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"contents":{"kind":"markdown","value":"```landin\nsum: (x: u8, y: u8) -> (z: u8)\n```"},"range":{"start":{"line":6,"character":8},"end":{"line":6,"character":11}}}}
<- {"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"```landin\ny: u8\n```"},"range":{"start":{"line":6,"character":4},"end":{"line":6,"character":5}}}}
<- {"jsonrpc":"2.0","id":5,"result":null}
<- {"jsonrpc":"2.0","id":6,"result":null}
<- {"jsonrpc":"2.0","id":7,"result":null}
exit: 0
