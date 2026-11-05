-- Optional theme service. Standalone completion uses the active Statement color.
local M = {}
local palette, stop
local function apply()
  local api = vim.api
  api.nvim_set_hl(
    0,
    "CompletionToolsDefaultCopilot",
    palette and { fg = palette.palette.purple } or { link = "Statement" }
  )
  local empty = vim.tbl_isempty(api.nvim_get_hl(0, { name = "CompletionToolsCopilot", create = false }))
  api.nvim_set_hl(
    0,
    "CompletionToolsCopilot",
    { link = "CompletionToolsDefaultCopilot", default = not empty }
  )
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
