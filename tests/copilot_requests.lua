local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local native = require("completion_tools.copilot")
local original = native.new
local requests, cancelled = {}, {}
local client = { initialized = true }
function client:is_stopped()
  return false
end
function client:cancel_request(id)
  cancelled[#cancelled + 1] = id
end
function client:request(_, _, cb)
  requests[#requests + 1] = cb
  return true, #requests
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
  bufnr = vim.api.nvim_get_current_buf(),
  winid = vim.api.nvim_get_current_win(),
  mode = "insert",
  filetype = "lua",
  row = 0,
  col = 2,
  line = "pr",
  before = "pr",
  prefix = "pr",
  start_col = 0,
  tick = vim.api.nvim_buf_get_changedtick(0),
}
local source = require("completion_tools.sources.copilot").new({ debounce_ms = 0 })
local calls = { 0, 0, 0 }
local function subscriber(i)
  return function()
    calls[i] = calls[i] + 1
  end
end
local first = source.complete(ctx, subscriber(1))
local second = source.complete(ctx, subscriber(2))
eq(1, #requests)
first()
eq({}, cancelled)
requests[1](nil, { completions = {} })
eq({ 0, 1, 0 }, calls)
second()
eq({}, cancelled)

first = source.complete(ctx, subscriber(1))
first(ctx) -- Transfer an identical pending request to a fresh engine run.
eq({}, cancelled)
second = source.complete(ctx, subscriber(2))
eq(2, #requests)
requests[2](nil, { completions = {} })
eq({ 0, 2, 0 }, calls)
first = source.complete(ctx, subscriber(1))
first(ctx)
local changed = vim.deepcopy(ctx)
changed.tick = changed.tick + 1
source.complete(changed, subscriber(3))
eq({ 3 }, cancelled)
requests[3](nil, { completions = {} })
eq({ 0, 2, 1 }, calls) -- Changed snapshot publishes empty; late old response is ignored.

source.complete(ctx, subscriber(1))
local width = vim.bo.shiftwidth
vim.bo.shiftwidth = width == 3 and 4 or 3
source.complete(ctx, subscriber(2))
eq({ 3, 4 }, cancelled) -- Same text with different formatting options is a new request.
vim.bo.shiftwidth = width
source.dispose()
eq({ 3, 4, 5 }, cancelled)
requests[4](nil, { completions = {} })
requests[5](nil, { completions = {} })
eq({ 0, 2, 1 }, calls)
native.new = original
print("copilot requests: shared subscribers, transfer, formatting identity and cancellation passed")
