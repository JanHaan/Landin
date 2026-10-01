# Landin for Vim

Copy this directory to `~/.vim/pack/landin/start/landin`, or point a Vim
package manager at `highlight/vim` in this repository. It provides `.ldn`
file detection, comments, syntax colours, matching suffixes, and indentation.

Neovim can also use this package as a regex fallback; its structural package
is in `../nvim`.

With [vim-lsp](https://github.com/prabirshrestha/vim-lsp) installed and
`refine` on the path, the package also registers `refine lsp`, the
compiler's language server: diagnostics, `:LspDefinition`, `:LspHover`,
`:LspDocumentFormat` and `:LspCodeAction` for its quick fixes. Without
vim-lsp it does nothing more.
