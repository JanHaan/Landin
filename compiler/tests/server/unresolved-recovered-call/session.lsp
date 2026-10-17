# A recovered call whose callee names nothing, in a routine whose error set
# is inferred: the server still checks a program whose only errors are
# unresolved names, so that its answers have types, and the call has no
# error set to infer. It reports the two names and hovers with the result's
# type, with no internal defect. Found by the fuzzer, seed 500673.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/main.ldn","languageId":"landin","version":1,"text":"display: type = concept (t: type)\nend display\n\nconsumer: (erased: any display) -> (answer: i32) ! ... =\n    answer = erase+%d.code() else (problem)\n        fail problem\n    end\nend consumer\n"}}}
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":4,"character":5}}}
-> {"jsonrpc":"2.0","id":3,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":4,"character":13},"end":{"line":4,"character":18}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`erase` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"},{"range":{"start":{"line":4,"character":20},"end":{"line":4,"character":21}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`d` is not declared in any scope this reaches\nnote: [1860]: a name that is not in scope is a misspelling, not a new binding"}]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nanswer: i32\n```"},"range":{"start":{"line":4,"character":4},"end":{"line":4,"character":10}}}}
<- {"jsonrpc":"2.0","id":3,"result":null}
exit: 0
