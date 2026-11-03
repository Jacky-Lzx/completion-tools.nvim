local scheduler = require("completion_tools.scheduler")
local config = require("completion_tools.config")
for _, opts in ipairs({
  { timeout_ms = -1 },
  { providers = { a = { max_items = 0 } } },
  { providers = { a = { timeout_ms = -1 } } },
  { providers = { a = { fallback_for = { "a" } } } },
  { providers = { a = { fallback_for = { "b" } }, b = { fallback_for = { "a" } } } },
}) do
  assert(not pcall(config.validate, opts))
end
local callbacks, calls, cancelled, changed, errors = {}, {}, {}, 0, {}
local run = scheduler.run({
  ids = { "fallback", "main", "other", "last" },
  options = {
    main = { enabled = true, timeout_ms = 30 },
    other = { enabled = true, timeout_ms = 0 },
    fallback = { enabled = true, timeout_ms = 100, fallback_for = { "main", "other" } },
    last = { enabled = true, timeout_ms = 100, fallback_for = { "fallback" } },
  },
  changed = function()
    changed = changed + 1
  end,
  failed = function(id, err)
    errors[id] = err
  end,
  receive = function(_, response)
    return response and response.matches or false
  end,
  start = function(id, cb)
    calls[id] = (calls[id] or 0) + 1
    callbacks[id] = cb
    return function()
      cancelled[id] = true
    end
  end,
})
assert(calls.main == 1 and calls.other == 1 and not calls.fallback)
callbacks.main({ pending = true, matches = false })
callbacks.other({ matches = false })
assert(not calls.fallback, "fallback ran before final result/deadline")
assert(vim.wait(500, function()
  return calls.fallback == 1
end))
assert(cancelled.main and run.records.main.status == "timeout")
callbacks.main({ matches = true })
assert(not run.records.main.matches, "late timed-out result was accepted")
callbacks.fallback({ matches = true })
assert(run.records.last.status == "skipped" and not calls.last and not run.pending())
run.cancel()
local before = changed
callbacks.other({ matches = true })
assert(changed == before and not next(errors))
run = scheduler.run({
  ids = { "bad", "fallback" },
  options = {
    bad = { enabled = true, timeout_ms = 0 },
    fallback = { enabled = true, timeout_ms = 100, fallback_for = { "bad" } },
  },
  changed = function() end,
  failed = function(id, err)
    errors[id] = err
  end,
  receive = function()
    return false
  end,
  start = function(id, cb)
    if id == "bad" then
      error("fixture failure")
    end
    cb({})
  end,
})
assert(errors.bad and run.records.fallback.status == "done" and not run.pending())
run.cancel()
print("scheduler: final-response fallback, chains, cycles, deadlines, errors and stale cancellation passed")
