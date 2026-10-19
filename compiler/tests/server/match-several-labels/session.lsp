# D405: one match arm names several cases.  Each label is a name the
# server knows on its own: where it is declared and what it is, the
# second label as well as the first.  Renaming the last arm's `east` to
# `north` names `north` twice, reported on the copy with the first as its
# related place, and leaves `east` without an arm.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace/","name":"workspace"}]}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"north: atom\nsouth: atom\neast: atom\ncompass: type = north | south | east\n\nheading: (c: compass) -> (n: i32) =\n    match c\n        north, south: n = 1\n        east: n = 2\n    end match\nend heading\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":7,"character":16}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":7,"character":9}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn"},"position":{"line":7,"character":16}}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","version":2},"contentChanges":[{"range":{"start":{"line":8,"character":8},"end":{"line":8,"character":12}},"text":"north"}]}}
pause
-> {"jsonrpc":"2.0","id":5,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}
<- {"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"```landin\nsouth: atom\n```"},"range":{"start":{"line":7,"character":15},"end":{"line":7,"character":20}}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":2,"diagnostics":[{"range":{"start":{"line":6,"character":10},"end":{"line":6,"character":11}},"severity":1,"code":"L0312","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0312"},"source":"refine","message":"this match has no arm for `east`\nnote: [0640]: matching an atom union is exhaustive"},{"range":{"start":{"line":8,"character":8},"end":{"line":8,"character":13}},"severity":1,"code":"L0311","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0311"},"source":"refine","message":"this atom is matched twice\nnote: [0640]: an exhaustive match names each atom at most once","relatedInformation":[{"location":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":7,"character":8},"end":{"line":7,"character":13}}},"message":"first matched here"}]}]}}
<- {"jsonrpc":"2.0","id":5,"result":null}
exit: 0
