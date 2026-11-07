vim.opt.rtp:prepend(vim.fn.getcwd())
local select = require("completion_tools.source_selection")
assert(not package.loaded.completion_tools)
local config = {
  default = { "lsp", "buffer" },
  providers = { lsp = {}, buffer = {}, copilot = {} },
  groups = { { "buffer" }, { "lsp" } },
}
local first = vim.api.nvim_get_current_buf()
local second = vim.api.nvim_create_buf(false, true)
local ctx = { bufnr = second }
assert(vim.deep_equal(select.cycle(config, -1, ctx), { "lsp" }))
assert(vim.deep_equal(select.active_sources(config), config.default))
local copy = select.sources(config)
copy[1] = "bad"
assert(config.default[1] == "lsp")
assert(vim.deep_equal(select.toggle_source(config, "copilot", ctx), { "copilot", "lsp", "buffer" }))
assert(vim.b[first].completion_tools_sources == nil)
select.cycle(config, 1, ctx)
assert(vim.deep_equal(select.active_sources(config, ctx), { "buffer" }))
select.toggle_source(config, "buffer", ctx)
assert(vim.deep_equal(select.active_sources(config, ctx), { "copilot", "lsp" }))
assert(not pcall(select.toggle_source, config, "unknown"))
select.reset(ctx)
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
