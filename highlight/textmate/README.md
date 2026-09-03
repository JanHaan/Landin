# Landin for TextMate-compatible editors

This directory is an installable VS Code language extension. Its TextMate
grammar is generated from `../landin_highlight.py`; `0.0.0` means that the
repository package is unreleased, not that Landin has a release version.

For VS Code, VSCodium, Cursor, or Windsurf, run `npm install`, then
`npx vsce package` and choose **Install from VSIX**, or copy this directory to
the editor's extensions directory while developing. `npm test` drives the
grammar through VS Code's own TextMate and Oniguruma libraries; `npm run
package:check` validates the files that will enter the extension.

Sublime Text and TextMate can load `syntaxes/landin.tmLanguage.json` directly.
JetBrains IDEs with the TextMate Bundles plugin can import this entire
directory.
