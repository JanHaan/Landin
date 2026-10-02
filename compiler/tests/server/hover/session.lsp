# The open buffer replaces a saved main.ldn in workspace/app.
# What a name or an expression is: a routine's header and its doc
# comment, an inferred local's type, a parameter, a struct type and its
# doc comment from another module, a comparison, a field selection and a
# literal; a keyword is not described.
# Positions are UTF-16 code units here. Workspace folder URIs may end in '/'.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace/","name":"workspace"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\n--- The larger of two counts.\n--- Equal counts give the first.\nlarger: (a: u32, b: u32) -> (c: u32) =\n    c = if a < b then b else a end if\nend larger\n\nmain: () -> (status: i32) =\n    count := larger (2, 40)\n    corner: shapes.point = (x: 1, y: 2)\n    status = i32 (count + corner.x)\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":9,"character":13}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":9,"character":6}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":5,"character":11}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":5,"character":13}}}
-> {"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":10,"character":19}}}
-> {"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":11,"character":33}}}
-> {"jsonrpc":"2.0","id":8,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":9,"character":21}}}
-> {"jsonrpc":"2.0","id":9,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":5,"character":8}}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","version":2},"contentChanges":[{"text":"import lib/shapes\n\n--- The larger of two counts.\n--- Equal counts give the first.\nlarger: (a: u32, b: u32) -> (c: u32) =\n    c = if a < b then b else a end if\nend larger\n\nmain: () -> (status: i32) =\n    count := larger (2, 41)\n    corner: shapes.point = (x: 1, y: 2)\n    status = i32 (count + corner.x)\nend main\n"}]}}
-> {"jsonrpc":"2.0","id":11,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":9,"character":13}}}
-> {"jsonrpc":"2.0","id":10,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nlarger: (a: u32, b: u32) -> (c: u32)\n```\n\nThe larger of two counts.\nEqual counts give the first."},"range":{"start":{"line":9,"character":13},"end":{"line":9,"character":19}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"contents":{"kind":"markdown","value":"```landin\ncount: u32\n```"},"range":{"start":{"line":9,"character":4},"end":{"line":9,"character":9}}}}
<- {"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"```landin\na: u32\n```"},"range":{"start":{"line":5,"character":11},"end":{"line":5,"character":12}}}}
<- {"jsonrpc":"2.0","id":5,"result":{"contents":{"kind":"markdown","value":"```landin\nbool\n```"},"range":{"start":{"line":5,"character":11},"end":{"line":5,"character":16}}}}
<- {"jsonrpc":"2.0","id":6,"result":{"contents":{"kind":"markdown","value":"```landin\npublic point: type = struct\n```\n\nA place on the grid."},"range":{"start":{"line":10,"character":19},"end":{"line":10,"character":24}}}}
<- {"jsonrpc":"2.0","id":7,"result":{"contents":{"kind":"markdown","value":"```landin\nu32\n```"},"range":{"start":{"line":11,"character":26},"end":{"line":11,"character":34}}}}
<- {"jsonrpc":"2.0","id":8,"result":{"contents":{"kind":"markdown","value":"```landin\nu32\n```"},"range":{"start":{"line":9,"character":21},"end":{"line":9,"character":22}}}}
<- {"jsonrpc":"2.0","id":9,"result":null}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":11,"result":{"contents":{"kind":"markdown","value":"```landin\nlarger: (a: u32, b: u32) -> (c: u32)\n```\n\nThe larger of two counts.\nEqual counts give the first."},"range":{"start":{"line":9,"character":13},"end":{"line":9,"character":19}}}}
<- {"jsonrpc":"2.0","id":10,"result":null}
exit: 0
