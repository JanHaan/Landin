# A missing erased entry reports L0308 even when its recovered error type
# leaves inference open. Repairing the concept clears the refusal.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/main.ldn","languageId":"landin","version":1,"text":"display: type = concept (t: type)\nend display\n\nconsumer: (erased: any display) -> (answer: i32) ! ... =\n    answer = erased.code() else (problem)\n        fail problem\n    end\nend consumer\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":0,"character":0}}}
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/main.ldn","version":2},"contentChanges":[{"text":"unavailable: atom\ndisplay: type = concept (t: type)\n    code: (self: ptr t) -> (value: i32) ! unavailable\nend display\n\nconsumer: (erased: any display) -> (answer: i32) ! ... =\n    answer = erased.code() else (problem)\n        fail problem\n    end\nend consumer\n\nbox: type = struct\n    value: i32\nend box\nbox_code: (self: ptr box) -> (value: i32) ! unavailable =\n    value = self.val.value\nend box_code\nbox is display (code: box_code)\n"}]}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":0,"character":0}}}
-> {"jsonrpc":"2.0","id":4,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":4,"character":20},"end":{"line":4,"character":24}},"severity":1,"code":"L0308","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0308"},"source":"refine","message":"this runtime concept has no entry called `code`\nnote: [1390]: an `any` member names one concept entry"}]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\ndisplay: type = concept (t: type)\n```"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":7}}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":3,"result":{"contents":{"kind":"markdown","value":"```landin\nunavailable: atom\n```"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":11}}}}
<- {"jsonrpc":"2.0","id":4,"result":null}
exit: 0
