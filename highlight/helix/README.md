# Landin for Helix

Merge `languages.toml` into the Helix language configuration, copy
`runtime/queries/landin` into the matching runtime directory, then run
`hx --grammar fetch` and `hx --grammar build`. The grammar source is pinned to
the commit that contains this package's queries. After changing the grammar
or queries, update the revision in `languages.toml` to a commit containing
those changes. For testing uncommitted changes, replace the grammar source
with an absolute `path` to `../tree-sitter`. The query set supplies highlights plus
indentation, folds, and text objects.

`languages.toml` also names `refine lsp`, the compiler's language server, as
Landin's: with `refine` on the path Helix shows its diagnostics and offers
go to definition, hover, `:format` and its quick fixes. A module's imports
are found under the workspace root, the nearest directory holding `.git`.
Formatting on save is left off, as Helix's default is; `auto-format = true`
turns it on.
