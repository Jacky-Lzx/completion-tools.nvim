vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd() .. "/../theme-tools.nvim"
if vim.fn.isdirectory(root) == 0 then
  print("skip optional theme-tools integration")
  return
end
vim.opt.rtp:append(root)
local api = vim.api
local completion = require("completion-tools")
completion.setup({ auto_show = false })
assert(not package.loaded.theme_tools, "completion eagerly loaded theme-tools")
local t = require("theme_tools")
t.setup({
  persist = false,
  catppuccin = false,
  dracula = false,
  icons = { default = "none" },
  default = "theme-tools-mocha",
  themes = { "theme-tools-mocha", "theme-tools-dracula", "morning" },
})
local function color()
  return api.nvim_get_hl(0, { name = "CompletionToolsCopilot", link = false }).fg
end
assert(color() == 0xcba6f7)
assert(t.set("theme-tools-dracula"))
assert(color() == 0xbd93f9)
assert(api.nvim_get_hl(0, { name = "CompletionToolsBorder", link = false }).bg == 0x21222c)
assert(not api.nvim_get_hl(0, { name = "CompletionToolsDocBorder", link = false }).bg)
api.nvim_set_hl(0, "CompletionToolsBorder", { fg = "#123456", bg = "#171720" })
t.refresh_palette()
assert(api.nvim_get_hl(0, { name = "CompletionToolsBorder", link = false }).bg == 0x171720)
local snapshot = require("theme_tools.colors").snapshot()
assert(t.set("morning"))
assert(color() == tonumber(t.palette().palette.purple:sub(2), 16))
require("theme_tools.colors").restore(snapshot)
assert(color() == 0xbd93f9)
api.nvim_set_hl(0, "CompletionToolsCopilot", { fg = "#123456" })
t.refresh_palette()
assert(color() == 0x123456)
completion.setup({ auto_show = false })
assert(color() == 0x123456)
assert(t.set("theme-tools-mocha"))
assert(color() == 0xcba6f7)
completion.dispose()
local previous = api.nvim_get_hl(0, { name = "CompletionToolsDefaultCopilot", link = false })
t.refresh_palette()
assert(vim.deep_equal(previous, api.nvim_get_hl(0, { name = "CompletionToolsDefaultCopilot", link = false })))
print(
  "completion theme: both setup orders, semantic purple, explicit overrides, restoration and cleanup passed"
)
