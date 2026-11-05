local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local factory = require("completion_tools.sources.copilot")
require("completion-tools").setup()
assert(not package.loaded["copilot.client"], "Default setup must not load optional Copilot")
require("completion-tools").dispose()
local disabled, attached, sent = false, true, true
local requests, cancellations, accepted = {}, {}, {}
local client = { initialized = true }
function client:is_stopped()
  return false
end
function client:cancel_request(id)
  cancellations[#cancellations + 1] = id
end
function client:request(method, params, callback, buf)
  if method == "notifyAccepted" then
    accepted[#accepted + 1] = params.uuid
    callback()
    return true
  end
  eq("getCompletionsCycling", method)
  requests[#requests + 1] = { params = params, callback = callback, buf = buf }
  return sent, #requests
end
local native = require("completion_tools.copilot")
local real_new = native.new
native.new = function()
  return {
    eligible = function()
      return not disabled and attached
    end,
    ensure = function(_, cb)
      cb(client.initialized and client or nil)
      return function() end
    end,
    dispose = function() end,
  }
end
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
eq(ctx.bufnr, requests[1].buf)
eq(8, requests[1].params.position.character)
eq(vim.uri_from_bufnr(ctx.bufnr), requests[1].params.textDocument.uri)
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

-- Reuse validates literal generated text, not the fuzzy filterText used by the menu.
local function forward(old, suffix)
  local next = vim.deepcopy(old)
  next.before = old.before .. suffix
  next.col = #next.before
  next.line = next.before .. old.line:sub(old.col + 1)
  next.prefix = vim.fn.matchstr(next.before, [[\k*$]])
  next.start_col = next.col - #next.prefix
  next.tick = old.tick + 1
  return next
end
eq(result, source.reuse(ctx, result, ctx))
local typed = forward(ctx, "int")
local reused = assert(source.reuse(typed, result, ctx))
eq(1, #reused.items)
eq(item.textEdit.newText, reused.items[1].textEdit.newText)
eq(11, reused.items[1].textEdit.range["end"].character)
eq("chosen", reused.items[1]._copilot_uuid)
eq(8, item.textEdit.range["end"].character) -- The original snapshot stays immutable.
local punctuation = forward(typed, "(")
local punct_result = assert(source.reuse(punctuation, reused, typed))
eq('"$1")\nprint("done")', punct_result.items[1].textEdit.newText)
eq(12, punct_result.items[1].textEdit.range.start.character)
for _, suffix in ipairs({ "X", "INT", "xint", 'int("$1")\nprint("done")' }) do
  eq(nil, source.reuse(forward(ctx, suffix), result, ctx))
end
for field, value in pairs({ row = 1, bufnr = -1, winid = -1, mode = "cmdline", filetype = "python" }) do
  local changed = vim.tbl_extend("force", typed, { [field] = value })
  eq(nil, source.reuse(changed, result, ctx))
end
local changed = vim.tbl_extend("force", typed, { line = typed.before .. "different suffix" })
eq(nil, source.reuse(changed, result, ctx))
eq(nil, source.reuse(ctx, reused, typed)) -- Backspace is not forward typing.
disabled = true
eq(nil, source.reuse(typed, result, ctx))
disabled = false
client.initialized = false
eq(nil, source.reuse(typed, result, ctx))
client.initialized = true

-- Insertions at the cursor, Unicode input and replacement of following lines.
local unicode = vim.deepcopy(item)
unicode.textEdit = {
  range = { start = { line = 0, character = 8 }, ["end"] = { line = 1, character = 3 } },
  newText = "😀 中文\nnext",
}
local unicode_ctx = forward(ctx, "😀 ")
local unicode_result = assert(source.reuse(unicode_ctx, { items = { unicode } }, ctx))
eq(11, unicode_result.items[1].textEdit.range.start.character)
eq({ line = 1, character = 3 }, unicode_result.items[1].textEdit.range["end"])
eq("中文\nnext", unicode_result.items[1].textEdit.newText)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { unicode_ctx.line, "old tail" })
require("completion_tools.edits").apply(
  { item = unicode_result.items[1], context = unicode_ctx },
  unicode_ctx,
  require("completion_tools.config").defaults
)
eq({ "中😀 = pr😀 中文", "next tail" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
local before_cursor = vim.deepcopy(unicode)
before_cursor.textEdit.range["end"] = { line = 0, character = 7 }
eq(nil, source.reuse(unicode_ctx, { items = { before_cursor } }, ctx))
local earlier_line = vim.deepcopy(unicode)
earlier_line.textEdit.range.start.line = -1
eq(nil, source.reuse(unicode_ctx, { items = { earlier_line } }, ctx))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { ctx.line })
vim.api.nvim_win_set_cursor(0, { 1, ctx.col })
ctx.tick = vim.api.nvim_buf_get_changedtick(0)

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
native.new = real_new
local format = require("completion_tools.copilot_status").format
for _, case in ipairs({
  { {}, { status = "pending" }, 0, "Waiting" },
  { { running = true }, { status = "pending" }, 0, "Starting" },
  { { running = true, initialized = true }, { status = "pending" }, 0, "Generating" },
  { {}, { status = "done" }, 3, "Ready" },
  { {}, { status = "done" }, 0, "No suggestions" },
  { {}, { status = "timeout" }, 0, "Timed out" },
  { { enabled = false }, {}, 0, "Disabled" },
  { { server = { kind = "Error" } }, {}, 0, "Sign in required" },
  { { last_error = "offline" }, {}, 0, "Unavailable" },
}) do
  local status = format(case[1], case[2], case[3])
  eq(case[4], status.label)
  assert(not status.text:find("Copilot:", 1, true))
  if case[4] == "Waiting" or case[4] == "Starting" or case[4] == "Generating" then
    eq("", status.text)
    eq(10, #status.frames)
    assert(status.frames[1] ~= status.frames[2])
  else
    eq(nil, status.frames)
  end
end
eq("", format({}, { status = "done" }, 3).text)
eq("", format({ enabled = false }, {}, 0).text)
eq("", format({ last_error = "offline" }, {}, 0).text)
eq("", format({ server = { kind = "Error" } }, {}, 0).text)
print(
  "copilot: native requests, eligibility, UTF-16 multiline edits, literal text, cancellation and debounce passed"
)
