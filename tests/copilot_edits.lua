local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local native = require("completion_tools.copilot")
local original, raw = native.new, nil
local client = { initialized = true }
function client:is_stopped()
  return false
end
function client:request(_, _, cb)
  cb(nil, { completions = { raw } })
  return true, 1
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
local source = require("completion_tools.sources.copilot").new({ debounce_ms = 0 })
vim.o.virtualedit = "onemore"
local function suggestion(before, after, text, finish)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { before .. after })
  vim.api.nvim_win_set_cursor(0, { 1, #before })
  local ctx = {
    bufnr = vim.api.nvim_get_current_buf(),
    winid = vim.api.nvim_get_current_win(),
    mode = "insert",
    filetype = "lua",
    row = 0,
    col = #before,
    before = before,
    line = before .. after,
    prefix = before,
    start_col = 0,
    tick = vim.api.nvim_buf_get_changedtick(0),
  }
  raw = {
    text = text,
    uuid = "suffix",
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = finish or vim.str_utfindex(before, "utf-16", #before, false) },
    },
  }
  local result
  source.complete(ctx, function(value)
    result = value
  end)
  return assert(result.items[1]), ctx
end
for _, case in ipairs({
  { "pr", ")", "print(1)", "print(1)" },
  { "pr", ") + tail", "print(1)", "print(1) + tail" },
  { "pr", "xyz", "print(1)", "print(1)xyz" },
  { "pr", ")😀tail", "print(1)😀", "print(1)😀tail" },
  { "pr", ")", "print(1)\nnext()", { "print(1)", "next())" } },
  { "pr", "))", "print(1)", "print(1))", 3 },
}) do
  local item, ctx = suggestion(case[1], case[2], case[3], case[5])
  require("completion_tools.edits").apply(
    { item = item, context = ctx },
    ctx,
    require("completion_tools.config").defaults
  )
  eq(type(case[4]) == "table" and case[4] or { case[4] }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
end
local item, ctx = suggestion("pr", ")", "print(1)")
local next = vim.tbl_extend("force", ctx, {
  before = "print",
  line = "print)",
  col = 5,
  prefix = "print",
  tick = ctx.tick + 1,
})
local reused = assert(source.reuse(next, { items = { item } }, ctx))
eq(6, reused.items[1].textEdit.range["end"].character)
local plan = assert(source.partial({ item = item, context = ctx }, ctx, "word"))
eq("int", plan.item.textEdit.newText)
require("completion_tools.edits").apply(
  { item = plan.item, context = ctx },
  ctx,
  require("completion_tools.config").defaults
)
local continuation = assert(plan.continue(next))
eq("(1)", continuation.items[1].textEdit.newText)
eq(6, continuation.items[1].textEdit.range["end"].character)
require("completion_tools.edits").apply(
  { item = continuation.items[1], context = next },
  next,
  require("completion_tools.config").defaults
)
eq({ "print(1)" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))

item, ctx = suggestion("pr", "TAIL", "print(1)\nnext()")
item.textEdit.range["end"] = { line = 1, character = 3 }
vim.api.nvim_buf_set_lines(0, 1, -1, false, { "old rest" })
plan = assert(source.partial({ item = item, context = ctx }, ctx, "line"))
eq("int(1)\n", plan.item.textEdit.newText)
require("completion_tools.edits").apply(
  { item = plan.item, context = ctx },
  ctx,
  require("completion_tools.config").defaults
)
local after_line = vim.tbl_extend("force", ctx, {
  row = 1,
  col = 0,
  before = "",
  line = "TAIL",
  prefix = "",
  start_col = 0,
})
continuation = assert(plan.continue(after_line))
eq({ line = 2, character = 3 }, continuation.items[1].textEdit.range["end"])
require("completion_tools.edits").apply(
  { item = continuation.items[1], context = after_line },
  after_line,
  require("completion_tools.config").defaults
)
eq({ "print(1)", "next() rest" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
item, ctx = suggestion("pr", "", "different text")
eq(nil, source.partial({ item = item, context = ctx }, ctx, "word"))
source.dispose()
native.new = original
print("copilot edits: single-line suffix overlap, Unicode, explicit ranges and reuse passed")
