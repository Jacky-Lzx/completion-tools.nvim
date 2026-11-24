if vim.env.COMPLETION_DOC_PARSER_RTP then
  vim.opt.rtp:append(vim.env.COMPLETION_DOC_PARSER_RTP)
end

local doc = require("completion_tools.documentation")
local config = require("completion_tools.config")
local ui = require("completion_tools.ui")
local CompletionItemKind = require("vim.lsp.protocol").CompletionItemKind

local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

local path = "/Users/test/Research/[project]/TeX/4_Experimental_Results.tex"
local lines, language = doc.build({
  kind = 17,
  detail = path,
  labelDetails = { detail = path, description = path },
}, "tex")
eq({ path }, lines)
eq(nil, language)
local literal = "~~~\n  keep **bold** and `ticks`\n~~~"
local plain_item = { detail = literal, documentation = { kind = "plaintext", value = "**plain** [text]" } }
lines, language = doc.build(plain_item, "markdown")
eq({ "~~~", "  keep **bold** and `ticks`", "~~~", "", "**plain** [text]" }, lines)
eq(nil, language)
lines, language = doc.build({ detail = "return 42" }, "lua")
eq({ "return 42" }, lines)
eq("lua", language)
eq({}, doc.build({}))

local signature = {
  label = "build(item, filetype)",
  kind = CompletionItemKind.Function,
  detail = "function",
  _client_name = "lua_ls",
  documentation = {
    kind = "markdown",
    value = "```lua\nfunction M.build(item, filetype)\n  -> string[]\n  2. string?\n```",
  },
}
local signature_lines = vim.split(signature.documentation.value, "\n", { plain = true })
local lsp = require("completion_tools.sources.lsp").new()
local signature_document = assert(lsp.documentation(signature))
eq(signature_lines, doc.build(signature, "lua", signature_document))
eq("function", doc.build(signature, "lua")[2])
eq("function", signature.detail)
eq({ "function" }, doc.build({ kind = signature.kind, detail = signature.detail, label = signature.label }, "lua"))
local other_label = vim.tbl_extend("force", signature, { label = "other()" })
eq(nil, lsp.documentation(other_label))
local other_detail = vim.tbl_extend("force", signature, { detail = "completion_tools.documentation" })
eq(nil, lsp.documentation(other_detail))

local markdown = 'Use `name` and **bold**.\n\n```lua\nlocal value = map["key"]\n```'
local item = {
  detail = "local map = {}",
  labelDetails = { detail = "local map = {}", description = literal },
  documentation = { kind = "markdown", value = markdown },
}
lines, language = doc.build(item, "lua")
eq({
  "~~~lua",
  "local map = {}",
  "~~~",
  "~~~~",
  "~~~",
  "  keep **bold** and `ticks`",
  "~~~",
  "~~~~",
  "",
  "Use `name` and **bold**.",
  "",
  "```lua",
  'local value = map["key"]',
  "```",
}, lines)
eq("markdown", language)

assert(not pcall(config.validate, { documentation = { on_render = true } }))
local renders, current = 0, nil
local cfg = config.validate({
  documentation = {
    on_render = function(ctx)
      assert(vim.api.nvim_win_get_buf(ctx.win) == ctx.buf)
      renders, current = renders + 1, ctx
    end,
  },
})
local ctx = {
  winid = vim.api.nvim_get_current_win(),
  bufnr = 0,
  row = 0,
  col = 0,
  start_col = 0,
  mode = "insert",
  before = "",
  line = "",
  filetype = "lua",
}
local function menu(label)
  ui.render({ { item = { label = label }, source_id = "lsp", start_col = 0 } }, 1, ctx, cfg)
end

menu("fixture")
assert(ui.documentation(item, cfg))
eq(1, renders)
eq(item, current.item)
eq(lines, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))
assert(vim.treesitter.highlighter.active[current.buf], "Markdown rendering should start native Tree-sitter")
local parser = vim.treesitter.get_parser(current.buf, "markdown")
parser:parse(true)
local captures = vim.treesitter.get_captures_at_pos(current.buf, 12, 19)
assert(
  vim.tbl_contains(
    vim.tbl_map(function(capture)
      return capture.lang
    end, captures),
    "lua"
  ),
  "The fenced code should use the Lua parser"
)
eq(2, vim.wo[current.win].conceallevel)
local function marks(primary, fallback)
  local source = vim.api.nvim_buf_get_extmarks(current.buf, vim.api.nvim_create_namespace(primary), 0, -1, {
    details = true,
  })
  if #source == 0 then
    source = vim.api.nvim_buf_get_extmarks(current.buf, vim.api.nvim_create_namespace(fallback), 0, -1, {
      details = true,
    })
  end
  return source
end
local function concealed_rows()
  return vim.tbl_map(function(mark)
    return mark[2]
  end, marks("base-tools-markdown-fences", "completion-tools-documentation"))
end
eq({ 0, 2, 3, 7, 11, 13 }, concealed_rows())

-- Older highlight queries can highlight the block without hiding its fences.
vim.treesitter.query.set("markdown", "highlights", "(fenced_code_block) @markup.raw.block")
assert(ui.documentation(signature, cfg, signature_document))
eq(signature_lines, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))
eq({ 0, 4 }, concealed_rows())
eq(3, vim.api.nvim_win_get_height(current.win))
vim.treesitter.query.set("markdown", "highlights", nil)

assert(ui.documentation(plain_item, cfg))
eq(0, vim.wo[current.win].conceallevel)
eq({}, concealed_rows())
assert(not vim.treesitter.highlighter.active[current.buf], "Plain text should clear the Markdown highlighter")

local markdown_code = { "```lua", "return true", "```" }
assert(ui.documentation({}, cfg, doc.code(table.concat(markdown_code, "\n"), "markdown")))
eq(markdown_code, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))
assert(vim.treesitter.highlighter.active[current.buf], "Literal Markdown can still use a Markdown parser")
eq(0, vim.wo[current.win].conceallevel)
eq(3, vim.api.nvim_win_get_height(current.win))

local start = vim.treesitter.start
vim.treesitter.start = function()
  error("Parser unavailable")
end
assert(ui.documentation({}, cfg, doc.code("**raw**", "lua")))
vim.treesitter.start = start
eq({ "**raw**" }, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))
assert(not vim.treesitter.highlighter.active[current.buf])

local rule_lines = { "Markdown preview with enough text", "", "---", "", "A heading", "---", "", "> ***" }
local rule_text = table.concat(rule_lines, "\n")
local rule_doc = doc.markdown(rule_text)
local function rule_marks()
  return marks("base-tools-markdown-rules", "completion-tools-documentation-rules")
end

assert(ui.documentation({}, cfg, rule_doc))
local rule_win = current.win
local rule_width = vim.api.nvim_win_get_width(rule_win)
local rules = rule_marks()
eq(2, #rules)
eq({ 2, 7 }, { rules[1][2], rules[2][2] })
eq({ { string.rep("─", rule_width), "CompletionToolsDocBorder" } }, rules[1][4].virt_text)
eq({ { string.rep("─", rule_width - 2), "CompletionToolsDocBorder" } }, rules[2][4].virt_text)

local narrow = vim.deepcopy(cfg)
narrow.documentation.max_width = 16
assert(ui.documentation({}, narrow, rule_doc))
eq(rule_win, current.win)
eq(16, vim.api.nvim_win_get_width(rule_win))
eq({ { string.rep("─", 16), "CompletionToolsDocBorder" } }, rule_marks()[1][4].virt_text)
local rule_tick = vim.api.nvim_buf_get_changedtick(current.buf)
assert(ui.documentation({}, narrow, doc.code(rule_text, "markdown")))
eq(rule_tick, vim.api.nvim_buf_get_changedtick(current.buf))
eq({}, rule_marks())
eq(rule_lines, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))

local long = {
  documentation = { kind = "plaintext", value = string.rep(string.rep("word ", 12) .. "\n", 40) },
}
local has_scrollbar = pcall(require, "base_tools.preview")
local function anchors(win)
  return vim.tbl_filter(function(candidate)
    return vim.api.nvim_win_get_config(candidate).win == win
  end, vim.api.nvim_list_wins())
end
local function scroll_percentage(win)
  local footer = vim.api.nvim_win_get_config(win).footer
  if type(footer) == "table" then
    for _, part in ipairs(footer) do
      local percentage = tonumber(part[1]:match("(%d+)%%"))
      if percentage then
        return percentage
      end
    end
  end
end
assert(ui.documentation(long, cfg))
if has_scrollbar then
  eq(0, scroll_percentage(current.win))
  eq(1, #anchors(current.win))
end
assert(ui.scroll_documentation(12))
local win = current.win
if has_scrollbar then
  local percentage = scroll_percentage(win)
  assert(percentage > 0 and percentage < 100)
end
local old_view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
local old_width = vim.api.nvim_win_get_width(win)
local old_tick = vim.api.nvim_buf_get_changedtick(current.buf)
assert(old_view.topline > 1)
local before_move = renders

-- Move and narrow the document while keeping the same candidate content.
menu("fixture-" .. string.rep("w", 64))
eq(before_move + 1, renders)
eq(win, current.win)
assert(vim.api.nvim_win_get_width(win) < old_width)
eq(old_tick, vim.api.nvim_buf_get_changedtick(current.buf))
eq(old_view.topline, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)

local refreshed = vim.deepcopy(long)
assert(ui.documentation(refreshed, cfg))
eq(old_tick, vim.api.nvim_buf_get_changedtick(current.buf))
eq(old_view.topline, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)

local has_label, label = pcall(require, "base_tools.label")
if has_scrollbar and has_label and label.scroll_percent({ fallback = "below" }).fallback == "below" then
  refreshed.documentation.value = refreshed.documentation.value .. "More documentation"
  assert(ui.documentation(refreshed, cfg))
  eq(old_view.topline, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)
end

long.documentation.value = "Updated description"
assert(ui.documentation(long, cfg))
eq({ "Updated description" }, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))
eq(1, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)
assert(ui.scroll_documentation(4))
eq(1, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)

local compact = vim.deepcopy(cfg)
compact.documentation.max_width = 20
compact.documentation.max_height = 4
assert(ui.documentation({ documentation = "```text\n" .. string.rep("x", 200) .. "\n```" }, compact))
assert(ui.scroll_documentation(100))
local bottom = vim.api.nvim_win_call(win, vim.fn.winsaveview)
eq(2, bottom.topline)
eq(120, bottom.skipcol)
if has_scrollbar then
  eq(100, scroll_percentage(win))
end
assert(ui.scroll_documentation(4))
eq(bottom, vim.api.nvim_win_call(win, vim.fn.winsaveview))

assert(ui.scroll_documentation(-4))
eq(40, vim.api.nvim_win_call(win, vim.fn.winsaveview).skipcol)

if has_scrollbar then
  assert(ui.documentation(long, cfg))
  eq(0, #anchors(win))
  eq(nil, scroll_percentage(win))

  local borderless = vim.deepcopy(cfg)
  borderless.documentation.border = "none"
  assert(ui.documentation({ documentation = string.rep("visible line\n", 50) }, borderless))
  local floats = anchors(win)
  eq(2, #floats)
  local label = vim.iter(floats):find(function(candidate)
    return vim.api.nvim_win_get_height(candidate) == 1
  end)
  assert(label)
  local label_buf = vim.api.nvim_win_get_buf(label)
  eq({ "0%" }, vim.api.nvim_buf_get_lines(label_buf, 0, -1, false))
  assert(ui.scroll_documentation(100))
  eq({ "100%" }, vim.api.nvim_buf_get_lines(label_buf, 0, -1, false))
  eq(50 - vim.api.nvim_win_get_height(win) + 1, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)
  vim.api.nvim_win_close(win, true)
  for _, candidate in ipairs(floats) do
    assert(not vim.api.nvim_win_is_valid(candidate), "orphaned scrollbar or scroll percentage")
  end
end
ui.hide()
assert(not ui.documentation(item, cfg))
ui.dispose()

print("documentation: native Markdown and injected code, literal fallback, render hooks and scroll reuse passed")
