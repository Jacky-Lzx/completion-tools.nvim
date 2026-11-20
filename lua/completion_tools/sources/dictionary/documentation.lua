local M = {}

function M.new(opts)
  local cache, order, slot, active, closed = {}, {}, 1, {}, false
  local function remember(word, value)
    local old = order[slot]
    if old then
      cache[old] = nil
    end
    order[slot], cache[word] = word, value
    slot = slot % 128 + 1
  end
  local function resolve(entry, callback)
    local item = vim.tbl_extend("force", {}, entry.item)
    local word = item.data and item.data.dictionary_word or item.label
    local function publish(value)
      if value then
        item.documentation = { kind = "plaintext", value = value }
      end
      callback(item)
    end
    if closed or not opts.enabled or vim.fn.executable(opts.command) ~= 1 then
      publish()
      return
    end
    if cache[word] ~= nil then
      publish(cache[word])
      return
    end
    local token, live, job = {}, true, nil
    local function cancel()
      if live then
        live = false
        active[token] = nil
        if job then
          job:kill(15)
        end
      end
    end
    local ok, result = pcall(vim.system, { opts.command, word, "-over" }, {
      text = true,
      timeout = opts.timeout_ms,
    }, function(response)
      vim.schedule(function()
        if closed or not live then
          return
        end
        live = false
        active[token] = nil
        local value = response.stdout and vim.trim(response.stdout) or ""
        -- WordNet returns the number of senses, so a nonzero code is normal.
        -- Killed/timed-out queries must never publish meanings or fill the cache.
        if response.signal == 0 and (value ~= "" or response.code == 0) then
          value = value ~= "" and value:sub(1, 65536) or false
          remember(word, value)
          publish(value)
        else
          publish()
        end
      end)
    end)
    if not ok then
      live = false
      publish()
      return
    end
    job, active[token] = result, cancel
    return cancel
  end
  return {
    resolve = resolve,
    dispose = function()
      closed = true
      for _, cancel in pairs(active) do
        cancel()
      end
      cache, order = {}, {}
    end,
  }
end

return M
