# A valid explicit target pins the invalid-level diagnostic on every host.
# Multiple other rejected settings still require visible error separators.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":[7,"file:///workspace"],"target":"linux-x86-64","level":"wrong-level","options":{"Bad-Name":"1"},"firmwareEntry":7}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"window/showMessage","params":{"type":1,"message":"refine: a root is not a string\nunknown level for linux-x86-64: wrong-level\ninvalid build option: Bad-Name\nfirmwareEntry is a string"}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
