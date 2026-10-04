# Alternating aliases invalidate cached analysis; repeated queries stay fresh.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/alias.ldn","version":1,"languageId":"landin","text":"first: (x: u8) -> (y: u8) = y = x end first\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn","version":1,"languageId":"landin","text":"other: (x: u16) -> (y: u16) = y = x end other\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":7,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":8,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":9,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":10,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":11,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":12,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":13,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":14,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":15,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/alias.ldn"},"position":{"line":0,"character":32}}}
-> {"jsonrpc":"2.0","id":16,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":17,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://localhost/workspace/alias.ldn"},"position":{"line":0,"character":34}}}
-> {"jsonrpc":"2.0","id":18,"method":"shutdown","params":{}}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/alias.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file://localhost/workspace/alias.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u8\n```"},"range":{"start":{"line":0,"character":32},"end":{"line":0,"character":33}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"uri":"file:///workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u8\n```"},"range":{"start":{"line":0,"character":32},"end":{"line":0,"character":33}}}}
<- {"jsonrpc":"2.0","id":5,"result":{"uri":"file:///workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":6,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u16\n```"},"range":{"start":{"line":0,"character":34},"end":{"line":0,"character":35}}}}
<- {"jsonrpc":"2.0","id":7,"result":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":8,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u16\n```"},"range":{"start":{"line":0,"character":34},"end":{"line":0,"character":35}}}}
<- {"jsonrpc":"2.0","id":9,"result":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":10,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u8\n```"},"range":{"start":{"line":0,"character":32},"end":{"line":0,"character":33}}}}
<- {"jsonrpc":"2.0","id":11,"result":{"uri":"file:///workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":12,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u16\n```"},"range":{"start":{"line":0,"character":34},"end":{"line":0,"character":35}}}}
<- {"jsonrpc":"2.0","id":13,"result":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":14,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u8\n```"},"range":{"start":{"line":0,"character":32},"end":{"line":0,"character":33}}}}
<- {"jsonrpc":"2.0","id":15,"result":{"uri":"file:///workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":16,"result":{"contents":{"kind":"markdown","value":"```landin\nx: u16\n```"},"range":{"start":{"line":0,"character":34},"end":{"line":0,"character":35}}}}
<- {"jsonrpc":"2.0","id":17,"result":{"uri":"file://localhost/workspace/alias.ldn","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
<- {"jsonrpc":"2.0","id":18,"result":null}
exit: 0
