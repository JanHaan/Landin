# D433: a `ptr` arm's `sink` binding.  The server parses `ptr (sink held)`,
# hovers the binding as the plain pointer it is, and reports the second
# use of the sunk binding as the checker does.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace/","name":"workspace"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"absent: atom\nnode: type = struct\n    value: i32\nend node\nmaybe_node: type = absent | ptr node\n\nrelease: (sink n: ptr node) -> (got: i32) =\n    got = n.val.value\nend release\n\ndrop: (sink m: maybe_node) -> (got: i32) =\n    got = 0\n    match m\n        absent: got = 1\n        ptr (sink held): got = release(held) + release(held)\n    end match\nend drop\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":14,"character":19}}}
-> {"jsonrpc":"2.0","id":3,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":14,"character":55},"end":{"line":14,"character":59}},"severity":1,"code":"L0302","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0302"},"source":"refine","message":"this place was consumed by `sink` and has not been assigned again\nnote: [0910]: a sunk place is dead until assignment","relatedInformation":[{"location":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":14,"character":18},"end":{"line":14,"character":22}}},"message":"the binding containing the consumed place"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nheld: ptr node\n```"},"range":{"start":{"line":14,"character":18},"end":{"line":14,"character":22}}}}
<- {"jsonrpc":"2.0","id":3,"result":null}
exit: 0
