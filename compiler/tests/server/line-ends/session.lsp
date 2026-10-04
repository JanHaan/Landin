# CR LF and lone CR line ends: lines are counted at each, and a column
# never counts the CR.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/c.ldn","languageId":"landin","version":1,"text":"f: (x: u8) -> (y: u8) =\r\n    w := x\r    y = w + true\r\nend f\r\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/c.ldn","version":1,"diagnostics":[{"range":{"start":{"line":2,"character":12},"end":{"line":2,"character":16}},"severity":1,"code":"L0301","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0301"},"source":"refine","message":"this is `bool` and `u8` belongs here\nnote: [1890]: two types that must agree, and [0310] converts nothing between them","relatedInformation":[{"location":{"uri":"file:///workspace/c.ldn","range":{"start":{"line":2,"character":8},"end":{"line":2,"character":16}}},"message":"required by this operator"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
