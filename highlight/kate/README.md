# Landin for Kate

Install `landin.xml` as a user syntax-highlighting definition, in
`~/.local/share/org.kde.syntax-highlighting/syntax/` on Linux.

`lsp-client.json` starts `refine lsp`, the compiler's language server, for
Landin files through Kate's LSP Client plugin: diagnostics, go to definition,
hover, formatting and quick fixes. Merge its `servers` entry into the
plugin's User Server Settings, under Settings, Configure Kate, LSP Client.
`refine` must be on the path. A module's imports are found under the
workspace root, the nearest directory holding `.git`.
