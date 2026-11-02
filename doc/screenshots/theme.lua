-- A local screenshot theme; this never changes the user's Neovim configuration.
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "no"
vim.o.laststatus = 2
vim.o.showmode = false
vim.o.ruler = false
vim.o.fillchars = "eob: "
vim.o.statusline = "  completion-tools.nvim  %=%t   %l:%c  "
vim.cmd("syntax enable")
local groups = {
  Normal = { fg = "#c0caf5", bg = "#1a1b26" },
  NormalFloat = { fg = "#c0caf5", bg = "#202330" },
  FloatBorder = { fg = "#565f89", bg = "#202330" },
  PmenuSel = { bg = "#343b58" },
  LineNr = { fg = "#565f89" },
  StatusLine = { fg = "#7aa2f7", bg = "#24283b", bold = true },
  StatusLineNC = { fg = "#7aa2f7", bg = "#24283b" },
  Comment = { fg = "#737da5", italic = true },
  String = { fg = "#9ece6a" },
  Number = { fg = "#ff9e64" },
  Function = { fg = "#7aa2f7" },
  Statement = { fg = "#bb9af7" },
  Type = { fg = "#2ac3de" },
  Special = { fg = "#bb9af7" },
  Identifier = { fg = "#c0caf5" },
  ["@variable.parameter"] = { fg = "#e0af68" },
  ["@type.builtin"] = { fg = "#2ac3de" },
}
for group, value in pairs(groups) do
  vim.api.nvim_set_hl(0, group, value)
end
