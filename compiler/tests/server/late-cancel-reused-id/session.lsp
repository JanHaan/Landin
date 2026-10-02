# A cancellation received after a hover answer cannot cancel the next
# hover with the same ID. The pause waits for the first answer on a pipe.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"untitled:cancel","languageId":"landin","version":1,"text":"value: u8 = 1\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"untitled:cancel"},"position":{"line":0,"character":1}}}
pause
-> {"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2}}
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"untitled:cancel"},"position":{"line":0,"character":1}}}
-> {"jsonrpc":"2.0","id":3,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"untitled:cancel","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nvalue: u8\n```"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nvalue: u8\n```"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}
<- {"jsonrpc":"2.0","id":3,"result":null}
exit: 0
