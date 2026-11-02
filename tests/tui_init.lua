dofile("tests/minimal_init.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha alphabet alphanumeric", "" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
require("completion-tools").setup({ sources = { "buffer" } })
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
    vim.fn.writefile({ vim.json.encode(data) }, vim.env.COMPLETION_TUI_STATE)
  end)
)
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    timer:stop()
    timer:close()
  end,
})
