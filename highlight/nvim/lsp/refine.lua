-- `refine lsp`, the Landin compiler's language server: diagnostics,
-- definitions, hover, formatting and quick fixes from the compiler's own
-- stages.  Neovim 0.11 and later read this file for `vim.lsp.config`; the
-- package enables it when `refine` is on the path.  A module's imports are
-- found under the workspace root.  Use a Git root when there is one;
-- otherwise use Neovim's working directory for files beneath it, or the
-- file's directory when it was opened from elsewhere.
return {
  cmd = { "refine", "lsp" },
  filetypes = { "landin" },
  root_dir = function(bufnr, on_dir)
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
      return
    end

    local git = vim.fs.root(bufnr, ".git")
    if git then
      on_dir(git)
      return
    end

    local cwd = vim.fn.getcwd()
    if file:sub(1, #cwd + 1) == cwd .. "/" then
      on_dir(cwd)
    else
      on_dir(vim.fs.dirname(file))
    end
  end,
}
