# A header that cannot be read leaves no way to find the next message, so
# the server ends there, with status 1.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
raw: Content-Length 2\r\n\r\n{}
-> {"jsonrpc":"2.0","id":2,"method":"shutdown"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
exit: 1
