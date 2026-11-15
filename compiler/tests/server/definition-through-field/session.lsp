# D1363: the name a conformance's `through` gives is a field of its
# target: definition goes to the field in the struct's body, and hover
# shows the field as that body declares it.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/main.ldn","languageId":"landin","version":1,"text":"counter: type = concept (t: type)\n    count: (self: t) -> (n: u32)\nend counter\n\nbox: type = struct\n    n: u32\nend box\n\nbox_count: (self: box) -> (n: u32) = self.n end box_count\n\nbox is counter (count: box_count)\n\nholder: type = struct\n    tag: u8\n    inner: box\nend holder\n\nholder is counter through inner\n\npublic main: () -> (code: i32) =\n    h: holder = (tag: 1, inner: (n: 2))\n    code = i32(holder.count(h))\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":17,"character":28}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":17,"character":28}}}
-> {"jsonrpc":"2.0","id":4,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"uri":"file:///workspace/main.ldn","range":{"start":{"line":14,"character":4},"end":{"line":14,"character":9}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"contents":{"kind":"markdown","value":"```landin\ninner: box\n```"},"range":{"start":{"line":17,"character":26},"end":{"line":17,"character":31}}}}
<- {"jsonrpc":"2.0","id":4,"result":null}
exit: 0
