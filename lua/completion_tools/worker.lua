-- One persistent headless Neovim per source. Keep at most one running request
-- and one latest replacement; cancelled work must never build an input backlog.
local M = {}
local script = debug.getinfo(1, "S").source:sub(2):gsub("worker.lua$", "worker_main.lua")
function M.warnings(name)
  local seen = {}
  return function(result)
    local errors = vim.list_extend({}, result.errors or {})
    if result.error then
      errors[#errors + 1] = result.error
    end
    if result.truncated then
      errors[#errors + 1] = "dictionary size/word limit reached"
    end
    for _, message in ipairs(errors) do
      if not seen[message] then
        seen[message] = true
        vim.notify("completion-tools " .. name .. ": " .. message, vim.log.levels.WARN)
      end
    end
  end
end

function M.new()
  local job, running, pending, delay_timer, deadline
  local sequence, closed, output, errors = 0, false, "", ""
  local pump
  local function stop(timer)
    if timer and not timer:is_closing() then
      timer:stop()
    end
  end
  local function finish(request, result)
    if request and not request.cancelled and not closed then
      request.callback(result)
    end
  end
  local function launch()
    local id
    id = vim.fn.jobstart({
      vim.v.progpath,
      "--headless",
      "--noplugin",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-n",
      "-l",
      script,
    }, {
      on_stdout = function(_, data)
        if job ~= id then
          return
        end
        output = output .. table.concat(data, "\n")
        while true do
          local at = output:find("\n", 1, true)
          if not at then
            break
          end
          local line = output:sub(1, at - 1)
          output = output:sub(at + 1)
          local ok, result = pcall(vim.json.decode, line)
          if ok and running and result.id == running.id then
            local request = running
            running = nil
            stop(deadline)
            if result.restart then
              -- Native spell lists are cached for the life of a Neovim process.
              -- Restart after a compiled word list changes, without publishing
              -- a stale result or dropping a newer pending request.
              local previous = job
              job = nil
              if not pending and not request.cancelled then
                request.ready, pending = true, request
              end
              vim.fn.jobstop(previous)
            else
              finish(request, result)
            end
            pump()
          end
        end
      end,
      on_stderr = function(_, data)
        if job == id then
          errors = (errors .. table.concat(data, "\n")):sub(-2048)
        end
      end,
      on_exit = function(_, code)
        if job ~= id then
          return
        end
        job, output = nil, ""
        local request = running
        running = nil
        stop(deadline)
        finish(request, { error = "worker exited (" .. code .. "): " .. errors, items = {} })
        pump()
      end,
    })
    if id <= 0 then
      return false
    end
    job, output, errors = id, "", ""
    return true
  end
  pump = function()
    if closed or running or not pending or not pending.ready then
      return
    end
    local request = pending
    pending = nil
    if request.cancelled then
      return
    end
    if not job and not launch() then
      finish(request, { error = "could not start Neovim worker", items = {} })
      return
    end
    running = request
    local ok = pcall(vim.fn.chansend, job, vim.json.encode(request.payload) .. "\n")
    if not ok then
      vim.fn.jobstop(job)
      return
    end
    deadline = deadline or vim.uv.new_timer()
    deadline:start(
      request.timeout_ms,
      0,
      vim.schedule_wrap(function()
        if running == request and job then
          vim.fn.jobstop(job)
        end
      end)
    )
  end
  local worker = {}
  function worker.request(payload, callback, delay_ms, timeout_ms)
    if closed then
      return function() end
    end
    sequence = sequence + 1
    payload.id = sequence
    local request = { id = sequence, payload = payload, callback = callback, timeout_ms = timeout_ms or 5000 }
    if pending then
      pending.cancelled = true
    end
    pending = request
    stop(delay_timer)
    if (delay_ms or 0) > 0 then
      delay_timer = delay_timer or vim.uv.new_timer()
      delay_timer:start(
        delay_ms,
        0,
        vim.schedule_wrap(function()
          request.ready = true
          pump()
        end)
      )
    else
      request.ready = true
      pump()
    end
    return function()
      request.cancelled = true
      if pending == request then
        pending = nil
        stop(delay_timer)
      end
    end
  end
  function worker.dispose()
    closed, pending = true, nil
    for _, timer in ipairs({ delay_timer or false, deadline or false }) do
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    if job then
      pcall(vim.fn.jobstop, job)
    end
    running = nil
  end
  return worker
end

return M
