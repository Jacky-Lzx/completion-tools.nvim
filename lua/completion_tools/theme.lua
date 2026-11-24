-- Optional theme service. Standalone completion uses the active Statement color.
local resolve_highlight = require("base_tools.highlight").resolve

local M = {}
local palette, stop

local function apply()
  local api = vim.api
  local menu = resolve_highlight("Pmenu")
  local border = resolve_highlight("FloatBorder")
  local float = resolve_highlight("NormalFloat")
  local c = palette and palette.ui
  local menu_bg = c and c.menu_bg or menu.bg or "NONE"
  local float_bg = c and c.float_bg or float.bg or "NONE"
  local border_fg = c and c.border or border.fg
  local groups = {
    Copilot = palette and { fg = palette.palette.purple } or { link = "Statement" },
    Menu = { fg = c and c.menu_fg or menu.fg, bg = menu_bg },
    Border = { fg = border_fg, bg = menu_bg },
    Doc = { fg = c and c.float_fg or float.fg, bg = float_bg },
    DocBorder = { fg = border_fg, bg = float_bg },
  }

  for name, value in pairs(groups) do
    local public, private = "CompletionTools" .. name, "CompletionToolsDefault" .. name
    api.nvim_set_hl(0, private, value)

    local empty = vim.tbl_isempty(api.nvim_get_hl(0, { name = public, create = false }))
    api.nvim_set_hl(0, public, { link = private, default = not empty })
  end
end

function M.highlights()
  local themes = package.loaded.theme_tools
  if not stop and type(themes) == "table" and type(themes.on_change) == "function" then
    stop = themes.on_change("completion-tools", function(value)
      palette = value
      apply()
    end)
  end

  apply()
end

function M.dispose()
  if stop then
    stop()
  end

  palette, stop = nil, nil
end

return M
