# A diagnostic after non-ASCII text on its line, a two-byte character
# and one outside the basic plane, counted in the units negotiated:
# UTF-16, the default.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/e.ldn","languageId":"landin","version":1,"text":"f: (x: u8) -> (y: u8) =\n    -- caf\u00e9 \ud834\udd1e\n    y = x + \"\u00e9\ud834\udd1e\" + true\nend f\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/e.ldn","version":1,"diagnostics":[{"range":{"start":{"line":2,"character":12},"end":{"line":2,"character":17}},"severity":1,"code":"L0301","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0301"},"source":"refine","message":"a text literal cannot take the `u8` context required here\nnote: [0260]: a text literal takes one of the text views, including `[]u8`","relatedInformation":[{"location":{"uri":"file:///workspace/e.ldn","range":{"start":{"line":2,"character":8},"end":{"line":2,"character":17}}},"message":"required by this operator"}]},{"range":{"start":{"line":2,"character":20},"end":{"line":2,"character":24}},"severity":1,"code":"L0301","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0301"},"source":"refine","message":"this is `bool` and `u8` belongs here\nnote: [1890]: two types that must agree, and [0310] converts nothing between them","relatedInformation":[{"location":{"uri":"file:///workspace/e.ldn","range":{"start":{"line":2,"character":8},"end":{"line":2,"character":24}}},"message":"required by this operator"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
