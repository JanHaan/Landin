# Landin for Helix

Merge `languages.toml` into the Helix language configuration, copy
`runtime/queries/landin` into the matching runtime directory, then run
`hx --grammar fetch` and `hx --grammar build`. For testing changes before they
reach `main`, replace the grammar source with an absolute `path` to
`../tree-sitter`. The query set supplies the required highlights plus
indentation, folds, and text objects.
