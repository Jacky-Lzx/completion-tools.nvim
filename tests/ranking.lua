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
