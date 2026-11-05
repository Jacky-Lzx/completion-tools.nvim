local insertion = require("completion_tools.insertion")
local edits = require("completion_tools.edits")
local config = require("completion_tools.config")
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ expected = a, actual = b }))
end
eq("foo\n      inner\n    end", insertion.indent("foo\n  inner\nend", "    "))
eq("  foo\n      inner\n    end", insertion.indent("  foo\n    inner\n  end", "    "))
eq("foo\n\n\tend", insertion.indent("foo\n\nend", "\t"))
for _, kind in ipairs({ 2, 3 }) do
  for _, suffix in ipairs({ "", " ", "value", ")", ",", "😀" }) do
    local text, offset = insertion.brackets("foo", { kind = kind }, suffix)
    eq({ "foo()", 1 }, { text, offset })
  end
  for _, body in ipairs({ "foo()", "foo(value)", "foo(${1:value})$0" }) do
    eq(body, insertion.brackets(body, { kind = kind }, "value"))
  end
  eq("foo", insertion.brackets("foo", { kind = kind }, "(value)"))
  eq("foo", insertion.brackets("foo", { kind = kind }, " (value)"))
  local text, offset = insertion.brackets("foo(", { kind = kind }, "value")
  eq({ "foo()", 1 }, { text, offset })
end
eq("foo", insertion.brackets("foo", { kind = 6 }, "value"))
eq("foo$0", insertion.brackets("foo$0", { kind = 3, insertTextFormat = 2 }, "value"))
assert(not pcall(config.validate, { accept = { mode = "invalid" } }))
local line = "😀foTAIL"
local ctx = {
  row = 0,
  before = "😀fo",
  line = line,
  bufnr = vim.api.nvim_get_current_buf(),
  winid = vim.api.nvim_get_current_win(),
}
local entry = {
  context = ctx,
  start_col = 4,
  item = {
    label = "foobar",
    _encoding = "utf-16",
    textEdit = {
      newText = "foobar",
      insert = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 4 } },
      replace = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 8 } },
    },
  },
}
for _, mode in ipairs({ "insert", "replace" }) do
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  edits.apply(entry, ctx, config.validate({ accept = { mode = mode } }))
  eq("😀foobar" .. (mode == "insert" and "TAIL" or ""), vim.api.nvim_get_current_line())
end
local seen
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "    fo" })
ctx.line, ctx.before = "    fo", "    fo"
entry.context, entry.start_col = ctx, 4
entry.item = { label = "foo", insertText = "foo\n  ${1:bar}\n$0", insertTextFormat = 2, insertTextMode = 2 }
edits.apply(
  entry,
  ctx,
  config.validate({
    snippets = {
      expand = function(text, options)
        seen = { text, options }
      end,
    },
  })
)
eq("foo\n      ${1:bar}\n    $0", seen[1])
eq(2, seen[2].insert_text_mode)
eq("    ", seen[2].indentation)
local caps = require("completion_tools").get_lsp_capabilities().textDocument.completion
eq({ 1, 2 }, caps.completionItem.insertTextModeSupport.valueSet)
eq(2, caps.insertTextMode)
print(
  "insertion: function brackets, insert/replace UTF-16 ranges, relative indentation, engine options and capabilities passed"
)
