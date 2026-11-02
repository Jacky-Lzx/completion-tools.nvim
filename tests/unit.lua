local count = 0
local function test(name, run)
  local ok, err = xpcall(run, debug.traceback)
  if not ok then
    error(name .. ": " .. err)
  end
  count = count + 1
end
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local matcher = require("completion_tools.matcher")
local defaults = require("completion_tools.config").defaults
local function group(items, id, offset, priority)
  return {
    items = items,
    source_id = id or "test",
    score_offset = offset or 0,
    priority = priority or 1,
    start_col = 0,
    context = {},
  }
end
test("prefix, camel case, subsequence and UTF-8", function()
  assert(matcher.score("getBufferName", "gbn"))
  assert(matcher.score("getBufferName", "get") > matcher.score("targetGetter", "get"))
  assert(matcher.score("中文名字", "中文"))
  assert(not matcher.score("apple", "xyz"))
  eq(0, matcher.score("anything", ""))
end)
test("top-k agrees with full ranking and deduplicates sources", function()
  math.randomseed(42)
  local items = {}
  for i = 1, 1500 do
    items[i] = {
      label = (i % 2 == 0 and "completion" or "compiler") .. math.random(100000),
      sortText = string.format("%06d", i),
    }
  end
  -- Always exercise duplicate labels, regardless of the platform's RNG stream.
  items[1].label, items[3].label = "compiler1", "compiler1"
  items[2].label, items[4].label = "completion1", "completion1"
  local ranked = {}
  for i, item in ipairs(items) do
    ranked[i] = { item = item, sort = item.sortText, score = matcher.score(item.label, "cmp") }
  end
  table.sort(ranked, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.sort < b.sort
  end)
  -- This fixture has identical insertion text/kind for each repeated label.
  -- The first full-sort occurrence is the winner of that completion identity.
  local unique, seen = {}, {}
  for _, candidate in ipairs(ranked) do
    local label = candidate.item.label
    if not seen[label] then
      seen[label] = true
      unique[#unique + 1] = candidate
    end
  end
  local result = matcher.filter({ group(items) }, { before = "cmp", prefix = "cmp" }, 50)
  eq(50, #result)
  for i = 1, 50 do
    eq(unique[i].item, result[i].item)
  end
  local duplicate = { label = "completion", kind = 1 }
  local result2 = matcher.filter(
    { group({ duplicate }, "buffer"), group({ duplicate }, "lsp", 40, 2) },
    { before = "cmp", prefix = "cmp" },
    10
  )
  eq(1, #result2)
  eq("lsp", result2[1].source_id)
end)
test("buffer source excludes the typed word only", function()
  local result = matcher.filter(
    { group({ { label = "apple" } }, "buffer"), group({ { label = "apple" } }, "lsp") },
    { before = "apple", prefix = "apple" },
    5
  )
  eq(1, #result)
  eq("lsp", result[1].source_id)
end)
test("configuration preserves empty source and keymap lists", function()
  local cfg = require("completion_tools.config").validate({ sources = {}, keymap = {} })
  eq({}, cfg.sources)
  eq({}, cfg.keymap)
  assert(not pcall(require("completion_tools.config").validate, { max_items = 0 }))
  assert(not pcall(require("completion_tools.config").validate, { buffer = { batch_lines = 0 } }))
end)
test("capability registration is pure and preserves extras", function()
  local cmp = require("completion_tools")
  local capabilities = cmp.get_lsp_capabilities({ experimental = { custom = true } })
  assert(capabilities.textDocument.completion.completionItem.snippetSupport)
  assert(capabilities.experimental.custom)
  assert(not pcall(vim.api.nvim_get_autocmds, { group = "CompletionTools" }))
end)
test("incremental buffer indexing, insert/delete lines, cap and detach", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha beta gamma", "delta delta", "epsilon" })
  local ready = 0
  local source = require("completion_tools.sources.buffer").new(
    vim.tbl_extend("force", defaults.buffer, { batch_lines = 2 }),
    function()
      ready = ready + 1
    end
  )
  source.warmup(buf)
  assert(vim.wait(500, function()
    return ready > 0
  end))
  local function labels()
    local result
    source.complete({ bufnr = buf }, function(response)
      result = vim.tbl_map(function(item)
        return item.label
      end, response.items)
    end)
    table.sort(result)
    return result
  end
  eq({ "alpha", "beta", "delta", "epsilon", "gamma" }, labels())
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "zeta" })
  eq({ "delta", "epsilon", "zeta" }, labels())
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "inserted", "words" })
  eq({ "delta", "epsilon", "inserted", "words", "zeta" }, labels())
  vim.api.nvim_buf_set_lines(buf, 1, 3, false, {})
  eq({ "delta", "epsilon", "zeta" }, labels())
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "different" })
  eq({ "different", "epsilon", "zeta" }, labels())
  source.dispose()
  vim.api.nvim_buf_delete(buf, { force = true })
  local small = require("completion_tools.sources.buffer").new(
    vim.tbl_extend("force", defaults.buffer, { max_words = 2 }),
    function() end
  )
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "one two three four five" })
  small.warmup(b)
  vim.wait(30)
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "replacement" })
  small.complete({ bufnr = b }, function(response)
    eq(1, #response.items)
    eq("replacement", response.items[1].label)
  end)
  small.dispose()
  vim.api.nvim_buf_delete(b, { force = true })
end)
test("oversized buffers are excluded", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "oversized" })
  local source = require("completion_tools.sources.buffer").new(
    vim.tbl_extend("force", defaults.buffer, { max_bytes = 2 }),
    function() end
  )
  source.complete({ bufnr = buf }, function(response)
    eq(0, #response.items)
  end)
  source.dispose()
  vim.api.nvim_buf_delete(buf, { force = true })
end)
test("continuous typing does not starve the initial buffer scan", function()
  local buf = vim.api.nvim_create_buf(true, false)
  local lines = {}
  for i = 1, 200 do
    lines[i] = "identifier" .. i
  end
  lines[201] = ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ready, edits, active, completed_at = false, 0, true, nil
  local source = require("completion_tools.sources.buffer").new(
    vim.tbl_extend("force", defaults.buffer, { batch_lines = 1 }),
    function()
      ready = true
      completed_at = edits
    end
  )
  source.warmup(buf)
  source.complete({ bufnr = buf }, function(response)
    eq(0, #response.items)
  end)
  local function type_more()
    if not active then
      return
    end
    edits = edits + 1
    vim.api.nvim_buf_set_lines(buf, 200, 201, false, { "typed" .. edits })
    if edits < 400 then
      vim.schedule(type_more)
    end
  end
  vim.schedule(type_more)
  assert(vim.wait(1000, function()
    return ready
  end))
  assert(completed_at < 400, "index only completed after typing stopped")
  source.complete({ bufnr = buf }, function(response)
    local found = false
    for _, item in ipairs(response.items) do
      if item.label == "identifier200" then
        found = true
      end
    end
    assert(found)
  end)
  active = false
  source.dispose()
  vim.api.nvim_buf_delete(buf, { force = true })
end)
test("bounded buffer cache reactivates evicted buffers without stale words", function()
  local source = require("completion_tools.sources.buffer").new(
    vim.tbl_extend("force", defaults.buffer, { max_buffers = 1 }),
    function() end
  )
  local buffers = {}
  for _, word in ipairs({ "firstBuffer", "secondBuffer" }) do
    local buf = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1] = buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { word })
    source.warmup(buf)
    vim.wait(20)
  end
  vim.api.nvim_buf_set_lines(buffers[1], 0, -1, false, { "freshWord" })
  source.complete({ bufnr = buffers[1] }, function(response)
    eq(0, #response.items)
  end)
  vim.wait(20)
  source.complete({ bufnr = buffers[1] }, function(response)
    eq("freshWord", response.items[1].label)
  end)
  source.dispose()
  for _, buf in ipairs(buffers) do
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end)
test("UTF-16 cached edit ranges rebase typed suffix correctly", function()
  local edits = require("completion_tools.edits")
  local old = { before = "😀fo", row = 0 }
  local ctx = { before = "😀foo", row = 0 }
  eq(
    { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 5 } },
    edits.rebase(
      { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 4 } },
      old,
      ctx,
      "utf-16"
    )
  )
  eq(
    { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 5 } },
    edits.rebase(
      { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 4 } },
      old,
      ctx,
      "utf-16"
    )
  )
end)
test("setup and disposal restore prior mappings without clobbering later mappings", function()
  local cmp = require("completion_tools")
  vim.keymap.set("i", "<Tab>", "old", { expr = false })
  cmp.setup({ sources = {}, auto_show = false })
  cmp.setup({ sources = {}, auto_show = false })
  cmp.dispose()
  eq("old", vim.fn.maparg("<Tab>", "i"))
  cmp.setup({ sources = {}, auto_show = false })
  vim.keymap.set("i", "<Tab>", "new")
  cmp.dispose()
  eq("new", vim.fn.maparg("<Tab>", "i"))
  vim.keymap.del("i", "<Tab>")
end)
test("global mapping lifecycle preserves an existing buffer-local mapping", function()
  local cmp = require("completion-tools")
  vim.keymap.set("i", "<Tab>", "global-before")
  vim.keymap.set("i", "<Tab>", "local-before", { buffer = 0 })
  cmp.setup({ sources = {}, auto_show = false })
  eq("local-before", vim.fn.maparg("<Tab>", "i"))
  cmp.dispose()
  eq("local-before", vim.fn.maparg("<Tab>", "i"))
  vim.keymap.del("i", "<Tab>", { buffer = 0 })
  eq("global-before", vim.fn.maparg("<Tab>", "i"))
  vim.keymap.del("i", "<Tab>")
end)
test("async path completion handles Unicode, hidden files and cancellation", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.mkdir(dir .. "/folder", "p")
  vim.fn.writefile({}, dir .. "/中文.lua")
  vim.fn.writefile({}, dir .. "/.hidden")
  local source = require("completion_tools.sources.path").new(vim.tbl_extend("force", defaults.path, {
    get_cwd = function()
      return dir
    end,
  }))
  local received
  source.complete({ before = "./", col = 2, bufnr = 0 }, function(response)
    received = response
  end)
  assert(vim.wait(1000, function()
    return received ~= nil
  end))
  eq(2, #received.items)
  eq(2, received.start_col)
  source.complete({ before = "./.", col = 3, bufnr = 0 }, function(response)
    eq(3, #response.items)
  end)
  local cancelled = false
  local cancel = source.complete(
    { before = "/unlikely-nonexistent-directory/", col = 32, bufnr = 0 },
    function()
      cancelled = true
    end
  )
  cancel()
  vim.wait(30)
  assert(not cancelled)
  source.dispose()
  vim.fn.delete(dir, "rf")
end)
test("LSP empty partial responses retain pending state across clients", function()
  local original = vim.lsp.get_clients
  local callbacks, published = {}, {}
  local ok, err = xpcall(function()
    local clients = {}
    for i = 1, 2 do
      clients[i] = { id = i, offset_encoding = "utf-8", server_capabilities = {} }
      clients[i].request = function(_, _, _, callback)
        callbacks[i] = callback
        return true, i
      end
    end
    vim.lsp.get_clients = function()
      return clients
    end
    require("completion_tools.sources.lsp").new().complete({
      bufnr = vim.api.nvim_get_current_buf(),
      winid = vim.api.nvim_get_current_win(),
      before = "a",
    }, function(result)
      published[#published + 1] = result
    end)
    callbacks[1](nil, {})
    assert(published[1].pending and not published[1].reusable)
    callbacks[2](nil, { { label = "alpha" } })
    assert(not published[2].pending and published[2].reusable)
    eq("alpha", published[2].items[1].label)
  end, debug.traceback)
  vim.lsp.get_clients = original
  assert(ok, err)
end)
print(string.format("unit: %d passed", count))
