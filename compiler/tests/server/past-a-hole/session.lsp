# D253: a body that does not parse is stood in for, so the type error in
# the routine after it is reported beside the syntax error, nothing is
# said inside the broken body, and no warning is given while it stands.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/h.ldn","languageId":"landin","version":1,"text":"sum: (x: u8, y: u8) -> (z: u8) =\n    z = x + undefined +\nend sum\n\ntwice: (x: u8) -> (y: u8) =\n    mut w := sum (x, x)\n    y = w + true\nend twice\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/h.ldn","version":1,"diagnostics":[{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},"severity":1,"code":"L0102","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0102"},"source":"refine","message":"an expression belongs after this operator\nnote: [1820]: every binary operator has a right operand","relatedInformation":[{"location":{"uri":"file:///workspace/h.ldn","range":{"start":{"line":1,"character":22},"end":{"line":1,"character":23}}},"message":"the operator"}]},{"range":{"start":{"line":6,"character":12},"end":{"line":6,"character":16}},"severity":1,"code":"L0301","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0301"},"source":"refine","message":"this is `bool` and `u8` belongs here\nnote: [1890]: two types that must agree, and [0310] converts nothing between them","relatedInformation":[{"location":{"uri":"file:///workspace/h.ldn","range":{"start":{"line":6,"character":8},"end":{"line":6,"character":16}}},"message":"required by this operator"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
