local doc = require("completion_tools.documentation")
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local markdown = {
  kind = "markdown",
  value = '```latex\n\\input{中文}\n```\n\nUse `name` and `` `tick` ``.\n~~~lua\n  return "value"\n~~~',
}
local lines, ranges = doc.build({ detail = "\\input", documentation = markdown }, "tex")
eq({ "\\input", "", "\\input{中文}", "", "Use name and `tick`.", '  return "value"' }, lines)
eq(5, #ranges)
eq("latex", ranges[2].filetype)
eq("lua", ranges[5].filetype)
local literal = "```\n  keep `ticks`\n```"
eq(vim.split(literal, "\n"), doc.build({ documentation = { kind = "plaintext", value = literal } }, "tex"))
eq(vim.split(literal, "\n"), doc.build({ detail = literal }, "markdown"))
eq({ "literal", "text `unmatched" }, doc.build({ documentation = "```literal```\ntext `unmatched" }, "lua"))
eq(
  { "```", "text", "~~~", "value" },
  doc.build({ documentation = "~~~~lua\n```\ntext\n~~~\nvalue\n~~~~" }, "lua")
)
eq({ "unclosed code" }, doc.build({ documentation = "```lua\nunclosed code" }, "lua"))
eq({}, doc.build({ documentation = "```lua\n```" }, "lua"))
eq({ "\\`literal\\`" }, doc.build({ documentation = "\\`literal\\`" }, "lua"))
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace("completion-doc-test")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local opts = require("completion_tools.config").validate({}).menu.highlight
opts.custom = function()
  error("menu callback must not run for documentation")
end
doc.highlight(buf, ns, lines, ranges, opts)
local groups = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  groups[mark[4].hl_group] = true
end
assert(groups.CompletionToolsDocCode and groups["@function"] and groups["@string"])
require("completion_tools.ui").highlights()
eq("Special", vim.api.nvim_get_hl(0, { name = "CompletionToolsKindSnippet" }).link)
local line = string.rep("中", 2000)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
opts.max_bytes = 7
doc.highlight(buf, ns, { line }, { { row = 0, first = 0, last = #line, filetype = "unknown" } }, opts)
vim.api.nvim_buf_delete(buf, { force = true })
print("documentation: fenced/inline code, literal text, languages, highlights and UTF-8 bounds passed")
vim.cmd("qa!")
