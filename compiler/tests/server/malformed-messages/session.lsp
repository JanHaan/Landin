# A body that is not JSON, one that is not an object, one that is not
# JSON-RPC 2.0, and one with no method each get their error and the
# session goes on; then the input ends without exit, which is status 1.
chunk: 7
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","id":2,
-> [1,2]
-> {"jsonrpc":"1.0","id":3,"method":"shutdown"}
-> {"jsonrpc":"2.0","id":4}
-> {"jsonrpc":"2.0","id":5,"method":"shutdown"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"a member needs a string name"}}
<- {"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"a message is an object"}}
<- {"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"not a JSON-RPC 2.0 message"}}
<- {"jsonrpc":"2.0","id":5,"result":null}
exit: 1
