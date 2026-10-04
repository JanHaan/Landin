# Each rejected initialization setting has a visible boundary in the one
# showMessage notification. A valid root is still accepted after a bad one.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"roots":[7,"file:///workspace"],"target":"wrong-target","level":"wrong-level","options":{"Bad-Name":"1"},"firmwareEntry":7}}}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"window/showMessage","params":{"type":1,"message":"refine: a root is not a string\nunknown target: wrong-target\nunknown level for linux-x86-64: wrong-level\ninvalid build option: Bad-Name\nfirmwareEntry is a string"}}
<- {"jsonrpc":"2.0","id":2,"result":null}
exit: 0
