# Formatting is D252's layout as edits, whatever the editor's options;
# a formatted source gets none, and one that does not parse gets null,
# since its diagnostics say why.  A document that is not open is refused.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/f.ldn","languageId":"landin","version":1,"text":"f:  (x: u8) -> (y: u8) =\n      y = x\nend f\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///workspace/f.ldn"},"options":{"tabSize":2,"insertSpaces":false}}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/f.ldn","version":2},"contentChanges":[{"text":"f: (x: u8) -> (y: u8) =\n    y = x\nend f\n"}]}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///workspace/f.ldn"},"options":{"tabSize":2,"insertSpaces":false}}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/f.ldn","version":3},"contentChanges":[{"text":"f: (x: u8) -> (y: u8) =\n    y = (x\nend f\n"}]}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///workspace/f.ldn"},"options":{"tabSize":2,"insertSpaces":false}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///workspace/closed.ldn"},"options":{"tabSize":2,"insertSpaces":false}}}
-> {"jsonrpc":"2.0","id":6,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/f.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":[{"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":4}},"newText":" "},{"range":{"start":{"line":0,"character":24},"end":{"line":1,"character":6}},"newText":"\n    "}]}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/f.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":3,"result":[]}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/f.ldn","version":3,"diagnostics":[{"range":{"start":{"line":1,"character":10},"end":{"line":1,"character":10}},"severity":1,"code":"L0103","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0103"},"source":"refine","message":"a parenthesised expression is closed with `)`\nnote: [1810]: a parenthesized expression is one primary expression","relatedInformation":[{"location":{"uri":"file:///workspace/f.ldn","range":{"start":{"line":1,"character":8},"end":{"line":1,"character":9}}},"message":"opened here"}]}]}}
<- {"jsonrpc":"2.0","id":4,"result":null}
<- {"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"the document is not open"}}
<- {"jsonrpc":"2.0","id":6,"result":null}
exit: 0
