local M = {}

local function key(item, source, filetype)
  return vim.json.encode({ filetype or "", source })
    .. require("completion_tools.identity").key({
      label = item.label,
      insertText = item.textEdit and item.textEdit.newText or item.insertText or item.label,
      detail = item.detail,
      labelDetails = item.labelDetails,
      insertTextFormat = item.insertTextFormat,
    })
end

function M.new(opts)
  local records, labels, loaded, dirty = {}, {}, false, false
  local path = opts.history.path or (vim.fn.stdpath("state") .. "/completion-tools/history.json")
  local function load()
    if loaded or not opts.history.enabled then
      return
    end
    loaded = true
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.size > 2 * 1024 * 1024 then
      return
    end
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if not ok or type(data) ~= "table" or data.version ~= 1 or type(data.records) ~= "table" then
      return
    end
    for _, record in ipairs(data.records) do
      if #records >= opts.history.max_entries then
        break
      end
      if
        type(record) == "table"
        and type(record.key) == "string"
        and type(record.label) == "string"
        and type(record.count) == "number"
        and record.count > 0
        and type(record.time) == "number"
      then
        records[#records + 1] = record
        labels[record.label] = true
      end
    end
  end
  local function save()
    if not dirty then
      return
    end
    local ok = pcall(function()
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local temporary = path .. "." .. vim.fn.getpid() .. ".tmp"
      vim.fn.writefile({ vim.json.encode({ version = 1, records = records }) }, temporary)
      local renamed, err = vim.uv.fs_rename(temporary, path)
      assert(renamed, err)
    end)
    if ok then
      dirty = false
    end
  end
  local timer
  local ranking = {}
  function ranking.record(entry, ctx)
    if not opts.history.enabled or ctx.mode == "cmdline" then
      return
    end
    load()
    local id = key(entry.item, entry.source_id, ctx.filetype)
    local record
    for i, value in ipairs(records) do
      if value.key == id then
        record = table.remove(records, i)
        break
      end
    end
    record = record or { key = id, label = entry.item.label, count = 0 }
    record.count, record.time = math.min(record.count + 1, 1000), os.time()
    table.insert(records, 1, record)
    while #records > opts.history.max_entries do
      table.remove(records)
    end
    labels = {}
    for _, value in ipairs(records) do
      labels[value.label] = true
    end
    dirty = true
    timer = timer or vim.uv.new_timer()
    timer:start(500, 0, vim.schedule_wrap(save))
  end
  function ranking.scorer(ctx)
    if ctx.mode == "cmdline" then
      return
    end
    load()
    local nearby = {}
    if opts.proximity.enabled and vim.api.nvim_buf_is_valid(ctx.bufnr) then
      local first = math.max(0, ctx.row - opts.proximity.lines)
      local last = math.min(vim.api.nvim_buf_line_count(ctx.bufnr), ctx.row + opts.proximity.lines + 1)
      for offset, line in ipairs(vim.api.nvim_buf_get_lines(ctx.bufnr, first, last, false)) do
        local distance = math.abs(first + offset - 1 - ctx.row)
        for word in line:gmatch("[%w_\128-\255]+") do
          nearby[word] = math.max(nearby[word] or 0, 12 / (distance + 1))
        end
      end
    end
    if not opts.history.enabled and not opts.proximity.enabled then
      return
    end
    local now = os.time()
    return function(item, source)
      local score = nearby[item.label] or 0
      if labels[item.label] then
        local id = key(item, source, ctx.filetype)
        for _, record in ipairs(records) do
          if record.key == id then
            local age = math.max(0, now - record.time) / 86400
            score = score + math.min(12, record.count * 2) + 12 / (1 + age)
            break
          end
        end
      end
      return score
    end
  end
  function ranking.dispose()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    save()
  end
  return ranking
end

return M
