if vim.env.COMPLETION_DOC_PARSER_RTP then
  vim.opt.rtp:append(vim.env.COMPLETION_DOC_PARSER_RTP)
end

local doc = require("completion_tools.documentation")
local config = require("completion_tools.config")
local ui = require("completion_tools.ui")

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

assert(ui.documentation(plain_item, cfg))
eq(0, vim.wo[current.win].conceallevel)
assert(not vim.treesitter.highlighter.active[current.buf], "Plain text should clear the Markdown highlighter")

local start = vim.treesitter.start
vim.treesitter.start = function()
  error("Parser unavailable")
end
assert(ui.documentation({ documentation = "**raw**" }, cfg))
vim.treesitter.start = start
eq({ "**raw**" }, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))
assert(not vim.treesitter.highlighter.active[current.buf])

local long = {
  documentation = { kind = "plaintext", value = string.rep(string.rep("word ", 12) .. "\n", 40) },
}
assert(ui.documentation(long, cfg))
assert(ui.scroll_documentation(24))
local win = current.win
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

assert(ui.documentation(vim.deepcopy(long), cfg))
eq(old_tick, vim.api.nvim_buf_get_changedtick(current.buf))
eq(old_view.topline, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)

long.documentation.value = "Updated description"
assert(ui.documentation(long, cfg))
eq({ "Updated description" }, vim.api.nvim_buf_get_lines(current.buf, 0, -1, false))
eq(1, vim.api.nvim_win_call(win, vim.fn.winsaveview).topline)
ui.hide()
assert(not ui.documentation(item, cfg))
ui.dispose()

print("documentation: native Markdown and injected code, literal fallback, render hooks and scroll reuse passed")
