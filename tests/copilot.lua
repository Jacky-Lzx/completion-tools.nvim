local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local factory = require("completion_tools.sources.copilot")
require("completion-tools").setup()
assert(not package.loaded["copilot.client"], "Default setup must not load optional Copilot")
require("completion-tools").dispose()
local unavailable
factory.new({ debounce_ms = 0 }).complete({}, function(result)
  unavailable = result
end)
eq({}, unavailable.items)

local disabled, attached, sent = false, true, true
local requests, cancellations, accepted = {}, {}, {}
local client = { initialized = true }
function client:is_stopped()
  return false
end
function client:cancel_request(id)
  cancellations[#cancellations + 1] = id
end
package.loaded["copilot.client"] = {
  get = function()
    return client
  end,
  is_disabled = function()
    return disabled
  end,
  buf_is_attached = function()
    return attached
  end,
}
package.loaded["copilot.util"] = {
  get_doc_params = function(overrides)
    return { bufnr = overrides.bufnr, doc = { position = { line = 0, character = 8 } } }
  end,
}
package.loaded["copilot.api"] = {
  get_completions_cycling = function(c, params, callback)
    eq(client, c)
    requests[#requests + 1] = { params = params, callback = callback }
    return sent, #requests
  end,
  notify_accepted = function(c, params, callback)
    eq(client, c)
    accepted[#accepted + 1] = params.uuid
    callback()
  end,
}
vim.o.virtualedit = "onemore"
vim.bo.filetype = "lua"
local line = "中😀 = pr"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { line .. ")" })
vim.api.nvim_win_set_cursor(0, { 1, #line })
local ctx = {
  mode = "insert",
  bufnr = vim.api.nvim_get_current_buf(),
  winid = vim.api.nvim_get_current_win(),
  row = 0,
  col = #line,
  before = line,
  line = line .. ")",
  start_col = #line - 2,
  prefix = "pr",
  filetype = "lua",
  tick = vim.api.nvim_buf_get_changedtick(0),
}
local source, results = factory.new({ debounce_ms = 0 }), {}
local function complete()
  return source.complete(ctx, function(result)
    results[#results + 1] = result
  end)
end
for _, state in ipairs({ "disabled", "detached", "uninitialized" }) do
  disabled, attached, client.initialized = state == "disabled", state ~= "detached", state ~= "uninitialized"
  complete()
  eq({}, results[#results].items)
  eq(0, #requests)
end
disabled, attached, client.initialized = false, true, true
complete()
eq(ctx.bufnr, requests[1].params.bufnr)
requests[1].callback(nil, {
  completions = {
    {
      text = '中😀 = print("$1")\r\nprint("done")',
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 8 } },
      uuid = "chosen",
    },
    { text = "", range = {} },
  },
})
local result = results[#results]
eq(1, #result.items)
assert(not result.reusable)
local item = result.items[1]
eq('print("$1")', item.label)
eq('print("$1")\nprint("done")', item.textEdit.newText)
eq(6, item.textEdit.range.start.character)
eq("utf-16", item._encoding)
eq(item.textEdit.newText, item.documentation.value)
local entries = require("completion_tools.matcher").filter({
  {
    items = result.items,
    source_id = "copilot",
    score_offset = 50,
    priority = 1,
    start_col = ctx.start_col,
    context = ctx,
  },
}, ctx, 10)
eq(1, #entries)
require("completion_tools.edits").apply(entries[1], ctx, require("completion_tools.config").defaults)
eq({ '中😀 = print("$1")', 'print("done"))' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
-- The primary edit never interprets Copilot text as snippet placeholders.
source.execute(entries[1])
eq({ "chosen" }, accepted)

-- Restore the originating context for cancellation/error tests.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { ctx.line })
vim.api.nvim_win_set_cursor(0, { 1, ctx.col })
ctx.tick = vim.api.nvim_buf_get_changedtick(0)
local cancel = complete()
local before = #results
cancel()
cancel()
eq({ 2 }, cancellations)
requests[2].callback(nil, { completions = {} })
eq(before, #results)
complete()
source.dispose()
eq({ 2, 3 }, cancellations)
requests[3].callback(nil, { completions = {} })
eq(before, #results)
sent = false
complete()
eq({}, results[#results].items)
sent = true
complete()
requests[#requests].callback({ message = "not authenticated" }, nil)
eq({}, results[#results].items)
complete()
requests[#requests].callback(nil, vim.NIL)
eq({}, results[#results].items)
complete()
requests[#requests].callback(nil, {
  completions = {
    {
      text = " \n  return value",
      range = {
        start = { line = ctx.row, character = 8 },
        ["end"] = { line = ctx.row, character = 8 },
      },
    },
  },
})
eq("return value", results[#results].items[1].label)
local continuation = require("completion_tools.matcher").filter({
  {
    items = results[#results].items,
    source_id = "copilot",
    score_offset = 50,
    priority = 1,
    start_col = ctx.col,
    context = ctx,
  },
}, ctx, 10)
eq(1, #continuation)

-- Alternative requests may include repeats or more results than requested.
local function alternative(text, uuid)
  return {
    text = text,
    uuid = uuid,
    range = {
      start = { line = 0, character = 6 },
      ["end"] = { line = 0, character = 8 },
    },
  }
end
local alternatives = {
  alternative("print(1)", "one"),
  alternative("print(1)", "repeat"),
  alternative("print(2)", "two"),
  alternative("print(3)", "three"),
  alternative("print(4)", "four"),
}
complete()
requests[#requests].callback(nil, { completions = alternatives })
eq(3, #results[#results].items)
eq(
  { "one", "two", "three" },
  vim.tbl_map(function(candidate)
    return candidate._copilot_uuid
  end, results[#results].items)
)
local limited = factory.new({ debounce_ms = 0, max_items = 2 })
limited.complete(ctx, function(result)
  eq(2, #result.items)
end)
requests[#requests].callback(nil, { completions = alternatives })
limited.dispose()

local debounced = factory.new({ debounce_ms = 30 })
local count = #requests
debounced.complete(ctx, function() end)()
vim.wait(60)
eq(count, #requests)
debounced.complete(ctx, function() end)
debounced.complete(ctx, function() end)
assert(vim.wait(200, function()
  return #requests == count + 1
end))
debounced.dispose()
eq(count + 1, cancellations[#cancellations])
debounced.complete(ctx, function() end)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
vim.wait(60)
eq(count + 1, #requests)
debounced.dispose()
for _, value in ipairs({ -1, 0.5, "fast" }) do
  assert(not pcall(require("completion_tools.config").validate, { copilot = { debounce_ms = value } }))
end
for _, value in ipairs({ -1, 0, 0.5, "three" }) do
  assert(not pcall(require("completion_tools.config").validate, { copilot = { max_items = value } }))
end
print(
  "copilot: optional loading, eligibility, UTF-16 multiline edits, literal text, cancellation and debounce passed"
)
