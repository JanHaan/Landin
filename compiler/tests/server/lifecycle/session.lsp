# The lifecycle: a request before initialize, initialize, a method the
# server does not offer, a notification it does not know, shutdown, a
# cancellation for an ID with no pending request, a request after shutdown,
# and exit after shutdown.
-> {"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{}}
-> {"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"initialized","params":{}}
-> {"jsonrpc":"2.0","id":3,"method":"workspace/symbol","params":{"query":"x"}}
-> {"jsonrpc":"2.0","method":"$/setTrace","params":{"value":"off"}}
-> {"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":7}}
-> {"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{}}
-> {"jsonrpc":"2.0","id":"s","method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","id":4,"method":"shutdown"}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/formatting","params":{}}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"the server is not initialized"}}
<- {"jsonrpc":"2.0","id":2,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"unsupported: workspace/symbol"}}
<- {"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"the document is not open"}}
<- {"jsonrpc":"2.0","id":"s","error":{"code":-32600,"message":"already initialized"}}
<- {"jsonrpc":"2.0","id":4,"result":null}
<- {"jsonrpc":"2.0","id":5,"error":{"code":-32600,"message":"the server is shutting down"}}
exit: 0
