# Roots are searched in order [1420].  An import found under the second
# root is the first root's as soon as a directory for it appears there,
# so a report also rests on each directory an import was looked for in
# under the roots before the one that had it, and the importer is
# rechecked when a source is created in one.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}},"initializationOptions":{"roots":["file:///workspace/first","file:///workspace/second"]}}}
-> {"jsonrpc":"2.0","method":"initialized","params":{}}
-> {"jsonrpc":"2.0","id":"refine-watch","result":null}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/second/app/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\nmain: () -> (status: i32) =\n    status = shapes.area (2, 3)\nend main\n"}}}
pause
disk: file:///workspace/first/lib/shapes/shapes.ldn | public area: (w: i32) -> (r: i32) = w * w end area\n
-> {"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///workspace/first/lib/shapes/shapes.ldn","type":1}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","id":"refine-watch","method":"client/registerCapability","params":{"registrations":[{"id":"refine-ldn-files","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[{"globPattern":"**/*.ldn"}]}}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/second/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/second/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/second/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":13},"end":{"line":3,"character":31}},"severity":1,"code":"L0327","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0327"},"source":"refine","message":"this call gives 2 arguments and the function takes 1 argument\nnote: [1920]: a call names every parameter exactly once","relatedInformation":[{"location":{"uri":"file:///workspace/first/lib/shapes/shapes.ldn","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":50}}},"message":"the signature written here"}]}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/first/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/second/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
