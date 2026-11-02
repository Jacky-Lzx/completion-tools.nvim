-- Optional adapter. Loading the engine does not load LuaSnip.
local M = {}
function M.new()
  return {
    score_offset = 30,
    complete = function(ctx, callback)
      local ls, items = require("luasnip"), {}
      local available = ls.available(function(snippet)
        return snippet
      end)
      for _, snippets in pairs(available) do
        for _, snippet in ipairs(snippets) do
          -- Pattern snippets require a separate preview/expansion policy;
          -- leave those to LuaSnip's ordinary automatic/manual expansion.
          if
            not snippet.hidden
            and not snippet.regTrig
            and (not snippet.show_condition or snippet.show_condition(ctx.before))
          then
            items[#items + 1] = {
              label = snippet.trigger,
              insertText = "",
              kind = 15,
              _snippet = snippet,
              sortText = string.format(
                "%010d",
                1000000000 - math.min(snippet.effective_priority or 1000, 1000000000)
              ) .. snippet.trigger,
            }
          end
        end
      end
      callback({ items = items })
    end,
    resolve = function(entry, callback)
      local snippet = entry.item._snippet
      local item = vim.tbl_extend("force", {}, entry.item)
      item.detail = table.concat(snippet:get_docstring(), "\n")
      item.documentation = table.concat(snippet.description or {}, "\n")
      callback(item)
    end,
    execute = function(entry, ctx)
      local snippet = entry.item._snippet
      require("luasnip").snip_expand(snippet, { expand_params = snippet:matches(ctx.before) })
    end,
  }
end
return M
