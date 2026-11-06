local config = require("completion_tools.config")
local path = require("completion_tools.sources.path")
local doc = require("completion_tools.documentation")
local ui = require("completion_tools.ui")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/folder", "p")
vim.fn.writefile({ "-- **literal** `code`", "\treturn '中文'", "third line" }, root .. "/source.lua")
local binary = assert(io.open(root .. "/binary.bin", "wb"))
binary:write("binary\0data")
binary:close()
vim.fn.writefile({}, root .. "/empty.txt")
vim.fn.writefile({ string.rep("中", 1000) }, root .. "/unicode.txt")
local cfg = config.validate({
  path = {
    get_cwd = function()
      return root
    end,
    preview = { max_lines = 2 },
  },
})
local source = path.new(cfg.path)
local received
source.complete({ before = "./", col = 2, bufnr = 0 }, function(response)
  received = response
end)
assert(vim.wait(2000, function()
  return received ~= nil
end))
local items = {}
for _, item in ipairs(received.items) do
  items[item.label] = item
end
local function resolve(item, provider)
  local result
  (provider or source).resolve({ item = item }, function(value)
    result = value
  end)
  assert(vim.wait(2000, function()
    return result ~= nil
  end))
  return result
end
assert(items["source.lua"].data.path == root .. "/./source.lua")
local original = vim.deepcopy(items["source.lua"])
local text = resolve(items["source.lua"])
assert(vim.deep_equal(original, items["source.lua"]), "Resolve mutated a cached candidate")
assert(text._path_preview.filetype == "lua" and text._path_preview.truncated)
local lines, ranges = doc.build(text, "tex")
assert(
  vim.deep_equal(
    lines,
    { text.detail, "", "-- **literal** `code`", "\treturn '中文'", "… preview truncated" }
  )
)
assert(ranges[1].filetype == "lua" and ranges[1].row == 2, "Preview must use the file's syntax")
assert(resolve(items["binary.bin"]).documentation.value:find("Binary file", 1, true))
assert(resolve(items["folder/"])._path_preview == nil)
assert(resolve(items["empty.txt"])._path_preview.kind == "text")
local long = resolve(items["unicode.txt"])._path_preview
assert(long.truncated and #long.lines[1] <= 2000 and #long.lines[1] % 3 == 0)
local bytes = path.new(vim.tbl_deep_extend("force", cfg.path, { preview = { max_bytes = 5 } }))
local limited = resolve(items["unicode.txt"], bytes)._path_preview
assert(limited.truncated and limited.lines[1] == "中", "Byte limit must preserve UTF-8")
bytes.dispose()
local missing = resolve({ label = "missing", data = { path = root .. "/missing" } })
assert(missing.documentation.value:find("Cannot preview", 1, true))
local disabled = path.new(vim.tbl_deep_extend("force", cfg.path, { preview = { enabled = false } }))
assert(resolve(items["source.lua"], disabled)._path_preview == nil)
disabled.dispose()
local called = false
local cancel = source.resolve({ item = items["source.lua"] }, function()
  called = true
end)
cancel()
local disposed = path.new(cfg.path)
disposed.resolve({ item = items["source.lua"] }, function()
  called = true
end)
disposed.dispose()
vim.wait(30)
assert(not called, "Canceled/disposed reads delivered a stale preview")
for _, preview in ipairs({ false, { enabled = "yes" }, { max_bytes = 0 }, { max_lines = 1.5 } }) do
  assert(not pcall(config.validate, { path = { preview = preview } }))
end

-- The public image-tools contract must borrow the documentation pane and reject
-- late callbacks after selection changes, including errors and menu teardown.
local requests, closes, resizes = {}, 0, 0
package.loaded.image_tools = {
  render = function(request)
    requests[#requests + 1] = request
    assert(vim.api.nvim_win_get_buf(request.win) == request.buf)
    assert(request.page == 1 and request.fit_pixels == true)
    return {
      close = function()
        closes = closes + 1
      end,
      resize = function()
        resizes = resizes + 1
      end,
    }
  end,
}
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
local menu = { { item = { label = "source.lua", kind = 17 }, source_id = "path", start_col = 0 } }
ui.highlights()
ui.render(menu, 1, ctx, cfg)
assert(ui.visible())
local owner = vim.api.nvim_get_current_win()
local png = resolve({ label = "image.png", data = { path = root .. "/image.png" } })
assert(ui.documentation(png, cfg))
assert(#requests == 1 and #vim.api.nvim_list_wins() == 3)
local first = requests[1]
assert(first.is_valid() and vim.api.nvim_get_current_win() == owner)
assert(vim.api.nvim_win_get_height(first.win) > 1, "Media needs a full preview viewport")
ui.documentation(png, cfg)
assert(#requests == 1 and resizes == 1, "Reposition must reuse the active view")
assert(vim.wo[first.win].conceallevel == 0 and not ui.scroll_documentation(4))
local pdf = resolve({ label = "figure.PDF", data = { path = root .. "/figure.PDF" } })
ui.documentation(pdf, cfg)
assert(#requests == 2 and closes == 1 and not first.is_valid())
ui.documentation(text, cfg)
assert(closes == 2 and not requests[2].is_valid())
assert(vim.wo[first.win].conceallevel == 0, "Literal file contents must disable Markdown syntax conceal")
local painted = vim.api.nvim_buf_get_lines(first.buf, 0, -1, false)
first.on_error("stale failure")
assert(vim.deep_equal(painted, vim.api.nvim_buf_get_lines(first.buf, 0, -1, false)))
ui.documentation(pdf, cfg)
ui.hide_documentation()
assert(closes == 3 and not requests[3].is_valid())
ui.documentation(png, cfg)
ui.dispose()
assert(closes == 4 and #vim.api.nvim_list_wins() == 1)
package.loaded.image_tools = {
  render = function()
    return nil, "terminal unavailable"
  end,
}
ui.render(menu, 1, ctx, cfg)
ui.documentation(png, cfg)
local fallback
for _, win in ipairs(vim.api.nvim_list_wins()) do
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].filetype == "markdown" then
    fallback = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
end
assert(fallback[3] == "Preview: terminal unavailable")
ui.dispose()
source.dispose()
vim.fn.delete(root, "rf")
print("path preview: bounded async text, literal syntax, media pane lifecycle and stale callbacks passed")
