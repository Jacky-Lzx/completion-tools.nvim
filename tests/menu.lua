local render = require("completion_tools.render")
local highlight = require("completion_tools.highlight")
local config = require("completion_tools.config")
local count = 0
local function test(name, run)
  highlight.clear()
  local ok, err = xpcall(run, debug.traceback)
  assert(ok, name .. ": " .. tostring(err))
  count = count + 1
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ expected = a, actual = b }))
end
local function entry(item)
  return { item = item, source_id = "lsp", start_col = 0 }
end
local ctx = { before = "", filetype = "missing-parser" }
local function span_for(spans, group)
  return vim.tbl_filter(function(s)
    return s[3] == group
  end, spans)
end
local opts = config.validate({ menu = { highlight = { treesitter = false } } }).menu
package.preload["colorful-menu"] = function()
  error("colorful-menu must not be used")
end

test("kind coverage, unknown kind, configurable icons", function()
  local kinds = require("completion_tools.kinds")
  for kind = 1, 25 do
    local name, icon, group = kinds.get(kind)
    assert(name ~= "Unknown" and icon ~= "" and group == "CompletionToolsKind" .. name)
  end
  eq("Text", kinds.get())
  eq("Unknown", kinds.get(999))
  local _, icon = kinds.get(3, { Function = "ƒ" })
  eq("ƒ", icon)
  _, icon = kinds.get(3, false)
  eq("", icon)
end)
test("column replacement, validation and grouping", function()
  local cfg = config.validate({ menu = { min_width = 1, columns = { { "label", "source", gap = 3 } } } })
  eq(1, #cfg.menu.columns)
  for _, columns in ipairs({ {}, { { "bad" } }, { { "label", "label" } } }) do
    assert(not pcall(config.validate, { menu = { columns = columns } }))
  end
  local items = { entry({ label = "x" }) }
  local layout = render.prepare(items, cfg.menu, 80)
  local line = render.row(layout, 1, items[1], ctx, cfg.menu)
  assert(line:find("x   LSP", 1, true))
end)
test("stable columns, Unicode clipping and immutable CompletionItems", function()
  local items = {
    entry({
      label = "decode",
      kind = 3,
      labelDetails = { detail = "(value: string): number", description = "中文模块" },
    }),
    entry({ label = "类型名字", kind = 7 }),
    entry({ label = string.rep("long中文", 60), kind = 25 }),
  }
  local original = vim.deepcopy(items)
  for width = 4, 90 do
    local layout, ending = render.prepare(items, opts, width), nil
    for i, e in ipairs(items) do
      local line, spans = render.row(layout, i, e, ctx, opts)
      eq(layout.width, vim.fn.strdisplaywidth(line))
      assert(layout.width <= width)
      local kindcol
      for _, span in ipairs(spans) do
        assert(span[1] >= 0 and span[2] <= #line and span[2] > span[1])
        local b1, b2 = line:byte(span[1] + 1), line:byte(span[2] + 1)
        assert(not b1 or b1 < 128 or b1 >= 192)
        assert(not b2 or b2 < 128 or b2 >= 192)
        if span[3]:find("^CompletionToolsKind") then
          kindcol = vim.fn.strdisplaywidth(line:sub(1, span[1]))
        end
      end
      if width >= 40 then
        assert(line:find(({ "Function", "Class", "TypeParameter" })[i], 1, true))
        if ending then
          eq(ending, kindcol)
        end
        ending = kindcol
      end
    end
  end
  eq(original, items)
  local layout = render.prepare({ items[1] }, opts, 120)
  local line = render.row(layout, 1, items[1], ctx, opts)
  assert(line:find("decode(value: string): number  中文模块", 1, true))
end)
test("separate details, disabled icons, controls and bounded text", function()
  local menu = config.validate({
    menu = {
      label_details = false,
      min_width = 1,
      kind_icons = false,
      max_label_bytes = 64,
      columns = { { "kind_icon" }, { "label", "label_detail", gap = 1 }, { "label_description" } },
    },
  }).menu
  local items = { entry({ label = "foo", detail = "foo(x)", labelDetails = { description = "中\n文" } }) }
  local layout = render.prepare(items, menu, 100)
  eq("label", layout.columns[1].name)
  local line = render.row(layout, 1, items[1], ctx, menu)
  assert(line:find("foo (x)", 1, true) and line:find("中 文", 1, true))
  local cleaned = require("completion_tools.text").clean(string.rep("中文", 10000), 64)
  assert(#cleaned <= 64 and vim.str_utfindex(cleaned) > 0)
end)
test("file metadata aligns, preserves names and path tails, and never becomes code", function()
  local root = vim.fn.getcwd()
  local items = {
    entry({ label = "TeX/0_Abstract.tex", kind = 17, detail = root .. "/paper/TeX/0_Abstract.tex" }),
    entry({
      label = "TeX/4_Experimental_Results.tex",
      kind = 17,
      labelDetails = { description = root .. "/paper/TeX/4_Experimental_Results.tex" },
    }),
  }
  local original = vim.deepcopy(items)
  local menu = config.validate({ menu = { max_width = 160 } }).menu
  local layout = render.prepare(items, menu, 160)
  local previous
  for i, e in ipairs(items) do
    local line, spans = render.row(layout, i, e, { before = "Te", filetype = "tex" }, menu)
    local at = assert(line:find("paper/TeX/", 1, true))
    if previous then
      eq(previous, at)
    end
    previous = at
    assert(not line:find(root, 1, true), "path should be relative to the project")
    assert(#span_for(spans, "CompletionToolsMatch") > 0)
    for _, span in ipairs(spans) do
      assert(span[3]:sub(1, 1) ~= "@", "file was highlighted as code")
      if span[1] <= at - 1 and span[2] >= at then
        eq("CompletionToolsSource", span[3])
      end
    end
  end
  layout = render.prepare(items, opts, 72)
  local line = render.row(layout, 2, items[2], ctx, opts)
  assert(line:find(items[2].item.label, 1, true), "metadata displaced the file name: " .. line)
  assert(line:find("…", 1, true) and line:find("Results.tex", 1, true), line)
  for width = 4, 100 do
    layout = render.prepare(items, opts, width)
    for i, e in ipairs(items) do
      local rendered = render.row(layout, i, e, ctx, opts)
      eq(layout.width, vim.fn.strdisplaywidth(rendered))
    end
  end
  eq(original, items)
end)
test("path truncation keeps UTF-8 suffixes within display cells", function()
  local text = require("completion_tools.text")
  local value = "/目录/论文/章节😀.tex"
  eq(value, text.truncate_path(value, 80))
  for width = 1, 30 do
    local suffix = text.truncate_path(value, width)
    assert(vim.fn.strdisplaywidth(suffix) <= width)
    assert(vim.str_utfindex(suffix) > 0)
    if width >= 8 then
      assert(suffix:sub(-4) == ".tex")
    end
  end
end)
test("lexical fallback, deprecation and whole UTF-8 match spans", function()
  local e = entry({
    label = "中文decode",
    kind = 3,
    tags = { 1 },
    labelDetails = { detail = '(value: string, count: 12): Result<"中">' },
  })
  local layout = render.prepare({ e }, opts, 120)
  local line, spans = render.row(layout, 1, e, { before = "中文", filetype = "missing-parser" }, opts)
  eq(2, #span_for(spans, "CompletionToolsMatch"))
  eq(1, #span_for(spans, "CompletionToolsDeprecated"))
  for _, name in ipairs({ "@type.builtin", "@variable.parameter", "@number", "@type", "@string" }) do
    assert(#span_for(spans, name) > 0, name .. " missing: " .. line)
  end
  local marks = span_for(spans, "CompletionToolsMatch")
  eq("中文", line:sub(marks[1][1] + 1, marks[2][2]))
end)
test("command-line names are literal, keep matching and do not share syntax caches", function()
  for _, label in ipairs({ "write-local-help", "<Help>", "vim.lsp.buf.signature_help.Opts" }) do
    local e = { item = { label = label, kind = 18 }, source_id = "cmdline", start_col = 5 }
    -- Prime the same text/kind in an Insert-mode context first.
    highlight.get(label, #label, e, { mode = "insert", filetype = "lua" }, opts.highlight)
    local context = { mode = "cmdline", completion_type = "help", filetype = "lua", before = "help help" }
    eq(
      { { 0, #label, "CompletionToolsKindReference", 110 } },
      highlight.get(label, #label, e, context, opts.highlight)
    )
    local layout = render.prepare({ e }, opts, 120)
    local _, spans = render.row(layout, 1, e, context, opts)
    assert(#span_for(spans, "CompletionToolsMatch") > 0)
    for _, span in ipairs(spans) do
      assert(span[3]:sub(1, 1) ~= "@", "help tag was interpreted as code")
    end
    for _, kind in ipairs({ "file", "dir", "command", "option", "customlist" }) do
      context.completion_type = kind
      eq(
        { { 0, #label, "CompletionToolsKindReference", 110 } },
        highlight.get(label, #label, e, context, opts.highlight)
      )
    end
  end
end)
test("command-line code uses its own language rather than the buffer filetype", function()
  local e = entry({ label = 'foo(12, "x")', kind = 3 })
  local menu = config.validate({}).menu
  if pcall(vim.treesitter.language.add, "lua") then
    local spans = highlight.get(
      e.item.label,
      3,
      e,
      { mode = "cmdline", completion_type = "lua", filetype = "tex" },
      menu.highlight
    )
    assert(#span_for(spans, "@string.lua") > 0, "Lua command completion inherited the buffer language")
  end
  for _, kind in ipairs({ "lua", "expression", "function" }) do
    local spans = highlight.get(
      e.item.label,
      3,
      e,
      { mode = "cmdline", completion_type = kind, filetype = "tex" },
      opts.highlight
    )
    assert(#span_for(spans, "@string") > 0)
  end
end)
test("custom spans are clipped and never contaminate cached built-in spans", function()
  local menu = config.validate({
    menu = {
      highlight = {
        treesitter = false,
        custom = function()
          return { { -100, 10000, "Special", 1.5 }, { 2.5, 4, "Error" }, { "bad", 1 }, false }
        end,
      },
    },
  }).menu
  local e = entry({ label = "中文name", kind = 3 })
  local layout = render.prepare({ e }, menu, 30)
  local _, spans = render.row(layout, 1, e, ctx, menu)
  eq(1, #span_for(spans, "Special"))
  eq(0, #span_for(highlight.get("中文name", 10, e, ctx, opts.highlight), "Special"))
  local disabled = config.validate({ menu = { highlight = { enabled = false } } }).menu
  eq({}, highlight.get("name", 4, e, ctx, disabled.highlight))
end)
test("native Tree-sitter is optional, bounded and cached", function()
  local original, calls = vim.treesitter.get_string_parser, 0
  vim.treesitter.get_string_parser = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, err = xpcall(function()
    local menu, e = config.validate({}).menu, entry({ label = "plain", kind = 3 })
    highlight.get("plain", 5, e, { filetype = "lua" }, menu.highlight)
    eq(0, calls)
    if pcall(vim.treesitter.language.add, "lua") then
      vim.treesitter.query.set("lua", "highlights", "(number) @number\n(string) @string")
      local code = 'foo(12, "中文")'
      local spans = highlight.get(code, 3, e, { filetype = "lua" }, menu.highlight)
      assert(#span_for(spans, "@number.lua") > 0, "native parser captures missing")
      assert(#span_for(spans, "@string.lua") > 0)
      eq(1, calls)
      highlight.get(code, 3, e, { filetype = "lua" }, menu.highlight)
      eq(1, calls)
      menu.highlight.max_bytes = 4
      highlight.get("bar(123)", 3, e, { filetype = "lua" }, menu.highlight)
      eq(1, calls)
      menu.highlight.max_bytes, menu.highlight.cache_size = 1024, 1
      highlight.clear()
      for _, value in ipairs({ code, "bar(1)", code }) do
        highlight.get(value, 3, e, { filetype = "lua" }, menu.highlight)
      end
      eq(4, calls)
      vim.treesitter.query.set("lua", "highlights", nil)
    else
      print("menu: optional Lua parser unavailable; lexical fallback covered")
    end
    assert(#span_for(highlight.get("missing(x: string)", 7, e, ctx, menu.highlight), "@type.builtin") > 0)
  end, debug.traceback)
  vim.treesitter.get_string_parser = original
  assert(ok, err)
end)
print("menu: " .. count .. " passed")
vim.cmd("qa!")
