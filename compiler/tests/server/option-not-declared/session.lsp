# The editor's one options setting reaches every module.  A module
# that does not declare an option is checked without it, and that is
# said once for the option, in the editor's log (D1068); a module that
# declares it is checked with it, and a value its option's type cannot
# hold is refused at that option, as a build refuses it.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"options":{"enabled":"true","level":"300"}}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/plain.ldn","languageId":"landin","version":1,"text":"aa: u8 = missing\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/plain.ldn","version":2},"contentChanges":[{"text":"aa: u8 = absent\n"}]}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/opted.ldn","languageId":"landin","version":1,"text":"option enabled: bool = false\nfixed if enabled then\n    answer: i32 = 42\nelse\n    answer: missing = 1\nend if\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/ranged.ldn","languageId":"landin","version":1,"text":"option level: u8 = 1\nanswer: i32 = 42\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/ranged.ldn","version":2},"contentChanges":[{"text":"option level: u8 = 1\nanswer: i32 = 42\nother: i32 = 1\n"}]}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/ranged.ldn","version":3},"contentChanges":[{"text":"option level: u8 = 1\nanswer: i32 = 42\nother: i32 = 2\n"}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/plain.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":16}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`missing` is not declared in any scope this reaches\nnote: [1860]: a name used here needs a declaration in scope; check its spelling"}]}}
<- {"jsonrpc":"2.0","method":"window/logMessage","params":{"type":2,"message":"refine: the build option `enabled` is not declared by the module of file:///workspace/plain.ldn and is not applied to it; a module that declares it is checked with it"}}
<- {"jsonrpc":"2.0","method":"window/logMessage","params":{"type":2,"message":"refine: the build option `level` is not declared by the module of file:///workspace/plain.ldn and is not applied to it; a module that declares it is checked with it"}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/plain.ldn","version":2,"diagnostics":[{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":15}},"severity":1,"code":"L0201","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0201"},"source":"refine","message":"`absent` is not declared in any scope this reaches\nnote: [1860]: a name used here needs a declaration in scope; check its spelling"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/opted.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/ranged.ldn","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":20}},"severity":1,"code":"L0300","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0300"},"source":"refine","message":"option `level`: --option=level=300 is outside its type range (u8)\nnote: [1530]/D202: the option value must fit its declared scalar type on the selected target"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/ranged.ldn","version":2,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":20}},"severity":1,"code":"L0300","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0300"},"source":"refine","message":"option `level`: --option=level=300 is outside its type range (u8)\nnote: [1530]/D202: the option value must fit its declared scalar type on the selected target"}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/ranged.ldn","version":3,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":20}},"severity":1,"code":"L0300","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0300"},"source":"refine","message":"option `level`: --option=level=300 is outside its type range (u8)\nnote: [1530]/D202: the option value must fit its declared scalar type on the selected target"}]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
