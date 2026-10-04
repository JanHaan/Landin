-- Starts `refine lsp` through the package and waits for type errors in
-- LANDIN_DIAGNOSTIC_FILES (or LANDIN_FIXTURE) with their catalogue code. Needs
-- `refine` on the path; `../test.sh` runs it when LANDIN_REFINE names one.
local function smoke()
  require("landin").setup()
  vim.cmd.edit(vim.fn.fnameescape(assert(os.getenv("LANDIN_FIXTURE"))))
  assert(vim.bo.filetype == "landin", "Landin filetype was not detected")
  local diagnostic_files = vim.split(
    os.getenv("LANDIN_DIAGNOSTIC_FILES") or assert(os.getenv("LANDIN_FIXTURE")), ";", { plain = true }
  )
  local found = vim.wait(20000, function()
    local remaining = {}
    for _, file in ipairs(diagnostic_files) do
      remaining[file] = true
    end
    for _, item in ipairs(vim.diagnostic.get()) do
      if item.code == "L0301" and item.source == "refine" then
        remaining[vim.api.nvim_buf_get_name(item.bufnr)] = nil
      end
    end
    return next(remaining) == nil
  end, 50)
  assert(found, "refine lsp published no L0301 diagnostic: " .. vim.inspect(vim.diagnostic.get()))
  local clients = vim.lsp.get_clients({ bufnr = 0, name = "refine" })
  assert(#clients == 1, "the refine client is not attached")
  local root = os.getenv("LANDIN_EXPECT_ROOT")
  if root then
    assert(clients[1].config.root_dir == root, "refine used the wrong workspace root")
  end
end

local ok, message = xpcall(smoke, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(message)
  vim.cmd("cquit 1")
else
  vim.cmd("quitall!")
end
