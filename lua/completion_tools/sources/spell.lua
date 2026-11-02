local M = {}
function M.new(opts)
  local worker = require("completion_tools.worker").new()
  local warn = require("completion_tools.worker").warnings("spell")
  return {
    score_offset = 10,
    complete = function(ctx, callback)
      if
        #ctx.prefix < opts.min_keyword_length
        or not vim.wo[ctx.winid].spell
        or (opts.enable_in_context and not opts.enable_in_context(ctx))
      then
        callback({ items = {} })
        return
      end
      local payload = {
        kind = "spell",
        query = ctx.prefix,
        runtimepath = vim.opt.runtimepath:get(),
        cwd = vim.fn.getcwd(),
        spelllang = vim.bo[ctx.bufnr].spelllang,
        spellfile = vim.bo[ctx.bufnr].spellfile,
        spellcapcheck = vim.bo[ctx.bufnr].spellcapcheck,
        spelloptions = vim.bo[ctx.bufnr].spelloptions,
        spellsuggest = vim.o.spellsuggest,
        max_items = opts.max_items,
        sort = opts.sort,
        preselect_current_word = opts.preselect_current_word,
        suggest_when_correct = opts.suggest_when_correct,
      }
      return worker.request(payload, function(result)
        if
          not vim.api.nvim_win_is_valid(ctx.winid)
          or not vim.api.nvim_buf_is_valid(ctx.bufnr)
          or not vim.wo[ctx.winid].spell
          or vim.bo[ctx.bufnr].spelllang ~= payload.spelllang
          or vim.bo[ctx.bufnr].spellfile ~= payload.spellfile
        then
          callback({ items = {} })
          return
        end
        warn(result)
        callback({ items = result.items or {} })
      end, opts.debounce_ms, opts.timeout_ms)
    end,
    dispose = worker.dispose,
  }
end
return M
