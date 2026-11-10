# An imported module's directory is removed and the change is
# reported for the directory, once with a final slash and once
# without: every module that read a source beneath it is rechecked.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}},"initializationOptions":{"roots":["file:///workspace"]}}}
-> {"jsonrpc":"2.0","method":"initialized","params":{}}
-> {"jsonrpc":"2.0","id":"refine-watch","result":null}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\nimport lib/numbers\n\nmain: () -> (status: i32) =\n    status = shapes.area (2, numbers.three ())\nend main\n"}}}
pause
gone: file:///workspace/lib/shapes
-> {"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///workspace/lib/shapes/","type":3}]}}
pause
gone: file:///workspace/lib/numbers
-> {"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///workspace/lib/numbers","type":3}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","id":"refine-watch","method":"client/registerCapability","params":{"registrations":[{"id":"refine-ldn-files","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[{"globPattern":"**/*.ldn"}]}}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"severity":1,"code":"L0006","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0006"},"source":"refine","message":"module not found: lib/shapes\nnote: [1420]: an import names a directory under a root, and roots are searched in the order given; no directory /workspace/lib/shapes was found"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":17}},"severity":1,"code":"L0006","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0006"},"source":"refine","message":"module not found: lib/shapes\nnote: [1420]: an import names a directory under a root, and roots are searched in the order given; no directory /workspace/lib/shapes was found"},{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":18}},"severity":1,"code":"L0006","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0006"},"source":"refine","message":"module not found: lib/numbers\nnote: [1420]: an import names a directory under a root, and roots are searched in the order given; no directory /workspace/lib/numbers was found"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/numbers/numbers.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
