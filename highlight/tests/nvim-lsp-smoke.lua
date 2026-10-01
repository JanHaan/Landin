-- Starts `refine lsp` through the package and waits for the type error in
-- LANDIN_FIXTURE to arrive as a diagnostic with its catalogue code.  Needs
-- `refine` on the path; `../test.sh` runs it when LANDIN_REFINE names one.
local function smoke()
  require("landin").setup()
  vim.cmd.edit(vim.fn.fnameescape(assert(os.getenv("LANDIN_FIXTURE"))))
  assert(vim.bo.filetype == "landin", "Landin filetype was not detected")
  local found = vim.wait(20000, function()
    for _, item in ipairs(vim.diagnostic.get(0)) do
      if item.code == "L0301" and item.source == "refine" then
        return true
      end
    end
    return false
  end, 50)
  assert(found, "refine lsp published no L0301 diagnostic")
  local clients = vim.lsp.get_clients({ bufnr = 0, name = "refine" })
  assert(#clients == 1, "the refine client is not attached")
end

local ok, message = xpcall(smoke, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(message)
  vim.cmd("cquit 1")
else
  vim.cmd("quitall!")
end
