# Fuzz seed 500282 misspells a concept return source. The server must
# report its signature error and still answer the four editor requests.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/case.ldn","languageId":"landin","version":1,"text":"cell: type = struct\n    value: i32\nend cell\n\nlender: type = concept (t: type)\n    take: (self: ptr mut t, source: ptr mut cell)\n          -> (result: ptr mut cell from source)\nend lender\n\nreceiver: type = struct\n    held: cell\nend receiver\n\ntake_receiver: (self: ptr mut receiver, other: ptr mut cell)\n      -> (answer: ptr mut cell from self) =\n    _ = other\n    answer = addr self.val.held\nend take_receiver\n\nreceiver is lender (take: take_receiver)\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/case.ldn","version":2},"contentChanges":[{"text":"cell: type = struct\n    value: i32\nend cell\n\nlender: type = concept (t: type)\n    take: (self: ptr mut t, soure: ptr mut cell)\n          -> (result: ptr mut cell from source)\nend lender\n\nreceiver: type = struct\n    held: cell\nend receiver\n\ntake_receiver: (self: ptr mut receiver, other: ptr mut cell)\n      -> (answer: ptr mut cell from self) =\n    _ = other\n    answer = addr self.val.held\nend take_receiver\n\nreceiver is lender (take: take_receiver)\n"}]}}
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/case.ldn"},"position":{"line":0,"character":8}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/case.ldn"},"position":{"line":0,"character":17}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///workspace/case.ldn"},"options":{"tabSize":4,"insertSpaces":true}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///workspace/case.ldn"},"range":{"start":{"line":13,"character":49},"end":{"line":13,"character":49}},"context":{"diagnostics":[]}}}
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/case.ldn"}}}
-> {"jsonrpc":"2.0","id":6,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/case.ldn","version":2,"diagnostics":[{"range":{"start":{"line":6,"character":40},"end":{"line":6,"character":46}},"severity":1,"code":"L0339","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0339"},"source":"refine","message":"this `from` source is not a runtime parameter of the signature\nnote: [0790]: a returned reference names the parameters it derives from","relatedInformation":[{"location":{"uri":"file:///workspace/case.ldn","range":{"start":{"line":6,"character":14},"end":{"line":6,"character":46}}},"message":"the named return"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
<- {"jsonrpc":"2.0","id":3,"result":null}
<- {"jsonrpc":"2.0","id":4,"result":[{"range":{"start":{"line":13,"character":60},"end":{"line":14,"character":6}},"newText":"\n               "}]}
<- {"jsonrpc":"2.0","id":5,"result":[]}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/case.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":6,"result":null}
exit: 0
