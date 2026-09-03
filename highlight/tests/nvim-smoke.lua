local function smoke()
  require("landin").setup()
  vim.cmd.edit(vim.fn.fnameescape(assert(os.getenv("LANDIN_FIXTURE"))))
  assert(vim.bo.filetype == "landin", "Landin filetype was not detected")
  local trees = vim.treesitter.get_parser(0, "landin"):parse()
  assert(trees[1] and not trees[1]:root():has_error(), "Landin parse has an error node")
  assert(vim.treesitter.query.get("landin", "highlights"), "highlight query did not load")
end

local ok, message = xpcall(smoke, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(message)
  vim.cmd("cquit 1")
else
  vim.cmd("quitall!")
end
