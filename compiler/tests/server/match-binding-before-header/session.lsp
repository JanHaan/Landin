# A match used as a value, whose arm calls a routine with the arm's
# binding, inside an inferred binding the subject cannot resolve: the
# first-arm value search reached the binding before any walk had
# checked the match's header. A mutated corpus fixture found the
# checker raising a defect there.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace/","name":"workspace"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"absent: atom\nmaybe_pointer: type = absent | ptr u32\n\npair: (cell: ptr u32, missing: bool)\n      -> (item: maybe_pointer from cell, got: bool) =\n    item = if missing then absent else cell end if\n    got = not missing\nend pair\n\nretain: (escaping pointer: ptr u32) -> none =\n    _ = pointer\nend retain\n\nbad: (missing: bool) -> none =\n    cell: u32 = 42\n    values := pair(addr cell, missing)\n +%   match values.item\n        absent: _ = 0\n        ptr (pointer): retain(pointer)\n    end match\nend bad\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":18,"character":34}}}
-> {"jsonrpc":"2.0","id":3,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":16,"character":12},"end":{"line":16,"character":18}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`values` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
<- {"jsonrpc":"2.0","id":3,"result":null}
exit: 0
