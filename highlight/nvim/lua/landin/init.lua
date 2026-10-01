local M = {}

-- `opts.lsp = false` leaves the language server alone; by default it is
-- enabled when Neovim has `vim.lsp.enable` and `refine` is on the path.
function M.setup(opts)
  opts = opts or {}
  vim.filetype.add({ extension = { ldn = "landin" } })
  vim.treesitter.language.register("landin", "landin")
  if opts.lsp ~= false and vim.lsp.enable and vim.fn.executable("refine") == 1 then
    vim.lsp.enable("refine")
  end
end

return M
