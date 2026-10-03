# Landin for Zed

Install this directory as a Zed dev extension. It associates `.ldn`, fetches
the grammar from this repository's `highlight/tree-sitter` subdirectory, and
provides highlighting, brackets, indentation, and outline items. The grammar
revision is pinned to the commit containing this package's grammar and queries.
After changing either, update `extension.toml` to a commit containing the
changes before distributing the extension.

The extension also starts `refine lsp`, the compiler's language server, for
Landin buffers: diagnostics, go to definition, hover, formatting and quick
fixes. `refine` must be on the path of the shell Zed opens the project in;
nothing is downloaded. Zed compiles `src/landin.rs` to WebAssembly when the
dev extension is installed, which needs Rust from rustup, as Zed's extension
documentation says. The repository's check builds it for `wasm32-wasip2`
when such a Rust is present; it does not run Zed.
