# Landin for TextMate-compatible editors

This directory is an installable VS Code language extension. Its TextMate
grammar is generated from `../landin_highlight.py`; `0.0.0` means that the
repository package is unreleased, not that Landin has a release version.

For VS Code, VSCodium, Cursor, or Windsurf, run `npm install`, then
`npx vsce package` and choose **Install from VSIX**, or copy this directory to
the editor's extensions directory while developing. The extension also
starts `refine lsp`, the compiler's language server, through
`vscode-languageclient`: diagnostics, go to definition, hover, formatting and
quick fixes. `refine` must be on the path, or `landin.server.path` must name
it; `landin.server.enable` turns the server off. `npm install` fetches the
client, and the VSIX carries it. `npm test` drives the
grammar through VS Code's own TextMate and Oniguruma libraries; `npm run
package:check` validates the files that will enter the extension.

Set `landin.server.target`, `landin.server.level` and
`landin.server.options` in VS Code's workspace settings to match the build.
For example, `.vscode/settings.json` for a Cortex-M0 build at the armv7-m
feature level with a `board` option can contain:

```json
{
  "landin.server.target": "cortex-m0",
  "landin.server.level": "armv7-m",
  "landin.server.options": { "board": "rp2040" }
}
```

An empty target selects `linux-x86-64`; an empty level selects that target's
default level. Option names use lowercase letters, digits and underscores,
and values are nonempty strings. The extension sends these settings when
`refine lsp` starts. After changing them, use **Developer: Reload Window**
to start it with the new values. The server reports invalid values in an
editor message.

Sublime Text and TextMate can load `syntaxes/landin.tmLanguage.json` directly.
JetBrains IDEs with the TextMate Bundles plugin can import this entire
directory.
