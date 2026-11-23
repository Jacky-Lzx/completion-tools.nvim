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
local function paint(entry, context, menu, width)
  local layout = render.prepare({ entry }, menu, width or 120)
  return render.row(layout, 1, entry, context, menu)
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
  assert(line:find("x   lsp", 1, true))
end)
test("LSP source column shows the originating client with a generic fallback", function()
  local items = {
    entry({ label = "alpha", _client_name = "lua_ls" }),
    entry({ label = "beta", _client_name = "texlab" }),
    entry({ label = "gamma" }),
  }
  local lsp = require("completion_tools.sources.lsp").new()
  for _, candidate in ipairs(items) do
    candidate.source_name = lsp.display_name(candidate.item)
  end
  local original = vim.deepcopy(items)
  local layout = render.prepare(items, opts, 100)
  for i, name in ipairs({ "lua_ls", "texlab", "LSP" }) do
    local line = render.row(layout, i, items[i], ctx, opts)
    assert(line:find(name, 1, true), line)
  end
  eq(original, items)
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
test("legacy prose stays muted in inline and separate details while signatures retain syntax", function()
  for _, columns in ipairs({ { { "label" } }, { { "label" }, { "label_detail" } } }) do
    local menu = config.validate({ menu = { columns = columns, max_width = 160 } }).menu
    for _, kind in ipairs({ 2, 3, 4, 10, 12, 18 }) do
      for _, detail in ipairs({
        "Requested image width",
        "Include an image [graphicx]",
        "PDF box used for natural image dimensions",
        "Use the high-resolution bounding box",
      }) do
        local e = entry({ label = "width", kind = kind, detail = detail, _client_name = "latex_lsp_human" })
        local original = vim.deepcopy(e)
        local layout = render.prepare({ e }, menu, 160)
        local line, spans = render.row(layout, 1, e, { before = "wi", filetype = "tex" }, menu)
        local first = assert(line:find(detail, 1, true)) - 1
        local muted = false
        for _, span in ipairs(spans) do
          if span[1] < first + #detail and span[2] > first then
            eq("CompletionToolsSource", span[3])
            muted = span[1] <= first and span[2] >= first + #detail
          end
        end
        assert(muted, "prose must have a uniform metadata color")
        assert(#span_for(spans, "CompletionToolsMatch") > 0)
        eq(original, e)
      end
    end
    for _, item in ipairs({
      { label = "decode", kind = 3, detail = "function decode(value: string)" },
      { label = "decode", kind = 3, detail = "decode(value: string)" },
      { label = "decode", kind = 10, detail = "(value: string)" },
      { label = "decode", kind = 10, labelDetails = { detail = "(value: string)" } },
    }) do
      local e = entry(item)
      local layout = render.prepare({ e }, menu, 160)
      local _, spans = render.row(layout, 1, e, ctx, menu)
      assert(#span_for(spans, "@type.builtin") > 0, "signature lost syntax coloring")
    end
  end
end)
test("session columns retain space across changing results and fit after resize", function()
  local menu = config.validate({ menu = { max_width = 72 } }).menu
  local long = { entry({ label = "alphaLongName", kind = 25, labelDetails = { description = "module" } }) }
  local short = { entry({ label = "alpha", kind = 1 }) }
  local layout = render.prepare(long, menu, 100)
  local retained = render.prepare(short, menu, 100, layout)
  eq(layout.width, retained.width)
  eq(layout.columns, retained.columns)
  local crowded = render.prepare({ entry({ label = string.rep("a", 200) }) }, menu, 100, retained)
  for i, column in ipairs(retained.columns) do
    assert(crowded.columns[i].width >= column.width, "new label displaced an existing column")
  end
  for available = 4, 90 do
    local resized = render.prepare(short, menu, available, crowded)
    local line = render.row(resized, 1, short[1], ctx, menu)
    eq(resized.width, vim.fn.strdisplaywidth(line))
    assert(resized.width <= available)
  end
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
test("Copilot fields stay purple with match styles and custom theme overrides", function()
  local e = entry({
    label = 'print("hello")',
    kind = 1,
    deprecated = true,
    labelDetails = { detail = "(value)", description = "AI" },
  })
  e.source_id = "copilot"
  local layout = render.prepare({ e }, opts, 120)
  local _, spans = render.row(layout, 1, e, { before = "pr", filetype = "lua" }, opts)
  local purple = span_for(spans, "CompletionToolsCopilot")
  eq(#layout.columns, #purple)
  for _, span in ipairs(purple) do
    eq(195, span[4])
  end
  assert(#span_for(spans, "CompletionToolsMatch") > 0)
  assert(#span_for(spans, "CompletionToolsDeprecated") > 0)
  e.source_id = "buffer"
  local _, buffer_spans = render.row(layout, 1, e, ctx, opts)
  eq(0, #span_for(buffer_spans, "CompletionToolsCopilot"))
  require("completion_tools.ui").highlights()
  eq(
    vim.api.nvim_get_hl(0, { name = "Statement", link = false }).fg,
    vim.api.nvim_get_hl(0, { name = "CompletionToolsCopilot", link = false }).fg
  )
  vim.api.nvim_set_hl(0, "CompletionToolsCopilot", { fg = "#aa66ff" })
  require("completion_tools.ui").highlights()
  eq(0xaa66ff, vim.api.nvim_get_hl(0, { name = "CompletionToolsCopilot" }).fg)
end)
test("command-line names are literal, keep matching and do not share syntax caches", function()
  for _, label in ipairs({ "write-local-help", "<Help>", "vim.lsp.buf.signature_help.Opts" }) do
    local e = { item = { label = label, kind = 18 }, source_id = "cmdline", start_col = 5 }
    -- Prime the same text/kind in an Insert-mode context first.
    highlight.get(label, "lua", opts.highlight)
    local context = { mode = "cmdline", completion_syntax = false, filetype = "lua", before = "help help" }
    local _, spans = paint(e, context, opts)
    assert(#span_for(spans, "CompletionToolsKindReference") > 0)
    assert(#span_for(spans, "CompletionToolsMatch") > 0)
    for _, span in ipairs(spans) do
      assert(span[3]:sub(1, 1) ~= "@", "help tag was interpreted as code")
    end
  end
end)
test("candidate syntax hints override defaults and keep match highlighting", function()
  local e = entry({ label = "foo-12", kind = 3 })
  local context = { filetype = "lua", before = "foo" }
  local _, spans = paint(e, context, opts)
  assert(#span_for(spans, "@number") > 0)
  e.item._syntax = false
  _, spans = paint(e, context, opts)
  assert(#span_for(spans, "CompletionToolsKindFunction") > 0)
  assert(#span_for(spans, "CompletionToolsMatch") > 0)
  eq(0, #span_for(spans, "@number"))

  e.item.kind, e.item._syntax = 1, nil
  _, spans = paint(e, context, opts)
  assert(#span_for(spans, "CompletionToolsKindText") > 0)
  eq(0, #span_for(spans, "@number"))
  e.item._syntax = "lua"
  _, spans = paint(e, context, opts)
  assert(#span_for(spans, "@number") > 0)
end)
test("per-field syntax keeps the label literal with inline and separate signatures", function()
  local e = entry({
    label = "函数-7",
    kind = 1,
    labelDetails = { detail = "(value: string)" },
    _syntax = { label = false, detail = "lua" },
  })
  local context = { before = "函", filetype = "tex" }
  for _, separate in ipairs({ false, true }) do
    local menu = config.validate({
      menu = {
        columns = separate and { { "label", "label_detail" } } or { { "label" } },
        label_details = not separate,
        highlight = { treesitter = false },
      },
    }).menu
    e.item._syntax = { label = false, detail = "lua" }
    local line, spans = paint(e, context, menu)
    local first = assert(line:find("string", 1, true)) - 1
    eq({ { first, first + #"string", "@type.builtin", 120 } }, span_for(spans, "@type.builtin"))
    eq(0, #span_for(spans, "@number"))
    assert(#span_for(spans, "CompletionToolsMatch") > 0)

    e.item._syntax = { label = "lua" }
    _, spans = paint(e, context, menu)
    eq(1, #span_for(spans, "@number"))
    eq(0, #span_for(spans, "@type.builtin"))
  end

  e.item._syntax = { label = false, detail = "lua" }
  local line, spans = paint(e, context, opts, 8)
  eq(0, #span_for(spans, "@number"))
  for _, span in ipairs(spans) do
    assert(span[2] <= #line)
    for column = 1, 2 do
      local byte = line:byte(span[column] + 1)
      assert(not byte or byte < 128 or byte >= 192, "Truncated highlight splits a UTF-8 character")
    end
  end
end)
test("inline detail syntax sees the full call and leaves custom spans scoped to the full column", function()
  local ok, loaded = pcall(vim.treesitter.language.add, "lua")
  if not ok or not loaded then
    return
  end
  local code = 'parse("x")'
  local calls = 0
  local menu = config.validate({
    menu = {
      columns = { { "label" } },
      highlight = {
        custom = function(_, _, text)
          calls = calls + 1
          return text == code and { { 0, #"parse", "Special" } } or {}
        end,
      },
    },
  }).menu
  local e = entry({ label = "parse", labelDetails = { detail = '("x")' }, _syntax = { label = false, detail = "lua" } })
  vim.treesitter.query.set(
    "lua",
    "highlights",
    "(function_call name: (identifier) @function (arguments (string) @string))"
  )
  local _, spans = paint(e, ctx, menu)
  vim.treesitter.query.set("lua", "highlights", nil)
  eq(0, #span_for(spans, "@function.lua"))
  eq(1, #span_for(spans, "@string.lua"))
  eq(1, #span_for(spans, "Special"))
  eq(1, calls)
end)
test("candidate and contextual languages override the buffer filetype", function()
  local e = entry({ label = 'foo(12, "x")', kind = 3 })
  local menu = config.validate({}).menu
  if pcall(vim.treesitter.language.add, "lua") then
    local _, spans = paint(e, { before = "", completion_syntax = "lua", filetype = "tex" }, menu)
    assert(#span_for(spans, "@string.lua") > 0, "Lua command completion inherited the buffer language")
    e.item._syntax = "lua"
    _, spans = paint(e, { before = "", completion_syntax = "vim", filetype = "tex" }, menu)
    assert(#span_for(spans, "@string.lua") > 0, "Source did not override the contextual language")
    e.item._syntax = nil
  end
  for _, language in ipairs({ "lua", "vim" }) do
    local _, spans = paint(e, { before = "", completion_syntax = language, filetype = "tex" }, opts)
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
  _, spans = paint(e, ctx, opts)
  eq(0, #span_for(spans, "Special"))
  local disabled = config.validate({ menu = { highlight = { enabled = false } } }).menu
  eq({}, highlight.get("name", "lua", disabled.highlight))
end)
test("native Tree-sitter is optional, bounded and cached", function()
  local original, calls = vim.treesitter.get_string_parser, 0
  vim.treesitter.get_string_parser = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, err = xpcall(function()
    local menu = config.validate({}).menu
    highlight.get("plain", "lua", menu.highlight)
    eq(0, calls)
    if pcall(vim.treesitter.language.add, "lua") then
      vim.treesitter.query.set("lua", "highlights", "(number) @number\n(string) @string")
      local code = 'foo(12, "中文")'
      local spans = highlight.get(code, "lua", menu.highlight)
      assert(#span_for(spans, "@number.lua") > 0, "native parser captures missing")
      assert(#span_for(spans, "@string.lua") > 0)
      eq(1, calls)
      highlight.get(code, "lua", menu.highlight)
      eq(1, calls)
      menu.highlight.max_bytes = 4
      highlight.get("bar(123)", "lua", menu.highlight)
      eq(1, calls)
      menu.highlight.max_bytes, menu.highlight.cache_size = 1024, 1
      highlight.clear()
      for _, value in ipairs({ code, "bar(1)", code }) do
        highlight.get(value, "lua", menu.highlight)
      end
      eq(4, calls)
      vim.treesitter.query.set("lua", "highlights", nil)
    else
      print("menu: optional Lua parser unavailable; lexical fallback covered")
    end
    assert(#span_for(highlight.get("missing(x: string)", ctx.filetype, menu.highlight), "@type.builtin") > 0)
  end, debug.traceback)
  vim.treesitter.get_string_parser = original
  assert(ok, err)
end)
print("menu: " .. count .. " passed")
vim.cmd("qa!")
