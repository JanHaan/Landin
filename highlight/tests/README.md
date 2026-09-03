# Isolated highlighting fixtures

These fixtures belong to the highlighting packages, not to the compiler test
corpus. `lexical.ldn` stresses colours, including syntax not yet enabled by the
bootstrap compiler. `structural.ldn` is accepted by the tree-sitter grammar
and exercises declarations, nesting, contextual words, calls and control flow.

`textmate-smoke.mjs` feeds the lexical fixture to VS Code's actual TextMate
engine. `vim-smoke.vim` and `emacs-smoke.el` open it in a real editor and
assert file recognition, comment settings, and representative syntax groups.
`../test.sh` runs them when their small test dependencies or editors are
installed. Nothing here builds or invokes `refine`.
