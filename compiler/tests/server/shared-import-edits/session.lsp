# Two modules import one edited source. Replacing and closing publications
# must keep the inverse dependency index current. Removing one importer
# republishes the remaining owner instead of clearing its shared diagnostic.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":["file:///workspace"]}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/a.ldn","languageId":"landin","version":1,"text":"import lib/numbers\n\nmain: () -> (status: i32) =\n    status = i32 (numbers.double (21))\nend main\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/other/b.ldn","languageId":"landin","version":1,"text":"import lib/numbers\n\nmain: () -> (status: i32) =\n    status = i32 (numbers.double (21))\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lib/numbers/numbers.ldn","languageId":"landin","version":1,"text":"public double: (x: u8) -> (y: u8) = x + x end double\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":2},"contentChanges":[{"text":"public triple: (x: u8) -> (y: u8) = x + x + x end triple\n"}]}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/app/a.ldn","version":2},"contentChanges":[{"text":"main: () -> (status: i32) =\n    status = 0\nend main\n"}]}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/app/a.ldn"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":3},"contentChanges":[{"text":"public double: (x: u8) -> (y: u8) = x + x end double\n"}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/a.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/other/b.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/a.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/other/b.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/a.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":26},"end":{"line":3,"character":32}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"module `numbers` has no member `double`\nnote: [1420]: a plain import exposes only qualified public members"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/other/b.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":26},"end":{"line":3,"character":32}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"module `numbers` has no member `double`\nnote: [1420]: a plain import exposes only qualified public members"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/a.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/other/b.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":26},"end":{"line":3,"character":32}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"module `numbers` has no member `double`\nnote: [1420]: a plain import exposes only qualified public members"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/a.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":3,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/other/b.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","version":3,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
