local config = require("completion_tools.config")
local factory = require("completion_tools.ranking")
local matcher = require("completion_tools.matcher")
local path = vim.fn.tempname() .. "/history.json"
local opts =
  config.validate({ ranking = { history = { enabled = true, path = path, max_entries = 2 } } }).ranking
local ctx = { mode = "insert", filetype = "lua", bufnr = 0, row = 0 }
local entry = { item = { label = "alpine" }, source_id = "test" }
local rank = factory.new(opts)
assert(rank.scorer(ctx)(entry.item, "test") == 0)
rank.record(entry, ctx)
assert(rank.scorer(ctx)(entry.item, "test") > 0)
assert(rank.scorer(vim.tbl_extend("force", ctx, { filetype = "tex" }))(entry.item, "test") == 0)
assert(rank.scorer(ctx)(entry.item, "other") == 0)
assert(rank.scorer({ mode = "cmdline" }) == nil)
rank.dispose()
rank = factory.new(opts)
assert(rank.scorer(ctx)(entry.item, "test") > 0, "history did not persist")
for _, label in ipairs({ "alpha", "alphabet" }) do
  rank.record({ item = { label = label }, source_id = "test" }, ctx)
end
assert(rank.scorer(ctx)(entry.item, "test") == 0, "history did not evict oldest item")
rank.dispose()
local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
assert(#data.records == 2)
vim.fn.writefile({ '{"version":1,"records":[1,{},false]}' }, path)
rank = factory.new(opts)
assert(rank.scorer(ctx)(entry.item, "test") == 0)
rank.dispose()
vim.fn.writefile({ "broken json" }, path)
rank = factory.new(opts)
assert(rank.scorer(ctx)(entry.item, "test") == 0)
rank.dispose()
local disabled = factory.new(config.defaults.ranking)
disabled.record(entry, ctx)
assert(disabled.scorer(ctx) == nil)
disabled.dispose()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpine", "", "alpha" })
rank = factory.new(config.validate({ ranking = { proximity = { enabled = true, lines = 1 } } }).ranking)
assert(rank.scorer(ctx)({ label = "alpine" }, "test") > 0)
assert(rank.scorer(ctx)({ label = "alpha" }, "test") == 0)
rank.dispose()
local groups = {
  {
    items = { { label = "print" }, { label = "pritnLiteral" } },
    source_id = "test",
    start_col = 0,
    score_offset = 0,
    priority = 1,
  },
}
local query = { before = "pritn", prefix = "pritn" }
assert(#matcher.filter(groups, query, 10) == 1)
local matches = matcher.filter(groups, query, 10, { max_typos = 1 })
assert(#matches == 2 and matches[1].item.label == "pritnLiteral", "typos outranked a literal prefix")
for _, prefix in ipairs({ "pront", "priint", "prnt" }) do
  assert(
    #matcher.filter(
        { vim.tbl_extend("force", groups[1], { items = { { label = "print" } } }) },
        { before = prefix, prefix = prefix },
        10,
        { max_typos = 1 }
      ) == 1,
    prefix
  )
end
for _, prefix in ipairs({ "pr", "pxxnt", "中文" }) do
  assert(
    #matcher.filter(
        { vim.tbl_extend("force", groups[1], { items = { { label = "print" } } }) },
        { before = prefix, prefix = prefix },
        10,
        { max_typos = 1 }
      ) == (prefix == "pr" and 1 or 0)
  )
end
vim.fn.delete(vim.fs.dirname(path), "rf")
print("ranking: persistent bounded history, scope, corrupt data, proximity and opt-in typos passed")

-- Cross-provider numeric sortText must not win equal-score source/client ties.
do
  local human = { label = "Peng18", detail = "human", _client_name = "preferred", _client_id = 20 }
  local tex =
    { label = "Peng18", sortText = "00Peng18", detail = "other", _client_name = "other", _client_id = 10 }
  local snippets = {}
  for i = 1, 70 do
    snippets[i] = { label = string.format("snippet%02d", i), sortText = string.format("%010d", i) }
  end
  local lsp = {
    items = { tex, human },
    source_id = "lsp",
    priority = 1,
    score_offset = 60,
    start_col = 6,
    client_order = { "preferred", "other" },
  }
  local snippet_group =
    { items = snippets, source_id = "snippets", priority = 2, score_offset = 60, start_col = 6 }
  local empty = { before = "\\cite{", prefix = "" }
  for _, items in ipairs({ { tex, human }, { human, tex } }) do
    lsp.items = items
    for _, groups in ipairs({ { lsp, snippet_group }, { snippet_group, lsp } }) do
      for _, limit in ipairs({ 1, 2, 3, 50, 100 }) do
        local result = matcher.filter(groups, empty, limit)
        assert(#result == math.min(limit, 72))
        assert(result[1].item == human, "preferred client lost an empty-query top-K tie")
        if limit > 1 then
          assert(result[2].item == tex)
        end
        for i = 3, #result do
          assert(result[i].item == snippets[i - 2])
        end
      end
    end
  end
  -- Unlisted clients use a stable namespace, independent of numeric sortText.
  lsp.client_order = nil
  local result = matcher.filter({ lsp }, empty, 10)
  assert(result[1].item == tex and result[2].item == human)
  tex._client_name, human._client_name = "zeta", "alpha"
  result = matcher.filter({ lsp }, empty, 10)
  assert(result[1].item == human, "unlisted client order depended on sortText")
  lsp.client_order = { "alpha" }
  lsp.start_col = 0
  human.label, tex.label = "Peng18", "Pe"
  result = matcher.filter({ lsp }, { before = "Pe", prefix = "Pe" }, 10)
  assert(result[1].item == tex, "client preference outranked a better match")
end

-- Compare bounded heaps with an independent full tuple sort over mixed clients.
do
  math.randomseed(71)
  local groups, expected = {}, {}
  for source = 1, 3 do
    local g = {
      items = {},
      source_id = "source" .. source,
      priority = source,
      score_offset = 0,
      start_col = 0,
      client_order = { "preferred" },
    }
    for i = 1, 90 do
      local name = ({ "preferred", "alpha", "zeta" })[i % 3 + 1]
      local item = {
        label = string.format("item%03d", i),
        sortText = string.format("%03d", 100 - i),
        _client_name = name,
        _client_id = i % 3 + 1,
        detail = g.source_id,
      }
      g.items[#g.items + 1] = item
      expected[#expected + 1] = { item = item, source = source, client = name == "preferred" and 1 or 2 }
    end
    groups[#groups + 1] = g
  end
  table.sort(expected, function(a, b)
    if a.source ~= b.source then
      return a.source < b.source
    end
    if a.client ~= b.client then
      return a.client < b.client
    end
    if a.item._client_name ~= b.item._client_name then
      return a.item._client_name < b.item._client_name
    end
    return a.item.sortText < b.item.sortText
  end)
  for attempt = 1, 5 do
    for _, g in ipairs(groups) do
      for i = #g.items, 2, -1 do
        local j = math.random(i)
        g.items[i], g.items[j] = g.items[j], g.items[i]
      end
    end
    groups[1], groups[3] = groups[3], groups[1]
    for _, limit in ipairs({ 1, 7, 50, 270 }) do
      local result = matcher.filter(groups, { before = "", prefix = "" }, limit)
      for i, entry in ipairs(result) do
        assert(entry.item == expected[i].item, "heap/full-order mismatch")
      end
    end
  end
end
for _, order in ipairs({ { "duplicate", "duplicate" }, { "" }, { 1 }, { bad = "name" }, "name" }) do
  assert(not pcall(config.validate, { providers = { lsp = { client_order = order } } }))
end
assert(not pcall(config.validate, { providers = { buffer = { client_order = {} } } }))
assert(pcall(config.validate, { providers = { lsp = { client_order = {} } } }))
print("ranking: source/client scope, top-K, response permutations and client_order validation passed")
