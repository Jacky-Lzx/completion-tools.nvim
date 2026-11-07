local M = {}

function M.new()
  local sources = {}
  local function source(id)
    if not sources[id] then
      sources[id] = {
        sessions = 0,
        requests = 0,
        cache_hits = 0,
        responses = 0,
        timeouts = 0,
        errors = 0,
        raw_count = 0,
        shown_count = 0,
        status = "not_requested",
      }
    end
    return sources[id]
  end
  local collector = {}
  function collector.start(id, cached)
    local item = source(id)
    item.sessions = item.sessions + 1
    item.requests = item.requests + (cached and 0 or 1)
    item.cache_hits = item.cache_hits + (cached and 1 or 0)
    item.raw_count = 0
  end
  function collector.receive(id, count)
    local item = source(id)
    item.responses, item.raw_count = item.responses + 1, count
  end
  function collector.update(records)
    for id, record in pairs(records) do
      local item = source(id)
      if item._record ~= record and not record.started then
        item.raw_count = 0
      end
      if item._record ~= record or item.status ~= record.status then
        if record.status == "timeout" then
          item.timeouts = item.timeouts + 1
        end
        if record.status == "error" then
          item.errors = item.errors + 1
        end
      end
      item._record, item.status = record, record.status
      item.elapsed_ms = record.elapsed_ms or 0
      item.has_matches = record.matches
      if record.error then
        item.last_error = record.error
      end
    end
  end
  function collector.shown(items)
    for _, item in pairs(sources) do
      item.shown_count = 0
    end
    for _, entry in ipairs(items) do
      local item = source(entry.source_id)
      item.shown_count = item.shown_count + 1
    end
  end
  function collector.snapshot()
    local result = {}
    for id, item in pairs(sources) do
      local copy = {}
      for field, value in pairs(item) do
        if field ~= "_record" then
          copy[field] = value
        end
      end
      if item.status == "pending" and item._record and item._record.started then
        copy.elapsed_ms = (vim.uv.hrtime() - item._record.started) / 1e6
      end
      result[id] = copy
    end
    return result
  end
  return collector
end

function M.format(status)
  local spans = {}
  local lines = {
    string.format(
      "completion-tools: %s; menu=%s; ready=%s",
      status.reason,
      tostring(status.menu_visible),
      tostring(status.ready)
    ),
  }
  if status.last_request_reason then
    lines[#lines + 1] = "Last request: " .. status.last_request_reason
  end
  local ids = vim.tbl_keys(status.sources)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local item = status.sources[id]
    lines[#lines + 1] = string.format(
      "%s: %s; %.2f ms; items=%d shown=%d; requests=%d cache=%d; timeouts=%d errors=%d",
      id,
      item.status,
      item.elapsed_ms or 0,
      item.raw_count or 0,
      item.shown_count or 0,
      item.requests or 0,
      item.cache_hits or 0,
      item.timeouts or 0,
      item.errors or 0
    )
    if item.client then
      local prefix, value = "  client: ", vim.inspect(item.client):gsub("\n", " ")
      local start = #table.concat(lines, "\n") + 1 + #prefix
      lines[#lines + 1] = prefix .. value
      spans[#spans + 1] = { start = start, finish = start + #value, filetype = "lua" }
    end
    if item.last_error then
      lines[#lines + 1] = "  " .. item.last_error
    end
  end
  return table.concat(lines, "\n"), spans
end

function M.command()
  return require("completion_tools.user_command").create("CompletionToolsInfo", function()
    require("completion_tools").show_status()
  end, { desc = "Show completion source status, timings and cache statistics" })
end

return M
