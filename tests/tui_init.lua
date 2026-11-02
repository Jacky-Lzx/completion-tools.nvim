dofile("tests/minimal_init.lua")
local lines = { "alpha alphabet alphanumeric" }
for i = 2, 80 do
  lines[i] = ""
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 80, 0 })
vim.cmd("normal! zb")
require("completion-tools").setup({ sources = { "buffer" }, min_keyword_length = 0 })
local timer = vim.uv.new_timer()
timer:start(
  10,
  10,
  vim.schedule_wrap(function()
    local cmp = require("completion-tools")
    local data = {
      line = vim.api.nvim_get_current_line(),
      mode = vim.api.nvim_get_mode().mode,
      visible = cmp.is_menu_visible(),
      selected = (cmp.get_selected_item() or {}).label,
    }
    local ctx = cmp.get_context()
    if ctx then
      data.prefix = ctx.prefix
      data.input_row = vim.fn.screenpos(ctx.winid, ctx.row + 1, ctx.col + 1).row - 1
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "completion-tools-menu" then
          local geometry = vim.api.nvim_win_get_config(win)
          data.menu = { row = geometry.row, height = geometry.height }
        end
      end
      local start = vim.fn.screenpos(ctx.winid, ctx.row + 1, ctx.start_col + 1)
      data.screen_word = ""
      for col = start.col, start.col + #ctx.prefix - 1 do
        data.screen_word = data.screen_word .. vim.fn.screenstring(data.input_row + 1, col)
      end
    end
    vim.fn.writefile({ vim.json.encode(data) }, vim.env.COMPLETION_TUI_STATE)
  end)
)
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    timer:stop()
    timer:close()
  end,
})
