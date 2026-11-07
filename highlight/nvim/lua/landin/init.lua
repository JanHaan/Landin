local M = {}
local lsp_enabled = true

-- `opts.lsp = false` disables this configuration; by default it is
-- enabled when Neovim has `vim.lsp.enable` and `refine` is on the path.
function M.setup(opts)
  opts = opts or {}
  if opts.lsp ~= nil then lsp_enabled = opts.lsp end
  vim.filetype.add({ extension = { ldn = "landin" } })
  vim.treesitter.language.register("landin", "landin")
  if vim.lsp.enable then
    if not lsp_enabled then
      vim.lsp.enable("refine", false)
    elseif vim.fn.executable("refine") == 1 then
      vim.lsp.enable("refine")
    end
  end
end

return M
