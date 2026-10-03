# Landin for Emacs

Place this directory on `load-path` and `(require 'landin-mode)`. Emacs 29+
uses `landin-ts-mode` when the `landin` tree-sitter grammar is installed and
falls back to `landin-mode` otherwise. Run `M-x landin-ts-install-grammar` to
fetch and compile the grammar, then reload this package to enable the
structural mode. The installer defaults to the commit matching this package's
grammar. If you change the grammar or its font-lock rules, update
`landin-treesit-revision` to a commit containing the grammar change before
distributing the package.

The package registers `refine lsp`, the compiler's language server, with
Eglot. With `refine` on the path, `M-x eglot` in a Landin buffer starts it:
diagnostics through Flymake, `xref-find-definitions`, Eldoc hover,
`eglot-format-buffer` and `eglot-code-actions` for its quick fixes. To start
it every time, add `eglot-ensure` to `landin-mode-hook`.
