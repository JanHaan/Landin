# Landin for Zed

Install this directory as a Zed dev extension. It associates `.ldn`, fetches
the grammar from this repository's `highlight/tree-sitter` subdirectory, and
provides highlighting, brackets, indentation, and outline items. The grammar
revision is pinned to the commit containing this package's grammar and queries.
After committing a change to either, `python3 highlight/grammar_pin.py` moves
the revision in `extension.toml`, and in the Helix and Emacs packages, to that
commit before the extension is distributed.

The extension also starts `refine lsp`, the compiler's language server, for
Landin buffers: diagnostics, go to definition, hover, formatting and quick
fixes. `refine` must be on the path of the shell Zed opens the project in;
nothing is downloaded. Zed compiles `src/landin.rs` to WebAssembly when the
dev extension is installed, which needs Rust from rustup, as Zed's extension
documentation says. No check of this repository builds it or runs Zed:
`../test.sh` compiles this package's queries, the outline among them,
against the grammar, and `../test_adapters.py` holds the manifest and the
two names the source starts the server by.
