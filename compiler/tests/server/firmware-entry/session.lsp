# The selected Cortex-M0 firmware entry is checked with the compiler's
# build-entry predicate, and its diagnostic clears when the shape is fixed.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"target":"cortex-m0","firmwareEntry":"start"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/entry.ldn","languageId":"landin","version":1,"text":"start: (value: u32) -> none =\n    _ = value\nend start\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/entry.ldn","version":2},"contentChanges":[{"text":"start: () -> none =\nend start\n"}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/entry.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"code":"L0502","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0502"},"source":"refine","message":"firmware requires --firmware-entry=start naming a nongeneric entry-module definition () -> none or noreturn with an empty error set"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/entry.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
