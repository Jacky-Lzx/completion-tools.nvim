vim.opt.rtp:prepend(vim.fn.getcwd())
local select = require("completion_tools.source_selection")
assert(not package.loaded.completion_tools)
local config = {
  default = { "lsp", "buffer" },
  providers = { lsp = {}, buffer = {}, copilot = {} },
  groups = { { "buffer" }, { name = "Code", sources = { "lsp" } } },
}
local first = vim.api.nvim_get_current_buf()
local second = vim.api.nvim_create_buf(false, true)
local ctx = { bufnr = second }
assert(vim.deep_equal(select.cycle(config, -1, ctx), { "lsp" }))
assert(select._menu_group(ctx, { "buffer" }, true) == nil)
local name, switched = select._menu_group(ctx, { "lsp" }, true)
assert(name == "Code" and switched)
name, switched = select._menu_group(ctx, nil, true)
assert(name == "Code" and not switched)
assert(select._menu_group({ bufnr = second, mode = "cmdline" }) == nil)
assert(select._menu_group() == nil)
assert(vim.deep_equal(select.active_sources(config), config.default))
local copy = select.sources(config)
copy[1] = "bad"
assert(config.default[1] == "lsp")
assert(vim.deep_equal(select.toggle_source(config, "copilot", ctx), { "copilot", "lsp", "buffer" }))
assert(select._menu_group(ctx) == nil)
assert(vim.b[first].completion_tools_sources == nil)
select.cycle(config, 1, ctx)
assert(vim.deep_equal(select.active_sources(config, ctx), { "buffer" }))
assert(select._menu_group(ctx) == "buffer")
select.toggle_source(config, "buffer", ctx)
assert(vim.deep_equal(select.active_sources(config, ctx), { "copilot", "lsp" }))
assert(not pcall(select.toggle_source, config, "unknown"))
assert(vim.deep_equal(select.cycle(config, -1, ctx), { "lsp" }))
assert(select._menu_group(ctx) == "Code")
local defaults = select.cycle(config, 1, ctx)
assert(vim.deep_equal(defaults, { "copilot", "lsp" }))
assert(select._menu_group(ctx, defaults, true) == nil)
select.cycle(config, 1, ctx)
select.reset(ctx)
assert(select._menu_group(ctx) == nil)
local dynamic = { "buffer" }
config.defaults = function()
  return dynamic
end
assert(vim.deep_equal(select.sources(config, ctx), dynamic))
dynamic = { "lsp" }
assert(vim.deep_equal(select.sources(config, ctx), dynamic))
select.toggle_source(config, "copilot", ctx)
assert(vim.deep_equal(dynamic, { "lsp" }))
assert(not package.loaded.completion_tools and not package.loaded["completion_tools.ui"])
vim.api.nvim_buf_delete(second, { force = true })
print("Source selection: explicit buffers, groups, context defaults, copies, overrides and reset passed")
