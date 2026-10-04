# Landin for Neovim

Run `make -C highlight/nvim`, then add `highlight/nvim` to `runtimepath` (or
use it as the `rtp` of a local plugin). The package registers `.ldn`, loads the
compiled parser, and supplies highlighting, indentation, folds, locals, and
text objects. The checked-in queries are synchronized with `../tree-sitter`.

The parser targets current Neovim's built-in tree-sitter interface; the Vim
package in `../vim` remains the fallback for installations without it.

With Neovim 0.11 or later and `refine` on the path, the package also starts
`refine lsp`, the compiler's language server, for every Landin buffer:
diagnostics, go to definition, hover, formatting and quick fixes. Its
configuration is `lsp/refine.lua`; `require("landin").setup({ lsp = false })`
leaves it off. A module's imports are found under the workspace root: the
nearest directory holding `.git`, or Neovim's working directory for a file
beneath it when there is no `.git`. For a file opened from elsewhere, its own
directory is the root. Start Neovim in the project directory to make sibling
modules available as imports in a project without Git.
