# Explicit idle boundaries publish diagnostics; formatting itself does not.
# Closing the canonical URI first still clears the last localhost alias.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/alias.ldn","languageId":"landin","version":1,"text":"aa: u8 = 1\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn","languageId":"landin","version":1,"text":"broken: (u8 =\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"options":{"tabSize":4,"insertSpaces":true}}}
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"}}}
pause
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"options":{"tabSize":4,"insertSpaces":true}}}
-> {"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"}}}
-> {"jsonrpc":"2.0","id":4,"method":"shutdown","params":{}}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/alias.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file://localhost/workspace/alias.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":12},"end":{"line":0,"character":13}},"severity":1,"code":"L0103","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0103"},"source":"refine","message":"a parameter names its type after `:`, not `=`\nnote: [1800]: modifiers precede `name: type`","relatedInformation":[{"location":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":9},"end":{"line":0,"character":11}}},"message":"declared here"}]},{"range":{"start":{"line":0,"character":12},"end":{"line":0,"character":13}},"severity":1,"code":"L0104","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0104"},"source":"refine","message":"this function is never closed\nnote: [1800]: `=` opens the body and `end` closes it","relatedInformation":[{"location":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":6}}},"message":"opened here"}]}]}}
<- {"jsonrpc":"2.0","id":2,"result":[]}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/alias.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file://localhost/workspace/alias.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":12},"end":{"line":0,"character":13}},"severity":1,"code":"L0103","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0103"},"source":"refine","message":"a parameter names its type after `:`, not `=`\nnote: [1800]: modifiers precede `name: type`","relatedInformation":[{"location":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":9},"end":{"line":0,"character":11}}},"message":"declared here"}]},{"range":{"start":{"line":0,"character":12},"end":{"line":0,"character":13}},"severity":1,"code":"L0104","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0104"},"source":"refine","message":"this function is never closed\nnote: [1800]: `=` opens the body and `end` closes it","relatedInformation":[{"location":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":6}}},"message":"opened here"}]}]}}
<- {"jsonrpc":"2.0","id":3,"result":null}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file://localhost/workspace/alias.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":4,"result":null}
exit: 0
