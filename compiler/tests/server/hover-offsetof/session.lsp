# The fields an `offsetof` measures, and a field a value selects: hover
# describes the field as its struct declares it where the measured
# path has no value of its own, and definition goes to the field in
# that struct, through a nested struct as well.
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
-> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/main.ldn","languageId":"landin","version":1,"text":"word_box: type = struct\n    tag: u8\n    word: u32\nend word_box\n\nframe: type = struct\n    head: u16\n    body: word_box\nend frame\n\npublic main: () -> (code: i32) =\n    code = i32(offsetof frame.body.word)\n    f: frame = zeroed\n    code += i32(f.head)\nend main\n"}}}
pause
-> {"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":11,"character":31}}}
-> {"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":11,"character":31}}}
-> {"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":11,"character":36}}}
-> {"jsonrpc":"2.0","id":5,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":11,"character":36}}}
-> {"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":13,"character":19}}}
-> {"jsonrpc":"2.0","id":7,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/main.ldn"},"position":{"line":13,"character":19}}}
-> {"jsonrpc":"2.0","id":99,"method":"shutdown"}
-> {"jsonrpc":"2.0","method":"exit"}
<- {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"hoverProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]}},"serverInfo":{"name":"refine"}}}
<- {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/main.ldn","version":1,"diagnostics":[]}}
<- {"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"```landin\nbody: word_box\n```"},"range":{"start":{"line":11,"character":30},"end":{"line":11,"character":34}}}}
<- {"jsonrpc":"2.0","id":3,"result":{"uri":"file:///workspace/main.ldn","range":{"start":{"line":7,"character":4},"end":{"line":7,"character":8}}}}
<- {"jsonrpc":"2.0","id":4,"result":{"contents":{"kind":"markdown","value":"```landin\nword: u32\n```"},"range":{"start":{"line":11,"character":35},"end":{"line":11,"character":39}}}}
<- {"jsonrpc":"2.0","id":5,"result":{"uri":"file:///workspace/main.ldn","range":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}}}}
<- {"jsonrpc":"2.0","id":6,"result":{"contents":{"kind":"markdown","value":"```landin\nu16\n```"},"range":{"start":{"line":13,"character":16},"end":{"line":13,"character":22}}}}
<- {"jsonrpc":"2.0","id":7,"result":{"uri":"file:///workspace/main.ldn","range":{"start":{"line":6,"character":4},"end":{"line":6,"character":8}}}}
<- {"jsonrpc":"2.0","id":99,"result":null}
exit: 0
