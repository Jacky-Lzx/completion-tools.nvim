-- Same process, same corpus, warm caches. This microbenchmark excludes providers
-- and UI; bench_input.lua measures actual input through menu rendering.
local blink_path = vim.env.BLINK_CMP_PATH or (vim.fn.stdpath("data") .. "/lazy/blink.cmp")
vim.opt.runtimepath:append(blink_path)
local ok, blink = pcall(require, "blink.cmp.fuzzy.rust")
assert(ok, "Set BLINK_CMP_PATH to a blink.cmp checkout with its compiled Rust matcher: " .. tostring(blink))
local matcher = require("completion_tools.matcher")
local queries = { "c", "co", "com", "comp", "cmp", "cBN" }
local function corpus(size)
  local items = {}
  local names = { "completeBufferName", "computeMemberValue", "compareResult", "configurationOption" }
  for i = 1, size do
    items[i] = { label = names[(i - 1) % #names + 1] .. string.format("%05d", i), kind = 6 }
  end
  return items
end
local function measure(run, rounds)
  for i = 1, 20 do
    run(queries[(i - 1) % #queries + 1])
  end
  collectgarbage("collect")
  local samples = {}
  for i = 1, rounds do
    local query = queries[(i - 1) % #queries + 1]
    local start = vim.uv.hrtime()
    run(query)
    samples[i] = (vim.uv.hrtime() - start) / 1e6
  end
  table.sort(samples)
  return { p50_ms = samples[math.ceil(#samples * 0.5)], p95_ms = samples[math.ceil(#samples * 0.95)] }
end
local results = {
  neovim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  benchmark = "warm matcher; six prefix/subsequence queries; 240 samples; 50 final candidates",
  blink_path = blink_path,
  cases = {},
}
for _, size in ipairs({ 1000, 10000, 20000 }) do
  local items = corpus(size)
  local groups =
    { { items = items, source_id = "bench", score_offset = 0, priority = 1, start_col = 0, context = {} } }
  blink.set_provider_items("bench", items)
  local opts = {
    max_typos = 0,
    match_suffix = false,
    use_frecency = false,
    use_proximity = false,
    nearby_words = {},
    snippet_score_offset = 0,
    sorts = { "score", "sort_text" },
  }
  local ours = measure(function(query)
    matcher.filter(groups, { before = query, prefix = query }, 50)
  end, 240)
  local theirs = measure(function(query)
    blink.fuzzy(query, #query, { "bench" }, opts)
  end, 240)
  results.cases[#results.cases + 1] = { items = size, completion_tools = ours, blink_rust = theirs }
end
local encoded = vim.json.encode(results)
if vim.env.BENCH_OUTPUT then
  vim.fn.writefile({ encoded }, vim.env.BENCH_OUTPUT)
end
print(encoded)
