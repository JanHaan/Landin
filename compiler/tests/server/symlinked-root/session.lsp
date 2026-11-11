# The root is named through a symbolic link, and the editor opens its
# files under the directory the link names.  Every path the loader
# builds goes through the link; the unsaved buffer of an imported source
# is still what its importer is checked against, the importer is
# rechecked when it changes, and a definition in it is answered with the
# URI the editor opened (D1069).
link: file:///workspace/linked | file:///workspace/real
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":["file:///workspace/linked"]}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/real/app/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\nmain: () -> (status: i32) =\n    status = shapes.area (2, 3)\nend main\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","languageId":"landin","version":1,"text":"public area: (w: i32, h: i32) -> (r: i32) = w * h end area\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","version":2},"contentChanges":[{"text":"public area: (w: i32) -> (r: i32) = w * w end area\n"}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/real/app/main.ldn"},"position":{"line":3,"character":21}}}
-> {"jsonrpc":"2.0","id":3,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/real/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/real/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":3,"character":13},"end":{"line":3,"character":31}},"severity":1,"code":"L0327","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0327"},"source":"refine","message":"this call gives 2 arguments and the function takes 1 argument\nnote: [1920]: a call names every parameter exactly once","relatedInformation":[{"location":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":50}}},"message":"the signature written here"}]}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"uri":"file:///workspace/real/lib/shapes/shapes.ldn","range":{"start":{"line":0,"character":7},"end":{"line":0,"character":11}}}}
<- {"jsonrpc":"2.0","id":3,"result":null}
exit: 0
