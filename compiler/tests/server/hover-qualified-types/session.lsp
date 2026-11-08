# A value of another module's type is spelled as the hovered source
# writes it: `shapes.point` in a program that imports lib/shapes, a
# private type by its public alias, `shapes.grid` rather than
# `grid_value`, and `point` alone inside lib/shapes itself; refusals
# spell them the same way. A local, a pointer, a call's result, an
# argument and a selection expression; then a local in the library.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace/","name":"workspace"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import lib/shapes\n\nmain: () -> (status: i32) =\n    corner: shapes.point = (x: 1, y: 2)\n    place := addr corner\n    plane := shapes.origin ()\n    status = i32 (place.val.x + shapes.width (plane))\nend main\n"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lib/shapes/shapes.ldn","languageId":"landin","version":1,"text":"public point: type = struct\n    x: u32\n    y: u32\nend point\n\ngrid_value: type = struct\n    corner: point\nend grid_value\n\n--- A grid, by its public name.\npublic grid: type = grid_value\n\npublic origin: () -> (result: grid) =\n    result = (corner: (x: 0, y: 0))\nend origin\n\npublic width: (of: grid) -> (count: u32) =\n    near := of.corner\n    count = near.x\nend width\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":3,"character":4}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":4,"character":4}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":5,"character":4}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":6,"character":46}}}
-> {"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":6,"character":24}}}
-> {"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/lib/shapes/shapes.ldn"},"position":{"line":17,"character":4}}}
-> {"jsonrpc":"2.0","id":8,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lib/shapes/shapes.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\ncorner: shapes.point\n```"},"range":{"start":{"line":3,"character":4},"end":{"line":3,"character":10}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"contents":{"kind":"markdown","value":"```landin\nplace: ptr shapes.point\n```"},"range":{"start":{"line":4,"character":4},"end":{"line":4,"character":9}}}}
<- {"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"```landin\nplane: shapes.grid\n```"},"range":{"start":{"line":5,"character":4},"end":{"line":5,"character":9}}}}
<- {"jsonrpc":"2.0","id":5,"result":{"contents":{"kind":"markdown","value":"```landin\nplane: shapes.grid\n```"},"range":{"start":{"line":6,"character":46},"end":{"line":6,"character":51}}}}
<- {"jsonrpc":"2.0","id":6,"result":{"contents":{"kind":"markdown","value":"```landin\nshapes.point\n```"},"range":{"start":{"line":6,"character":18},"end":{"line":6,"character":27}}}}
<- {"jsonrpc":"2.0","id":7,"result":{"contents":{"kind":"markdown","value":"```landin\nnear: point\n```"},"range":{"start":{"line":17,"character":4},"end":{"line":17,"character":8}}}}
<- {"jsonrpc":"2.0","id":8,"result":null}
exit: 0
