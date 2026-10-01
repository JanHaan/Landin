-- `refine lsp`, the Landin compiler's language server: diagnostics,
-- definitions, hover, formatting and quick fixes from the compiler's own
-- stages.  Neovim 0.11 and later read this file for `vim.lsp.config`; the
-- package enables it when `refine` is on the path.  A module's imports are
-- found under the workspace root, the nearest directory holding `.git`.
return {
  cmd = { "refine", "lsp" },
  filetypes = { "landin" },
  root_markers = { ".git" },
}
