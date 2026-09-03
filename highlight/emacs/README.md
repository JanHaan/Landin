# Landin for Emacs

Place this directory on `load-path` and `(require 'landin-mode)`. Emacs 29+
uses `landin-ts-mode` when the `landin` tree-sitter grammar is installed and
falls back to `landin-mode` otherwise. Run `M-x landin-ts-install-grammar` to
fetch and compile the grammar, then reload this package to enable the
structural mode.
