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
function _G.completion_tui_history()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  require("completion-tools").setup({
    sources = { "history" },
    ranking = { history = { enabled = true, path = vim.env.COMPLETION_TUI_STATE .. ".history" } },
    providers = {
      history = {
        complete = function(_, cb)
          cb({ items = { { label = "alpha" }, { label = "alpine" } } })
        end,
      },
    },
  })
end
function _G.completion_tui_fallback()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  require("completion-tools").setup({
    sources = { "main", "fallback" },
    timeout_ms = 40,
    providers = {
      main = {
        complete = function(_, cb)
          vim.defer_fn(function()
            cb({ items = { { label = "alWrong" } } })
          end, 250)
        end,
      },
      fallback = {
        fallback_for = { "main" },
        max_items = 1,
        complete = function(_, cb)
          cb({ items = { { label = "alphanumeric" }, { label = "alpha" } } })
        end,
      },
    },
  })
end
function _G.completion_tui_insertion()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "    blTAIL" })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.bo.expandtab, vim.bo.shiftwidth = true, 2
  require("completion-tools").setup({
    sources = { "test" },
    accept = { mode = "insert" },
    providers = {
      test = {
        complete = function(_, cb)
          cb({
            items = {
              {
                label = "block",
                insertTextFormat = 2,
                insertTextMode = 2,
                textEdit = {
                  newText = "block\n  ${1:value}\n$0",
                  insert = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 6 } },
                  replace = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 10 } },
                },
              },
            },
          })
        end,
      },
    },
  })
end
function _G.completion_tui_diagnostics()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  require("completion-tools").setup({
    sources = { "diag" },
    providers = {
      diag = {
        max_items = 1,
        complete = function(_, cb)
          vim.defer_fn(function()
            cb({ items = { { label = "alpha" }, { label = "alpine" } }, reusable = true })
          end, 100)
        end,
      },
    },
  })
  completion_diagnostics = true
end
function _G.completion_tui_manual()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  completion_manual = { calls = 0 }
  local maps = vim.deepcopy(require("completion_tools.config").defaults.keymap)
  maps["<C-Space>"] = {
    function(cmp)
      return cmp.show({ sources = { "manual" } })
    end,
  }
  require("completion-tools").setup({
    sources = {},
    keymap = maps,
    providers = {
      manual = {
        complete = function(_, callback)
          completion_manual.calls = completion_manual.calls + 1
          local function publish()
            callback({ items = { { label = "alpha" }, { label = "alpine" } } })
          end
          if completion_manual.calls == 1 then
            publish()
            vim.defer_fn(function()
              vim.api.nvim_exec_autocmds("LspAttach", { buffer = 0, data = { client_id = 999999 } })
            end, 100)
          else
            vim.defer_fn(publish, 80)
          end
        end,
      },
    },
  })
end
function _G.completion_tui_copilot(staged)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "中😀 = )" })
  vim.api.nvim_win_set_cursor(0, { 1, #"中😀 = " })
  vim.bo.filetype = "lua"
  completion_copilot = { requests = 0, cancelled = 0, accepted = {} }
  local client = { initialized = true }
  function client:is_stopped()
    return false
  end
  function client:cancel_request()
    completion_copilot.cancelled = completion_copilot.cancelled + 1
  end
  function client:request(method, params, callback)
    if method == "notifyAccepted" then
      table.insert(completion_copilot.accepted, params.uuid)
      callback()
      return true
    end
    assert(method == "getCompletionsCycling" or (staged and method == "getCompletions"))
    completion_copilot.requests = completion_copilot.requests + 1
    local id = completion_copilot.requests
    local stale = not staged and params.position.character == 8
    vim.defer_fn(function()
      local items = {}
      for i, name in ipairs({ "print", "printf", "printlog", "print_more" }) do
        items[i] = {
          text = "中😀 = " .. name .. '("' .. (stale and "stale" or "fresh") .. '")\nprint("$1")',
          uuid = tostring(id) .. ":" .. name,
          range = { start = { line = 0, character = 0 }, ["end"] = params.position },
        }
        if method == "getCompletions" then
          break
        end
      end
      callback(nil, { completions = items })
    end, staged and (method == "getCompletions" and 30 or 250) or (stale and 300 or 60))
    return true, id
  end
  local native = require("completion_tools.copilot")
  local real_new = native.new
  native.new = function()
    return {
      eligible = function()
        return true
      end,
      ensure = function(_, cb)
        cb(client)
        return function() end
      end,
      dispose = function() end,
    }
  end
  require("completion-tools").setup({
    sources = { "copilot" },
    copilot = { debounce_ms = 20, request_mode = staged and "staged" or "cycling" },
    keymap = vim.tbl_extend("force", require("completion_tools.config").defaults.keymap, {
      ["<C-l>"] = { "accept_word", "fallback" },
      ["<C-j>"] = { "accept_line", "fallback" },
    }),
    documentation = { delay_ms = 0 },
  })
  native.new = real_new
end
function _G.completion_tui_triggers()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.bo.filetype = "lua"
  require("completion-tools").setup({
    sources = { "fixture" },
    min_keyword_length = 0,
    trigger_characters = function(ctx)
      return ctx.filetype == "tex" and { ".", "\\", "{" } or { "." }
    end,
    providers = {
      fixture = {
        trigger = function()
          return true
        end,
        complete = function(_, callback)
          callback({ items = { { label = "alpha" } } })
        end,
      },
    },
  })
end
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
                documentation = {
                  kind = "markdown",
                  value = "```latex\n\\input{中文}\n```\n\nUse `path`.\n\n---\n\n@*param* `path` — **Target** file.",
                },
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
function _G.completion_tui_files()
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
                label = "TeX/0_Abstract.tex",
                kind = 17,
                detail = "/Users/test/Research/Papers/Very_Long_Project/TeX/0_Abstract.tex",
              },
              {
                label = "TeX/4_Experimental_Results.tex",
                kind = 17,
                labelDetails = {
                  description = "/Users/test/Research/Papers/Very_Long_Project/TeX/4_Experimental_Results.tex",
                },
              },
            },
          })
        end,
      },
    },
  })
end
function _G.completion_tui_flicker()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.bo.filetype = "lua"
  require("completion-tools").setup({
    sources = { "fast", "slow" },
    documentation = { delay_ms = 5 },
    providers = {
      fast = {
        complete = function(_, cb)
          cb({ items = { { label = "zzzz" } } })
        end,
      },
      slow = {
        complete = function(ctx, cb)
          vim.defer_fn(function()
            cb({ items = { { label = "abcdefghijResult", detail = "function abcdefghijResult()" } } })
          end, ctx.prefix == "a" and 5 or 120)
        end,
      },
    },
  })
  completion_flicker = { active = true, samples = 0, hidden = 0, blank = 0, closed = 0 }
  vim.api.nvim_create_autocmd("InsertLeave", {
    once = true,
    callback = function()
      completion_flicker.active = false
    end,
  })
end
function _G.completion_tui_height()
  local lines = {}
  for i = 1, 32 do
    lines[i] = ""
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 26, 0 })
  vim.cmd("normal! zt")
  vim.cmd("normal! 25\25")
  require("completion-tools").setup({
    sources = { "fast", "slow" },
    -- Leave enough margin for the terminal polling loop's 45 ms input cadence.
    -- The default 50 ms deadline is covered by attached-UI and unit tests.
    menu = { shrink_delay_ms = 150 },
    documentation = { auto_show = false },
    providers = {
      fast = {
        complete = function(ctx, cb)
          local items = {}
          for i = 1, (ctx.prefix == "a" and 12 or 2) do
            items[i] = {
              label = ctx.prefix .. "Fast" .. i .. (ctx.prefix == "a" and string.rep("Long", 6) or ""),
              kind = ctx.prefix == "a" and 25 or 1,
              labelDetails = ctx.prefix == "a" and { description = "module" } or nil,
            }
          end
          cb({ items = items })
        end,
      },
      slow = {
        complete = function(ctx, cb)
          vim.defer_fn(function()
            local items = {}
            if #ctx.prefix % 2 == 1 then
              for i = 1, 10 do
                items[i] = { label = ctx.prefix .. "Slow" .. i }
              end
            end
            cb({ items = items })
          end, 25)
        end,
      },
    },
  })
end
function _G.completion_tui_selection()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  require("completion-tools").setup({
    sources = { "fast", "slow" },
    documentation = { auto_show = false },
    providers = {
      fast = {
        complete = function(_, cb)
          cb({ items = { { label = "alpha" }, { label = "alphaZ" } } })
        end,
      },
      slow = {
        score_offset = 1000,
        complete = function(_, cb)
          vim.defer_fn(function()
            cb({ items = { { label = "alphaLsp" } } })
          end, 250)
        end,
      },
    },
  })
end
function _G.completion_tui_paging()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  completion_paging_calls = 0
  local function page(method)
    return function(cmp)
      completion_paging_calls = completion_paging_calls + 1
      return cmp[method]({ count = 5, wrap = false })
    end
  end
  local maps = { ["<A-d>"] = { page("select_next") }, ["<A-u>"] = { page("select_prev") } }
  local items = {}
  for i = 1, 8 do
    items[i] = { label = string.format("alpha%02d", i) }
    vim.api.nvim_create_user_command(string.format("CompletionPaging%02d", i), function() end, {})
  end
  require("completion-tools").setup({
    sources = { "paging" },
    keymap = maps,
    cmdline = { enabled = true, keymap = maps },
    providers = { paging = {
      complete = function(_, cb)
        cb({ items = items })
      end,
    } },
  })
end
function _G.completion_tui_dictionary()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  local path = vim.fn.tempname()
  vim.fn.writefile({ "apple" }, path)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      vim.fn.delete(path)
    end,
  })
  require("completion-tools").setup({
    sources = { "dictionary" },
    documentation = { delay_ms = 5 },
    dictionary = {
      files = { path },
      documentation = { command = vim.fn.getcwd() .. "/tests/dictionary_command.py" },
    },
  })
end
function _G.completion_tui_cmdline()
  vim.bo.filetype = "lua"
  vim.o.wildoptions = "tagfile"
  require("completion-tools").setup({ sources = {}, cmdline = { enabled = true } })
  local path = vim.fn.tempname()
  vim.fn.mkdir(path .. "/doc", "p")
  vim.fn.writefile({ "*CompletionTui-local-Help* command-line color fixture" }, path .. "/doc/fixture.txt")
  vim.cmd("helptags " .. vim.fn.fnameescape(path .. "/doc"))
  vim.opt.runtimepath:prepend(path)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      vim.fn.delete(path, "rf")
    end,
  })
  vim.api.nvim_set_hl(0, "CompletionToolsKindReference", { fg = "#c0c0c0" })
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
      columns = vim.o.columns,
      visible = cmp.is_menu_visible(),
      selected = (cmp.get_selected_item() or {}).label,
      first = (cmp.get_items()[1] or {}).label,
      paging_calls = completion_paging_calls,
      error = vim.v.errmsg,
      cmdline = vim.fn.getcmdline(),
      wildoptions = vim.o.wildoptions,
      executed = vim.g.completion_tui_executed,
      can_accept = cmp._can("accept") == true,
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
          local selected_row = vim.api.nvim_win_get_cursor(win)[1]
          data.menu = {
            row = geometry.row,
            height = geometry.height,
            width = geometry.width,
            win = win,
            cursor = selected_row,
          }
          local b = vim.api.nvim_win_get_buf(win)
          local line = vim.api.nvim_buf_get_lines(b, selected_row - 1, selected_row, false)[1]
          local top = vim.fn.screenpos(win, 1, 1)
          local at = vim.fn.screenpos(win, selected_row, 1)
          data.menu_line = line
          data.menu_rows = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          data.menu_blank_screen = ""
          for row, text in ipairs(data.menu_rows) do
            if text == "" then
              for col = at.col, at.col + geometry.width - 1 do
                data.menu_blank_screen = data.menu_blank_screen .. vim.fn.screenstring(top.row + row - 1, col)
              end
            end
          end
          data.menu_source_attrs = {}
          data.copilot_marks = {}
          for _, mark in
            ipairs(
              vim.api.nvim_buf_get_extmarks(
                b,
                vim.api.nvim_create_namespace("completion-tools-menu"),
                0,
                -1,
                { details = true }
              )
            )
          do
            if mark[4].hl_group == "CompletionToolsCopilot" then
              local row = tostring(mark[2] + 1)
              data.copilot_marks[row] = (data.copilot_marks[row] or 0) + 1
            end
            if mark[2] == selected_row - 1 and mark[4].hl_group == "CompletionToolsSource" then
              if line:sub(mark[3] + 1, mark[4].end_col) == "fast" then
                data.menu_source_col = mark[3]
              end
              local cell = vim.fn.strdisplaywidth(line:sub(1, mark[3]))
              data.menu_source_attrs[#data.menu_source_attrs + 1] = vim.fn.screenattr(at.row, at.col + cell)
            end
          end
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
            "CompletionTui",
            "local",
            "-",
            "Help",
            "Reference",
            "Users",
            "Project",
            "Abstract",
            ".tex",
          }) do
            local first = line:find(word, 1, true)
            if first then
              local cell = vim.fn.strdisplaywidth(line:sub(1, first - 1))
              data.menu_attrs[word] = vim.fn.screenattr(at.row, at.col + cell)
            end
          end
        elseif vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "markdown" then
          data.doc_win = win
          data.doc_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
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
    if completion_flicker and completion_flicker.active then
      local stats = completion_flicker
      if
        not stats.menu
        and data.menu
        and data.doc_win
        and data.menu_screen:find("abcdefghijResult", 1, true)
        and data.doc_screen:find("abcdefghijResult", 1, true)
      then
        stats.menu, stats.doc = data.menu.win, data.doc_win
        vim.api.nvim_create_autocmd("WinClosed", {
          pattern = { tostring(stats.menu), tostring(stats.doc) },
          callback = function()
            if stats.active and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
              stats.closed = stats.closed + 1
            end
          end,
        })
      end
      if stats.menu then
        stats.samples = stats.samples + 1
        if not data.visible or not data.menu or data.menu.win ~= stats.menu or data.doc_win ~= stats.doc then
          stats.hidden = stats.hidden + 1
        elseif not data.menu_screen:find("abcdefghijResult", 1, true) then
          stats.blank = stats.blank + 1
        end
      end
    end
    data.flicker = completion_flicker
    data.manual = completion_manual
    data.copilot = completion_copilot
    data.lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if completion_diagnostics then
      data.diagnostics = cmp.get_status()
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
