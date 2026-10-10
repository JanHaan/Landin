# A pointer to and a slice of erased values: the hover spells the
# referent from its concept, which an erased referent records in place
# of a reference. A mutated corpus fixture found the pointer's hover
# raising a defect.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace/","name":"workspace"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"counter: type = concept (t: type)\n    bump: (self: ptr mut t) -> (result: i32)\nend counter\none: type = struct\n    value: i32\nend one\nbump_one: (self: ptr mut one) -> (result: i32) =\n    result = self.val.value\nend bump_one\none is counter (bump: bump_one)\nmut left: one = (value: 7)\n\nmain: () -> (status: i32) =\n    mut items: [2]any counter = [any(addr left), any(addr left)]\n    held := addr items[0]\n    view := items[0 ..< 2]\n    status = i32(lenof view) + held.val.bump()\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":14,"character":4}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":15,"character":4}}}
-> {"jsonrpc":"2.0","id":4,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nheld: ptr mut any counter\n```"},"range":{"start":{"line":14,"character":4},"end":{"line":14,"character":8}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"contents":{"kind":"markdown","value":"```landin\nview: []mut any counter\n```"},"range":{"start":{"line":15,"character":4},"end":{"line":15,"character":8}}}}
<- {"jsonrpc":"2.0","id":4,"result":null}
exit: 0
