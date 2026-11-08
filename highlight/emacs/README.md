# Landin for Emacs

Place this directory on `load-path` and `(require 'landin-mode)`. That
gives `landin-mode`, the regex-based mode, on any Emacs. Emacs 29+ uses
`landin-ts-mode` instead when the `landin` tree-sitter grammar is installed
and loads: the grammar is generated at tree-sitter ABI 15, so the Emacs
must be linked with a tree-sitter library that reads ABI 15 (0.25 or
later; `M-x eval-expression` of `(treesit-library-abi-version)` gives 15 or more).
Where it does not, `treesit-ready-p` refuses the grammar with a warning
and `.ldn` files open in `landin-mode`. Run `M-x landin-ts-install-grammar`
to fetch and compile the grammar, then reload this package to enable the
structural mode. The installer defaults to the commit matching this package's
grammar. After committing a change to the grammar,
`python3 highlight/grammar_pin.py` moves `landin-treesit-revision`, and the
Helix and Zed revisions, to that commit before the package is distributed.

The package registers `refine lsp`, the compiler's language server, with
Eglot. With `refine` on the path, `M-x eglot` in a Landin buffer starts it:
diagnostics through Flymake, `xref-find-definitions`, Eldoc hover,
`eglot-format-buffer` and `eglot-code-actions` for its quick fixes. To start
it every time, add `eglot-ensure` to `landin-mode-hook`.
