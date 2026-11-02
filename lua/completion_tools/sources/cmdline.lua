local M = {}
local kinds = {
  command = 3,
  option = 10,
  lua = 6,
  expression = 6,
  var = 6,
  environment = 6,
  file = 17,
  file_in_path = 17,
  buffer = 17,
  diff_buffer = 17,
  dir = 19,
  dir_in_path = 19,
  help = 18,
  color = 16,
  event = 23,
  augroup = 9,
  highlight = 7,
  ["function"] = 3,
  filetype = 14,
}
function M.new()
  return {
    complete = function(ctx, callback)
      local ok, matches = pcall(vim.fn.getcompletion, ctx.before, "cmdline", true)
      local items = {}
      local kind = kinds[ctx.completion_type] or (ctx.command and ctx.command:match("^set") and 10) or 1
      for index, label in ipairs(ok and matches or {}) do
        local text = label
        -- getcmdcomplpat() can include the no/inv prefix when the cursor is
        -- inside a command with a suffix. Native getcompletion() strips it.
        if kind == 10 and ctx.command and ctx.command:match("^set") then
          local flag = ctx.prefix:match("^inv") or ctx.prefix:match("^no")
          if flag and label:sub(1, #ctx.prefix) ~= ctx.prefix then
            text = flag .. label
          end
        end
        if kind == 17 or kind == 19 then
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
        items[#items + 1] = {
          label = label,
          insertText = text,
          kind = label:sub(-1) == "/" and 19 or kind,
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
