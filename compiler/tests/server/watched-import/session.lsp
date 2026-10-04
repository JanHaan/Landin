# An unopened import changes on disk twice. Each watched-file notification
# republishes the importer and the import, including the newly absent error.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}},"initializationOptions":{"roots":["file:///workspace"]}}}
-> {"jsonrpc":"2.0","method":"initialized","params":{}}
-> {"jsonrpc":"2.0","id":"refine-watch","result":null}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import lib/numbers\n\nmain: () -> (status: i32) =\n    status = i32 (numbers.double (21))\nend main\n"}}}
pause
disk: file:///workspace/lib/numbers/numbers.ldn | public doubel: (x: u8) -> (y: u8) = x + x end doubel\n
-> {"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///workspace/lib/numbers/numbers.ldn","type":2}]}}
pause
disk: file:///workspace/lib/numbers/numbers.ldn | public double: (x: u8) -> (y: u8) = x + x end double\n
-> {"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///workspace/lib/numbers/numbers.ldn","type":2},{"uri":"https://invalid.example/file.ldn","type":2}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","id":"refine-watch","method":"client/registerCapability","params":{"registrations":[{"id":"refine-ldn-files","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[{"globPattern":"**/*.ldn"}]}}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":26},"end":{"line":3,"character":32}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"module `numbers` has no member `double`\nnote: [1420]: a plain import exposes only qualified public members"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
