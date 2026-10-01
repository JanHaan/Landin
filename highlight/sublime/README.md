# Landin for Sublime Text

Copy this directory to the Sublime Text `Packages/Landin` directory. The
package contains the generated TextMate grammar, `.ldn` recognition, comment
commands, and four-space indentation defaults.

With the [LSP package](https://lsp.sublimetext.io) installed, merge
`LSP-refine.sublime-settings` into its settings to start `refine lsp`, the
compiler's language server, for Landin files: diagnostics, go to definition,
hover, formatting and quick fixes. `refine` must be on the path.
