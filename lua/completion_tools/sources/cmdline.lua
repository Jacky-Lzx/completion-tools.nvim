local M = {}
local CompletionItemKind = require("vim.lsp.protocol").CompletionItemKind
local kinds = require("completion_tools.kinds")

local completion_kinds = {
  command = CompletionItemKind.Function,
  option = CompletionItemKind.Property,
  lua = CompletionItemKind.Variable,
  expression = CompletionItemKind.Variable,
  var = CompletionItemKind.Variable,
  environment = CompletionItemKind.Variable,
  file = CompletionItemKind.File,
  file_in_path = CompletionItemKind.File,
  buffer = CompletionItemKind.File,
  diff_buffer = CompletionItemKind.File,
  dir = CompletionItemKind.Folder,
  dir_in_path = CompletionItemKind.Folder,
  help = CompletionItemKind.Reference,
  color = CompletionItemKind.Color,
  event = CompletionItemKind.Event,
  augroup = CompletionItemKind.Module,
  highlight = CompletionItemKind.Class,
  ["function"] = CompletionItemKind.Function,
  filetype = CompletionItemKind.Keyword,
}

function M.new(opts)
  opts = opts or {}
  return {
    complete = function(ctx, callback)
      -- getcompletion() follows wildoptions. Enable native fuzzy matching only
      -- for this synchronous call, including when a custom completer throws.
      local wildoptions = vim.o.wildoptions
      local enable_fuzzy = opts.fuzzy ~= false and not vim.tbl_contains(vim.opt.wildoptions:get(), "fuzzy")
      if enable_fuzzy then
        vim.opt.wildoptions:append("fuzzy")
      end
      local ok, matches = pcall(vim.fn.getcompletion, ctx.before, "cmdline", true)
      if enable_fuzzy then
        vim.o.wildoptions = wildoptions
      end
      local items = {}
      local kind = completion_kinds[ctx.completion_type]
        or (ctx.command and ctx.command:match("^set") and CompletionItemKind.Property)
        or CompletionItemKind.Text
      for index, label in ipairs(ok and matches or {}) do
        local text = label
        -- getcmdcomplpat() can include the no/inv prefix when the cursor is
        -- inside a command with a suffix. Native getcompletion() strips it.
        if kind == CompletionItemKind.Property and ctx.command and ctx.command:match("^set") then
          local flag = ctx.prefix:match("^inv") or ctx.prefix:match("^no")
          if flag and label:sub(1, #ctx.prefix) ~= ctx.prefix then
            text = flag .. label
          end
        end
        if kinds.is_path(kind) then
          text = vim.fn.fnameescape(label)
          if ctx.command and ctx.command:match("^set") then
            text = text:gsub("\\([ \t])", function(char)
              return string.rep("\\", 3) .. char
            end)
            text = text:gsub(",", function()
              return string.rep("\\", 2) .. ","
            end)
          end
        end
        local folder = label:sub(-1) == "/"
        items[#items + 1] = {
          label = label,
          insertText = text,
          kind = folder and CompletionItemKind.Folder or kind,
          _syntax = not folder and ctx.completion_syntax or false,
          -- Native completion already interpreted escapes, wildcards and user
          -- commands. Do not discard or reorder these results with another matcher.
          filterText = ctx.prefix,
          sortText = string.format("%08d", index),
        }
      end
      callback({ items = items })
    end,
  }
end
return M
