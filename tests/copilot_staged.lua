local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local native, requests, cancellations = require("completion_tools.copilot"), {}, {}
local original, synchronous = native.new, false
local client = { initialized = true }
function client:is_stopped()
  return false
end
function client:cancel_request(id)
  cancellations[#cancellations + 1] = id
end
local function raw(text, uuid)
  return {
    text = text,
    uuid = uuid or text,
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 2 } },
  }
end
function client:request(method, params, cb)
  local id = #requests + 1
  requests[id] = { method = method, callback = cb, params = params }
  if synchronous and method == "getCompletions" then
    cb(nil, { completions = { raw("print(1)") } })
  end
  return true, id
end
native.new = function()
  return {
    eligible = function()
      return true
    end,
    ensure = function(_, cb)
      cb(client)
    end,
    dispose = function() end,
  }
end
vim.o.virtualedit = "onemore"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "pr" })
vim.api.nvim_win_set_cursor(0, { 1, 2 })
local ctx = {
  mode = "insert",
  filetype = "lua",
  bufnr = vim.api.nvim_get_current_buf(),
  winid = vim.api.nvim_get_current_win(),
  row = 0,
  col = 2,
  line = "pr",
  before = "pr",
  prefix = "pr",
  start_col = 0,
  tick = vim.api.nvim_buf_get_changedtick(0),
}
local factory = require("completion_tools.sources.copilot")
local source = factory.new({ debounce_ms = 0, request_mode = "staged" })
local first, second = {}, {}
local cancel = source.complete(ctx, function(r)
  first[#first + 1] = r
end)
eq("getCompletions", requests[1].method)
requests[1].callback(nil, { completions = { raw("print(1)", "primary") } })
eq(1, #first)
assert(first[1].pending and first[1].stable)
eq("getCompletionsCycling", requests[2].method)
eq(nil, source.reuse(ctx, first[1], ctx))
local typed =
  vim.tbl_extend("force", ctx, { before = "pri", line = "pri", col = 3, prefix = "pri", tick = ctx.tick + 1 })
assert(source.reuse(typed, first[1], ctx))
cancel(ctx)
cancel = source.complete(ctx, function(r)
  second[#second + 1] = r
end)
eq(1, #second) -- A new subscriber gets the already available first stage.
eq(2, #requests)
requests[2].callback(
  nil,
  { completions = { raw("print(1)", "duplicate"), raw("print(2)"), raw("print(3)"), raw("print(4)") } }
)
eq(2, #second)
assert(not second[2].pending)
eq(3, #second[2].items)
eq("primary", second[2].items[1]._copilot_uuid)
assert(second[1].items[1] == second[2].items[1])
eq(1, #first[1].items) -- Final publication must not mutate the first response's list.
cancel()
eq({}, cancellations)

synchronous = true
cancel = source.complete(ctx, function() end)
eq(4, #requests)
cancel()
eq({ 4 }, cancellations) -- Cancel the second stage, even with a synchronous first stage.
requests[4].callback(nil, { completions = { raw("late") } })
source.dispose()
synchronous = false
source = factory.new({ debounce_ms = 0, request_mode = "staged" })
local results = {}
source.complete(ctx, function(r)
  results[#results + 1] = r
end)
requests[5].callback(nil, { completions = { raw("print(1)") } })
requests[6].callback({ message = "cycling unavailable" })
eq(2, #results)
eq(1, #results[2].items)
assert(not results[2].pending)
source.dispose()
source = factory.new({ debounce_ms = 0, request_mode = "staged", max_items = 1 })
source.complete(ctx, function(r)
  assert(not r.pending and #r.items == 1)
end)
requests[7].callback(nil, { completions = { raw("print(1)") } })
eq(7, #requests)
source.dispose()
assert(not pcall(require("completion_tools.config").validate, { copilot = { request_mode = "unknown" } }))
native.new = original
print("copilot staged: first publication, stable alternatives, coalescing, cancellation and fallback passed")
