-- Native Copilot completion source. The language server starts on demand.
local M = {}

local function normalise(raw, ctx, client)
  if type(raw.text) ~= "string" or raw.text == "" or type(raw.range) ~= "table" then
    return
  end
  local range, text = vim.deepcopy(raw.range), raw.text:gsub("\r\n?", "\n")
  -- Extend a cursor-ending single-line edit over an already present suffix.
  -- Keep the generated text intact, so both acceptance and later reuse use the
  -- same replacement (and the cursor finishes after the closing delimiters).
  if
    not text:find("\n", 1, true)
    and range["end"].line == ctx.row
    and range["end"].character == vim.str_utfindex(ctx.line, "utf-16", ctx.col, false)
  then
    local suffix = ctx.line:sub(ctx.col + 1)
    for offset in text:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
      local tail = text:sub(offset)
      if suffix:sub(1, #tail) == tail then
        range["end"].character = range["end"].character + vim.str_utfindex(tail, "utf-16", #tail, false)
        break
      end
    end
  end
  local start_col = ctx.start_col
  if range.start.line == ctx.row then
    start_col = vim.str_byteindex(ctx.line, "utf-16", range.start.character, false)
    -- Copilot often replaces the whole line. Keep the existing prefix out of
    -- the menu when the generated text preserves it exactly.
    local prefix = ctx.line:sub(start_col + 1, ctx.start_col)
    if start_col <= ctx.start_col and text:sub(1, #prefix) == prefix then
      text = text:sub(#prefix + 1)
      start_col = ctx.start_col
      range.start.character = vim.str_utfindex(ctx.line, "utf-16", start_col, false)
    end
  end
  local label
  for line in text:gmatch("[^\n]+") do
    if vim.trim(line) ~= "" then
      label = vim.trim(line)
      break
    end
  end
  if not label then
    return
  end
  return {
    label = label,
    kind = 1,
    -- Copilot already matched the context; continuations need not contain the
    -- keyword (and a replacement range can start before that keyword).
    filterText = ctx.before:sub(start_col + 1) .. label,
    textEdit = { range = range, newText = text },
    documentation = { kind = "plaintext", value = text },
    _encoding = "utf-16",
    _copilot_client = client,
    _copilot_uuid = raw.uuid,
  }
end

function M.new(opts)
  opts = opts or {}
  local native = require("completion_tools.copilot")
  local copilot = native.new(opts)
  local source, active = { score_offset = 50 }, nil
  local function cancel_active()
    if active then
      active()
      active = nil
    end
  end
  -- Only carry suggestions through literal forward typing. Fuzzy matching is
  -- useful for a menu, but cannot establish that an old generated edit is safe.
  function source.reuse(ctx, response, old)
    if not copilot.eligible(ctx.bufnr) or ctx.mode ~= "insert" then
      return
    end
    local items = response.items or {}
    local client = items[1] and items[1]._copilot_client
    if not client or not client.initialized or client:is_stopped() then
      return
    end
    local context = require("completion_tools.context")
    if context.same(old, ctx) then
      return response
    end
    if not context.advances(old, ctx) then
      return
    end
    local retained = {}
    local cursor = vim.str_utfindex(old.line, "utf-16", old.col, false)
    for _, item in ipairs(items) do
      local edit, range = item.textEdit, item.textEdit.range
      local finish = range["end"]
      if
        range.start.line == old.row
        and range.start.character <= cursor
        and (finish.line > old.row or (finish.line == old.row and finish.character >= cursor))
      then
        local start = vim.str_byteindex(old.line, "utf-16", range.start.character, false)
        local typed = ctx.before:sub(start + 1)
        if #edit.newText > #typed and edit.newText:sub(1, #typed) == typed then
          local candidate = normalise({
            text = edit.newText,
            range = require("completion_tools.edits").rebase(range, old, ctx, "utf-16"),
            uuid = item._copilot_uuid,
          }, ctx, client)
          if candidate then
            candidate.sortText = item.sortText
            retained[#retained + 1] = candidate
          end
        end
      end
    end
    if #retained > 0 then
      return { items = retained }
    end
  end
  function source.complete(ctx, callback)
    cancel_active()
    if ctx.mode == "cmdline" then
      callback({ items = {} })
      return
    end
    if not copilot.eligible(ctx.bufnr) then
      callback({ items = {} })
      return
    end
    local cancelled, finished, timer, client, request_id, cancel_start = false, false, nil, nil, nil, nil
    local function cancel()
      if cancelled then
        return
      end
      cancelled = true
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      if cancel_start then
        cancel_start()
      end
      if client and request_id and not finished then
        client:cancel_request(request_id)
      end
    end
    active = cancel
    local function send(ready_client)
      if cancelled then
        return
      end
      client = ready_client
      if
        not copilot.eligible(ctx.bufnr)
        or not client
        or not client.initialized
        or client:is_stopped()
        or not vim.api.nvim_buf_is_valid(ctx.bufnr)
        or vim.api.nvim_get_current_buf() ~= ctx.bufnr
        or vim.api.nvim_get_current_win() ~= ctx.winid
        or vim.api.nvim_buf_get_changedtick(ctx.bufnr) ~= ctx.tick
        or not vim.deep_equal(vim.api.nvim_win_get_cursor(ctx.winid), { ctx.row + 1, ctx.col })
      then
        finished = true
        callback({ items = {} })
        return
      end
      local params = native.params(ctx)
      local sent
      -- Cycling requests ask Copilot for alternatives instead of only its first suggestion.
      sent, request_id = client:request("getCompletionsCycling", params, function(err, result)
        finished = true
        if cancelled then
          return
        end
        if copilot.record_error then
          copilot.record_error(err)
        end
        local items, seen = {}, {}
        if not err and result and result ~= vim.NIL then
          for i, raw in ipairs(result.completions or {}) do
            local item = normalise(raw, ctx, client)
            if item then
              local edit = item.textEdit
              local range = edit.range
              local key = edit.newText
                .. "\0"
                .. table.concat({
                  range.start.line,
                  range.start.character,
                  range["end"].line,
                  range["end"].character,
                }, ":")
              if not seen[key] then
                seen[key] = true
                item.sortText = string.format("%06d", i)
                items[#items + 1] = item
                if #items >= (opts.max_items or 3) then
                  break
                end
              end
            end
          end
        end
        -- Reuse is opt-in per candidate through source.reuse, never fuzzy prefix caching.
        callback({ items = items })
      end, ctx.bufnr)
      if not sent and not finished then
        finished = true
        callback({ items = {} })
      end
    end
    if (opts.debounce_ms or 150) == 0 then
      cancel_start = copilot.ensure(ctx.bufnr, send)
    else
      timer = vim.defer_fn(function()
        cancel_start = copilot.ensure(ctx.bufnr, send)
      end, opts.debounce_ms or 150)
    end
    return cancel
  end
  function source.execute(entry)
    local item = entry.item
    local client = item._copilot_client
    if client and not client:is_stopped() then
      if item._copilot_uuid then
        client:request("notifyAccepted", { uuid = item._copilot_uuid }, function() end)
      end
    end
  end
  function source.dispose()
    cancel_active()
    copilot.dispose()
  end
  source.get_status = copilot.get_status

  return source
end

return M
