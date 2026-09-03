local M = {}

function M.setup()
  vim.filetype.add({ extension = { ldn = "landin" } })
  vim.treesitter.language.register("landin", "landin")
end

return M
