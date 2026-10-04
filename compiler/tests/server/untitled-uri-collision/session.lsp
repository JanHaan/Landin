# Explicit idle boundaries publish diagnostics; formatting itself does not.
# Escaped percent bytes and literal underscores name distinct untitled
# buffers. Opening, changing, and closing one must not alter the other.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"untitled:foo%20bar","languageId":"landin","version":1,"text":"first:u8=1\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"untitled:foo%20bar"},"options":{"tabSize":2,"insertSpaces":true}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"untitled:foo_2520bar","languageId":"landin","version":1,"text":"second: u8 = 2\n"}}}
pause
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/formatting","params":{"textDocument":{"uri":"untitled:foo%20bar"},"options":{"tabSize":2,"insertSpaces":true}}}
pause
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/formatting","params":{"textDocument":{"uri":"untitled:foo_2520bar"},"options":{"tabSize":2,"insertSpaces":true}}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"untitled:foo_2520bar","version":2},"contentChanges":[{"text":"second:u8=3\n"}]}}
pause
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/formatting","params":{"textDocument":{"uri":"untitled:foo%20bar"},"options":{"tabSize":2,"insertSpaces":true}}}
pause
-> {"jsonrpc":"2.0","id":6,"method":"textDocument/formatting","params":{"textDocument":{"uri":"untitled:foo_2520bar"},"options":{"tabSize":2,"insertSpaces":true}}}
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"untitled:foo_2520bar"}}}
pause
-> {"jsonrpc":"2.0","id":7,"method":"textDocument/formatting","params":{"textDocument":{"uri":"untitled:foo%20bar"},"options":{"tabSize":2,"insertSpaces":true}}}
-> {"jsonrpc":"2.0","id":8,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"untitled:foo%20bar","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":6}},"newText":" "},{"range":{"start":{"line":0,"character":8},"end":{"line":0,"character":8}},"newText":" "},{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":9}},"newText":" "}]}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"untitled:foo_2520bar","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":3,"result":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":6}},"newText":" "},{"range":{"start":{"line":0,"character":8},"end":{"line":0,"character":8}},"newText":" "},{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":9}},"newText":" "}]}
<- {"jsonrpc":"2.0","id":4,"result":[]}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"untitled:foo_2520bar","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":5,"result":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":6}},"newText":" "},{"range":{"start":{"line":0,"character":8},"end":{"line":0,"character":8}},"newText":" "},{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":9}},"newText":" "}]}
<- {"jsonrpc":"2.0","id":6,"result":[{"range":{"start":{"line":0,"character":7},"end":{"line":0,"character":7}},"newText":" "},{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":9}},"newText":" "},{"range":{"start":{"line":0,"character":10},"end":{"line":0,"character":10}},"newText":" "}]}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"untitled:foo_2520bar","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":7,"result":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":6}},"newText":" "},{"range":{"start":{"line":0,"character":8},"end":{"line":0,"character":8}},"newText":" "},{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":9}},"newText":" "}]}
<- {"jsonrpc":"2.0","id":8,"result":null}
exit: 0
