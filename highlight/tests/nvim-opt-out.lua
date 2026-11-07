-- Exercise both user setup orders and an explicit re-enable without a server.
local landin = require("landin")
local calls = {}
vim.fn.executable = function() return 1 end
vim.lsp.enable = function(name, enabled)
  assert(name == "refine")
  calls[#calls + 1] = enabled ~= false
end
landin.setup({ lsp = false })
vim.cmd("runtime plugin/landin.lua") -- automatic setup after explicit setup
assert(calls[#calls] == false)
landin.setup({ lsp = true })
assert(calls[#calls] == true)
landin.setup({ lsp = false }) -- explicit setup after automatic setup
assert(calls[#calls] == false)
vim.cmd("quitall!")
