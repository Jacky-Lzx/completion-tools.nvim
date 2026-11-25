vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("completion_tools")
local api = vim.api
local cold = { commands = api.nvim_get_commands({}), handlers = api.nvim_get_autocmds({}) }
assert(plugin.get_config("max_items") == 50)
plugin.validate_config({ "menu", "max_height" }, 15)
assert(plugin.get_config("menu", "max_height") == 12)
assert(vim.deep_equal(cold.commands, api.nvim_get_commands({})))
assert(vim.deep_equal(cold.handlers, api.nvim_get_autocmds({})))

local has = vim.fn.has
vim.fn.has = function(feature)
  if feature == "nvim-0.12" then
    return 0
  end
  return has(feature)
end
for _, opts in ipairs({ false, { max_items = -1 } }) do
  local ok, err = pcall(plugin.setup, opts)
  assert(not ok and err:find("completion-tools requires Neovim 0.12+", 1, true), tostring(err))
end
vim.fn.has = has

local options = { sources = {}, max_items = 9, cmdline = { enabled = false, sources = { ["/"] = {} } } }
local caller = vim.deepcopy(options)
plugin.setup(options)
assert(vim.deep_equal(caller, options), "setup mutated caller configuration")
local snapshot = plugin.get_config()
assert(snapshot.max_items == 9 and vim.deep_equal(snapshot.sources, {}))
assert(vim.deep_equal(snapshot.cmdline.sources, { [":"] = { "cmdline" }, ["/"] = {}, ["?"] = { "buffer" } }))
assert(snapshot._keymap_bindings == nil and snapshot.cmdline._keymap_bindings == nil)
snapshot.cmdline.sources["/"][1] = "buffer"
assert(vim.deep_equal(plugin.get_config("cmdline", "sources", "/"), {}))
local commands = vim.api.nvim_get_commands({})
local handlers = vim.api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, false), "setup(false) must reject an invalid configuration type")
assert(vim.deep_equal(commands, vim.api.nvim_get_commands({})), "Invalid setup replaced commands")
assert(vim.deep_equal(handlers, vim.api.nvim_get_autocmds({})), "Invalid setup replaced handlers")
plugin.setup(caller)
assert(#vim.api.nvim_get_autocmds({}) == #handlers, "Repeated setup duplicated automatic handlers")
print("completion-tools.nvim: setup version guard, input isolation and registration lifetime passed")

local before = plugin.get_status()
local saved = plugin.get_config()
assert(not pcall(plugin.setup, { max_items = -1 }))
local ok, err = pcall(plugin.validate_config, { "menu", "max_width" }, 1)
assert(not ok and tostring(err):find("min_width must not exceed max_width", 1, true))
assert(not pcall(plugin.validate_config, { "cmdline", "sources", "/" }, "buffer"))
plugin.validate_config({ "max_items" }, 10)
assert(vim.deep_equal(saved, plugin.get_config()))
assert(vim.deep_equal(before, plugin.get_status()))
plugin.dispose()
plugin.dispose()
assert(not plugin.get_status().configured and not plugin.get_status().menu_visible)
assert(vim.fn.exists("#CompletionTools") == 0)
assert(plugin.get_config("max_items") == 50)
plugin.setup(caller)
plugin.dispose()
