local M = {}

-- A request owns its deadlines and cancellation. Dependencies are evaluated
-- against matched results, not raw lists, and wait for final responses.
function M.run(args)
  local records, cancelled, pumping, again = {}, false, false, false
  local run = { records = records }
  for _, id in ipairs(args.ids) do
    local options = args.options[id]
    records[id] = {
      status = options.error and "error" or (options.enabled and "waiting" or "disabled"),
      error = options.error,
      matches = false,
    }
  end
  local function close(record)
    if record.timer then
      record.timer:stop()
      record.timer:close()
      record.timer = nil
    end
  end
  local pump
  local function fail(id, err)
    local record = records[id]
    close(record)
    record.status, record.error = "error", tostring(err)
    record.elapsed_ms = (vim.uv.hrtime() - record.started) / 1e6
    if record.cancel then
      pcall(record.cancel)
    end
    args.failed(id, err)
    args.changed()
  end
  local function start(id)
    local record, options = records[id], args.options[id]
    record.status, record.started = "pending", vim.uv.hrtime()
    if options.timeout_ms > 0 then
      record.timer = vim.uv.new_timer()
      record.timer:start(
        options.timeout_ms,
        0,
        vim.schedule_wrap(function()
          if cancelled or record.status ~= "pending" then
            return
          end
          close(record)
          record.status = "timeout"
          record.elapsed_ms = (vim.uv.hrtime() - record.started) / 1e6
          if record.cancel then
            pcall(record.cancel)
          end
          args.changed()
          pump()
        end)
      )
    end
    local function publish(response)
      if cancelled or record.status == "timeout" or record.status == "error" then
        return
      end
      local ok, matches = pcall(args.receive, id, response)
      if not ok then
        fail(id, matches)
      else
        record.matches = matches
        record.status = response and response.pending == true and "pending" or "done"
        record.elapsed_ms = (vim.uv.hrtime() - record.started) / 1e6
        if record.status == "done" then
          close(record)
        end
        args.changed()
      end
      pump()
    end
    local ok, cancel = pcall(args.start, id, function(response)
      if vim.in_fast_event() then
        vim.schedule(function()
          publish(response)
        end)
      else
        publish(response)
      end
    end)
    if ok then
      record.cancel = type(cancel) == "function" and cancel or nil
      if record.cancel and (cancelled or record.status == "error") then
        pcall(record.cancel)
        record.cancel = nil
      end
    else
      fail(id, cancel)
    end
  end
  pump = function()
    if pumping then
      again = true
      return
    end
    pumping = true
    repeat
      again = false
      for _, id in ipairs(args.ids) do
        local record, options = records[id], args.options[id]
        if record.status == "waiting" then
          local ready, blocked = true, false
          for _, dependency in ipairs(options.fallback_for or {}) do
            local other = records[dependency]
            if other then
              if other.status == "pending" or other.status == "waiting" then
                ready = false
              end
              blocked = blocked or other.matches or other.status == "skipped"
            end
          end
          if ready then
            if blocked then
              record.status = "skipped"
              args.changed()
            else
              start(id)
            end
            again = true
          end
        end
      end
    until not again or cancelled
    pumping = false
  end
  function run.pending()
    for _, record in pairs(records) do
      if record.status == "waiting" or record.status == "pending" then
        return true
      end
    end
    return false
  end
  function run.cancel()
    cancelled = true
    for _, record in pairs(records) do
      close(record)
      if record.status == "pending" or record.status == "waiting" then
        if record.started then
          record.elapsed_ms = (vim.uv.hrtime() - record.started) / 1e6
        end
        record.status = "cancelled"
      end
      if record.cancel then
        pcall(record.cancel)
        record.cancel = nil
      end
    end
  end
  pump()
  args.changed()
  return run
end

return M
