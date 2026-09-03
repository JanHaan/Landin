# Landin for Neovim

Run `make -C highlight/nvim`, then add `highlight/nvim` to `runtimepath` (or
use it as the `rtp` of a local plugin). The package registers `.ldn`, loads the
compiled parser, and supplies highlighting, indentation, folds, locals, and
text objects. The checked-in queries are synchronized with `../tree-sitter`.

The parser targets current Neovim's built-in tree-sitter interface; the Vim
package in `../vim` remains the fallback for installations without it.
