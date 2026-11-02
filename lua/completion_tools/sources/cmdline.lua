local M = {}
function M.new()
  return {
    complete = function(ctx, callback)
      -- Shell command completion can execute external helpers. Leave it to Vim.
      if ctx.before:match("^%s*[%%0-9,'<>%-]*!") then
        callback({ items = {} })
        return
      end
      local ok, matches = pcall(vim.fn.getcompletion, ctx.before, "cmdline", false)
      local items = {}
      for _, label in ipairs(ok and matches or {}) do
        items[#items + 1] = { label = label }
      end
      callback({ items = items })
    end,
  }
end
return M
