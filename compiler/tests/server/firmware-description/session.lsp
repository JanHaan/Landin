# A firmware module that imports its device description is checked with the
# profile it selects (D543, D544): IRQ1 is slot 17 there, so a handler at
# slot 21 is refused naming the device, and moving it to 17 clears it.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///workspace","name":"w"}],"initializationOptions":{"target":"cortex-m0","firmwareEntry":"start"}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","languageId":"landin","version":1,"text":"import descriptions/plain\nlink(vector: 21) extern(interrupt) h: () -> none = end h\nstart: () -> none = end start\n"}}}
pause
-> {"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/app/main.ldn","version":2},"contentChanges":[{"text":"import descriptions/plain\nlink(vector: 17) extern(interrupt) h: () -> none = end h\nstart: () -> none = end start\n"}]}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":1,"diagnostics":[{"range":{"start":{"line":1,"character":35},"end":{"line":1,"character":36}},"severity":1,"code":"L0347","codeDescription":{"href":"https://www.701.dev/diagnostics.html#l0347"},"source":"refine","message":"vector slot 21 is reserved in plain, so no handler takes it\nnote: [1990]/D544: a cortex-m0plus takes handlers at core slots 2, 3, 11, 14 and 15 and at 16 + IRQ for each interrupt the description names; its 48-word table holds every other slot as zero","relatedInformation":[{"location":{"uri":"file:///workspace/app/main.ldn","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":56}}},"message":"the declaration it places"}]}]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/descriptions/plain/interrupts.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/descriptions/plain/memory.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/app/main.ldn","version":2,"diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/descriptions/plain/interrupts.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/descriptions/plain/memory.ldn","diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
