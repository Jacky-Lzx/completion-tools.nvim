local path = assert(vim.env.DICTIONARY_FILE, "Set DICTIONARY_FILE to a real word list")
local opts = require("completion_tools.config").validate({ dictionary = { files = { path } } }).dictionary
local dictionary = require("completion_tools.sources.dictionary").new(opts)
local queries, seen = {}, {}
local handle = assert(io.open(path, "rb"))
for line in handle:lines() do
  local word = line:gsub("\r$", "")
  if #word >= 6 then
    local query = word:sub(1, 5)
    if not seen[query] then
      seen[query], queries[#queries + 1] = true, query
      if #queries == 40 then
        break
      end
    end
  end
end
handle:close()
assert(#queries > 0)
local maximum_gap, last, ticks = 0, vim.uv.hrtime(), 0
local timer = vim.uv.new_timer()
timer:start(
  2,
  2,
  vim.schedule_wrap(function()
    local now = vim.uv.hrtime()
    maximum_gap, last, ticks = math.max(maximum_gap, (now - last) / 1e6), now, ticks + 1
  end)
)
local function query(value)
  local done, items
  local start = vim.uv.hrtime()
  dictionary.complete({ prefix = value }, function(result)
    done, items = true, result.items
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 1),
    "dictionary timeout"
  )
  assert(#items > 0 and #items <= opts.max_items)
  return (vim.uv.hrtime() - start) / 1e6
end
local ok, result = xpcall(function()
  local cold = query(queries[1])
  local samples = {}
  for _, value in ipairs(queries) do
    samples[#samples + 1] = query(value)
  end
  table.sort(samples)
  return {
    benchmark = "background dictionary; real file; uncached fuzzy queries; main-loop heartbeat",
    neovim = tostring(vim.version()),
    bytes = vim.uv.fs_stat(path).size,
    samples = #samples,
    first_result_ms = cold,
    query_p95_ms = samples[math.ceil(#samples * 0.95)],
    main_loop_max_gap_ms = maximum_gap,
    heartbeat_ticks = ticks,
  }
end, debug.traceback)
timer:stop()
timer:close()
dictionary.dispose()
assert(ok, result)
print(vim.json.encode(result))
if vim.env.BENCH_OUTPUT then
  vim.fn.writefile({ vim.json.encode(result) }, vim.env.BENCH_OUTPUT)
end
vim.cmd("qa!")
