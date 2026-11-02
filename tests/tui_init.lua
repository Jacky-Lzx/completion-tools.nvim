dofile("tests/minimal_init.lua")
local lines = { "alpha alphabet alphanumeric" }
for i = 2, 80 do
  lines[i] = ""
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 80, 0 })
vim.cmd("normal! zb")
require("completion-tools").setup({ sources = { "buffer" }, min_keyword_length = 0 })
vim.api.nvim_set_hl(0, "Comment", { fg = "#a0a0a0" })
function _G.completion_tui_semantic()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  require("completion-tools").setup({
    sources = { "fixture" },
    documentation = { auto_show = false },
    menu = { highlight = { treesitter = false } },
    providers = {
      fixture = {
        complete = function(_, callback)
          callback({
            items = {
              {
                label = "decode",
                kind = 3,
                labelDetails = { detail = "(value: string): number", description = "模块" },
              },
            },
          })
        end,
      },
    },
  })
  vim.api.nvim_set_hl(0, "CompletionToolsKindFunction", { fg = "#ef4545" })
  vim.api.nvim_set_hl(0, "@type.builtin", { fg = "#34d399" })
  vim.api.nvim_set_hl(0, "@variable.parameter", { fg = "#61afef" })
  vim.api.nvim_set_hl(0, "CompletionToolsSelected", { bg = "#123456" })
end
function _G.completion_tui_snippet()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.bo.filetype = "tex"
  require("completion-tools").setup({
    sources = { "fixture" },
    documentation = { delay_ms = 5 },
    providers = {
      fixture = {
        complete = function(_, callback)
          callback({
            items = {
              {
                label = "ignore",
                kind = 15,
                detail = "\\ignore{value}",
                documentation = { kind = "markdown", value = "```latex\n\\input{中文}\n```\n\nUse `path`." },
              },
            },
          })
        end,
      },
    },
  })
  vim.api.nvim_set_hl(0, "Special", { fg = "#c678dd" })
  vim.api.nvim_set_hl(0, "@function", { fg = "#56b6c2" })
end
function _G.completion_tui_cmdline()
  require("completion-tools").setup({ sources = {}, cmdline = { enabled = true } })
  vim.api.nvim_create_user_command("CompletionTuiAlpha", function()
    vim.g.completion_tui_executed = "alpha"
  end, {})
  vim.api.nvim_create_user_command("CompletionTuiAlpine", function()
    vim.g.completion_tui_executed = "alpine"
  end, {})
end
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
      error = vim.v.errmsg,
      cmdline = vim.fn.getcmdline(),
      executed = vim.g.completion_tui_executed,
    }
    if data.mode == "c" then
      data.cmdline_screen = ""
      for col = 1, vim.o.columns do
        data.cmdline_screen = data.cmdline_screen .. vim.fn.screenstring(vim.o.lines, col)
      end
    end
    local ctx = cmp.get_context()
    if ctx then
      data.prefix = ctx.prefix
      data.input_row = ctx.mode == "cmdline" and vim.o.lines - 1
        or vim.fn.screenpos(ctx.winid, ctx.row + 1, ctx.col + 1).row - 1
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "completion-tools-menu" then
          local geometry = vim.api.nvim_win_get_config(win)
          data.menu = { row = geometry.row, height = geometry.height }
          local b = vim.api.nvim_win_get_buf(win)
          local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
          local at = vim.fn.screenpos(win, 1, 1)
          data.menu_line = line
          data.menu_screen = ""
          for col = at.col, at.col + geometry.width - 1 do
            data.menu_screen = data.menu_screen .. vim.fn.screenstring(at.row, col)
          end
          data.menu_attrs = {}
          for _, word in ipairs({
            "alpha",
            "pha",
            "Text",
            "decode",
            "code",
            "string",
            "ignore",
            "ore",
            "Snippet",
          }) do
            local first = line:find(word, 1, true)
            if first then
              local cell = vim.fn.strdisplaywidth(line:sub(1, first - 1))
              data.menu_attrs[word] = vim.fn.screenattr(at.row, at.col + cell)
            end
          end
        elseif vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "markdown" then
          local geometry = vim.api.nvim_win_get_config(win)
          local at = vim.fn.screenpos(win, 1, 1)
          data.doc_screen = ""
          for row = at.row, at.row + geometry.height - 1 do
            for col = at.col, at.col + geometry.width - 1 do
              data.doc_screen = data.doc_screen .. vim.fn.screenstring(row, col)
            end
            data.doc_screen = data.doc_screen .. "\n"
          end
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
