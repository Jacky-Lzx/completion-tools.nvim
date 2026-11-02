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
local path = "/Users/test/Research/Very_Long_Project/TeX/4_Experimental_Results.tex"
local file_lines, file_ranges = doc.build({ kind = 17, detail = path }, "tex")
eq({ path }, file_lines)
eq({}, file_ranges)
file_lines, file_ranges = doc.build({ kind = 17, labelDetails = { description = path } }, "tex")
eq({ path }, file_lines)
eq({}, file_ranges)
eq(
  { path },
  doc.build({ kind = 17, detail = path, labelDetails = { detail = path, description = path } }, "tex")
)
eq(
  { "(value: string)", "module", "", "Help." },
  doc.build({
    labelDetails = { detail = "(value: string)", description = "module" },
    documentation = "Help.",
  }, "lua")
)
eq({ "\\`literal\\`" }, doc.build({ documentation = "\\`literal\\`" }, "lua"))
local function visible(value)
  local _, _, display = doc.build({ documentation = { kind = "markdown", value = value } }, "lua")
  return display
end
eq({ "@param url: bold and both." }, visible("@*param* `url`: **bold** and ***both***."))
eq({ "italic and bold", "snake_case and a__b__c" }, visible("_italic_ and __bold__\nsnake_case and a__b__c"))
eq({ "outer inner text", "outer inner text" }, visible("**outer *inner* text**\n*outer **inner** text*"))
eq({ "outer _unmatched text" }, visible("*outer _unmatched text*"))
eq({ "中文 斜体 粗体" }, visible("中文 *斜体* **粗体**"))
eq({ "*literal* and __literal__", "---" }, visible("`*literal*` and `__literal__`\n```lua\n---\n```"))
eq({ "    *literal*", "\t---" }, visible("    *literal*\n\t---"))
eq({ "\\*literal\\* and *unclosed and a * b" }, visible("\\*literal\\* and *unclosed and a * b"))
eq({ "", "", "", "    ---", "a --- b" }, visible("---\n * * *\n___\n    ---\na --- b"))
local prose = "---\n*italic* and **bold**"
eq(vim.split(prose, "\n"), doc.build({ detail = prose }, "lua"))
local _, literal_ranges, literal_visible =
  doc.build({ documentation = { kind = "plaintext", value = prose } }, "markdown")
eq({}, literal_ranges)
eq(vim.split(prose, "\n"), literal_visible)
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
local styled, decorations =
  doc.build({ documentation = "---\n@*param* `url`: **bold** and ***both***" }, "lua")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, styled)
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
doc.highlight(buf, ns, styled, decorations, opts, 28)
local styles, concealed, separator = {}, 0, nil
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local info = mark[4]
  if info.conceal == "" then
    concealed = concealed + 1
  end
  if info.virt_text then
    separator = info.virt_text[1][1]
  elseif info.hl_group then
    styles[info.hl_group] = styled[mark[2] + 1]:sub(mark[3] + 1, info.end_col)
  end
end
eq(7, concealed) -- A rule plus opening/closing delimiters for three emphasis spans.
eq(string.rep("─", 28), separator)
eq("param", styles.CompletionToolsDocItalic)
eq("bold", styles.CompletionToolsDocBold)
eq("both", styles.CompletionToolsDocBoldItalic)
require("completion_tools.ui").highlights()
eq("Special", vim.api.nvim_get_hl(0, { name = "CompletionToolsKindSnippet" }).link)
assert(vim.api.nvim_get_hl(0, { name = "CompletionToolsDocItalic" }).italic)
assert(vim.api.nvim_get_hl(0, { name = "CompletionToolsDocBold" }).bold)
local line = string.rep("中", 2000)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
opts.max_bytes = 7
doc.highlight(buf, ns, { line }, { { row = 0, first = 0, last = #line, filetype = "unknown" } }, opts)
vim.api.nvim_buf_delete(buf, { force = true })
print("documentation: code, Markdown conceal/styles/rules, literal text and UTF-8 bounds passed")
vim.cmd("qa!")
