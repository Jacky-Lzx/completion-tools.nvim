local M = {}

function M.new(opts)
  if opts.preset == "luasnip" then
    return require("completion_tools.sources.luasnip").new()
  end
  return {
    score_offset = 30,
    complete = function(ctx, callback)
      local items = {}
      local collection = type(opts.collection) == "function" and opts.collection(ctx) or opts.collection
      for _, ft in ipairs({ "all", ctx.filetype }) do
        for _, snippet in ipairs(collection[ft] or {}) do
          items[#items + 1] = {
            label = snippet.prefix,
            insertText = type(snippet.body) == "table" and table.concat(snippet.body, "\n") or snippet.body,
            insertTextFormat = 2,
            kind = 15,
            detail = snippet.description,
          }
        end
      end
      callback({ items = items, reusable = true })
    end,
  }
end

return M
