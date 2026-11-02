local M = {}
function M.new(opts)
  local worker = require("completion_tools.worker").new()
  local warn = require("completion_tools.worker").warnings("dictionary")
  return {
    score_offset = 5,
    complete = function(ctx, callback)
      if #ctx.prefix < opts.min_keyword_length then
        callback({ items = {} })
        return
      end
      local files = type(opts.files) == "function" and opts.files(ctx) or opts.files
      local paths, seen = {}, {}
      for _, file in ipairs(files) do
        local path = vim.fn.fnamemodify(vim.fs.normalize(file), ":p")
        if not seen[path] then
          seen[path], paths[#paths + 1] = true, path
        end
      end
      if #paths == 0 then
        callback({ items = {} })
        return
      end
      local payload = {
        kind = "dictionary",
        files = paths,
        query = ctx.prefix,
        max_items = opts.max_items,
        max_bytes = opts.max_bytes,
        max_words = opts.max_words,
        max_word_bytes = opts.max_word_bytes,
        matching = opts.matching,
        capitalize = opts.capitalize,
      }
      return worker.request(payload, function(result)
        warn(result)
        callback({ items = result.items or {} })
      end, 0, opts.timeout_ms)
    end,
    dispose = worker.dispose,
  }
end
return M
