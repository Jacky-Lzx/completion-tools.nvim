local M = {}

function M.new(opts, refresh)
  local states, closed = {}, false
  local clock = 0
  local source = {}
  local function retire(state)
    state.generation = state.generation + 1
    state.active, state.ready = false, false
    state.lines, state.counts, state.items, state.indices, state.size = {}, {}, {}, {}, 0
  end
  local function activate(state)
    local active, oldest = 0, nil
    for _, candidate in pairs(states) do
      if candidate.active and candidate ~= state then
        active = active + 1
        if not oldest or candidate.last_used < oldest.last_used then
          oldest = candidate
        end
      end
    end
    if active >= opts.max_buffers and oldest then
      retire(oldest)
    end
    state.active = true
    state.rebuild()
  end
  local function allowed(buf)
    return vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == ""
      and vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) <= opts.max_bytes
  end
  local function words(line)
    local result = {}
    -- Non-ASCII identifiers are retained. ASCII punctuation is a separator.
    for word in line:gmatch("[%w_\128-\255]+") do
      if #word >= opts.min_length and not word:match("^%d+$") then
        result[word] = true
      end
    end
    return result
  end
  local function adjust(state, set, delta)
    for word in pairs(set or {}) do
      local previous = state.counts[word]
      local count = (previous or 0) + delta
      if previous and count <= 0 then
        state.counts[word] = nil
        state.size = state.size - 1
        local index = state.indices[word]
        local last = state.items[#state.items]
        state.items[index] = last
        state.indices[last.label] = index
        state.items[#state.items] = nil
        state.indices[word] = nil
      elseif count > 0 and (previous or state.size < opts.max_words) then
        if not previous then
          state.size = state.size + 1
          state.items[#state.items + 1] = { label = word, kind = 1 }
          state.indices[word] = #state.items
        end
        state.counts[word] = count
      end
    end
  end
  local function attach(buf)
    clock = clock + 1
    if states[buf] then
      local state = states[buf]
      state.last_used = clock
      if not state.active then
        activate(state)
      end
      return state
    end
    local state = { lines = {}, counts = {}, size = 0, generation = 0, last_used = clock }
    states[buf] = state
    local scan
    local function rebuild()
      state.generation = state.generation + 1
      local generation, row = state.generation, 0
      state.lines, state.counts, state.size, state.items, state.indices, state.ready =
        {}, {}, 0, {}, {}, false
      state.scanned = 0
      local function batch()
        if closed or states[buf] ~= state or generation ~= state.generation then
          return
        end
        if not allowed(buf) then
          retire(state)
          return
        end
        local last = math.min(row + opts.batch_lines, vim.api.nvim_buf_line_count(buf))
        for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, row, last, false)) do
          local set = words(line)
          state.lines[row + i] = set
          adjust(state, set, 1)
        end
        row = last
        state.scanned = row
        if row < vim.api.nvim_buf_line_count(buf) then
          vim.schedule(batch)
        else
          state.ready = true
          refresh()
        end
      end
      vim.schedule(batch)
    end
    scan = rebuild
    state.rebuild = rebuild
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, _, _, first, old_last, new_last)
        if closed or states[buf] ~= state then
          return true
        end
        if not state.active then
          return
        end
        if not allowed(buf) then
          retire(state)
          return
        end
        if not state.ready then
          if old_last == new_last and old_last - first <= opts.batch_lines then
            -- Ordinary typing must not restart a large initial scan. Rows
            -- ahead of the scan will be read in their latest state; patch
            -- already indexed rows in place.
            local last = math.min(new_last, state.scanned)
            if first < last then
              for i = first + 1, last do
                adjust(state, state.lines[i], -1)
              end
              for offset, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, last, false)) do
                local set = words(line)
                state.lines[first + offset] = set
                adjust(state, set, 1)
              end
            end
          else
            scan()
          end
          return
        end
        -- Large edits are rebuilt in bounded batches outside the input handler.
        if math.max(old_last - first, new_last - first) > opts.batch_lines then
          scan()
          return
        end
        for i = first + 1, old_last do
          adjust(state, state.lines[i], -1)
        end
        local old_count, shift = #state.lines, new_last - old_last
        if shift ~= 0 then
          table.move(state.lines, old_last + 1, old_count, new_last + 1)
          for i = old_count + shift + 1, old_count do
            state.lines[i] = nil
          end
        end
        for offset, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, new_last, false)) do
          local set = words(line)
          state.lines[first + offset] = set
          adjust(state, set, 1)
        end
      end,
      on_detach = function()
        if states[buf] == state then
          states[buf] = nil
        end
      end,
      on_reload = function()
        if state.active then
          scan()
        end
      end,
    })
    activate(state)
    return state
  end
  function source.complete(ctx, callback)
    local buffers = opts.get_bufnrs and opts.get_bufnrs(ctx) or { ctx.bufnr }
    local items = {}
    for _, buf in ipairs(buffers) do
      if allowed(buf) then
        local state = attach(buf)
        if #buffers == 1 then
          callback({ items = state.ready and state.items or {} })
          return
        end
        for _, item in ipairs(state.ready and state.items or {}) do
          items[#items + 1] = item
        end
      end
    end
    callback({ items = items })
  end
  function source.warmup(buf)
    if allowed(buf) then
      attach(buf)
    end
  end
  function source.dispose()
    closed = true
    for _, state in pairs(states) do
      retire(state)
    end
    states = {}
  end
  return source
end

return M
