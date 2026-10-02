# A file's directory is its entry module and its imports are found under
# the configured roots, so a misspelt member is offered the public one; an
# untitled buffer is analysed alone; options refine would not accept are
# reported through showMessage. A configured folder root may end in '/'.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":["file:///workspace/"],"target":"linux-x86-64","options":{"Bad-Name":"1"}}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import lib/numbers\n\nmain: () -> (status: i32) =\n    status = i32 (numbers.doubel (21))\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"untitled:Untitled-1","languageId":"landin","version":1,"text":"f: () -> none = undefined () end f\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"window/showMessage","params":{"type":1,"message":"refine: invalid build option: Bad-Name"}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":26},"end":{"line":3,"character":32}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"module `numbers` has no member `doubel`\nnote: [1420]: a plain import exposes only qualified public members"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"untitled:Untitled-1","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":16},"end":{"line":0,"character":25}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`undefined` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
