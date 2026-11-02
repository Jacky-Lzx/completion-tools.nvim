-- JSON-lines worker; never loads the user's init or the Blink ecosystem.
local root = debug.getinfo(1, "S").source:sub(2):gsub("completion_tools/worker_main.lua$", "")
package.path = root .. "?.lua;" .. package.path
local matcher = require("completion_tools.matcher")
local indexes, clock = {}, 0

local function dictionary(request)
  local signature, errors = {}, {}
  for _, file in ipairs(request.files) do
    local stat = vim.uv.fs_stat(file)
    signature[#signature + 1] = { file, stat and stat.size, stat and stat.mtime, stat and stat.ino }
  end
  local key = vim.json.encode({ request.files, request.max_bytes, request.max_words, request.max_word_bytes })
  local fingerprint = vim.json.encode(signature)
  local index = indexes[key]
  if not index or index.signature ~= fingerprint then
    indexes[key] = nil
    index = { words = {}, prefixes = {}, cache = {}, order = {}, slot = 1, signature = fingerprint }
    local seen, bytes = {}, 0
    for _, file in ipairs(request.files) do
      local stat = vim.uv.fs_stat(file)
      if stat and stat.size > request.max_bytes - bytes then
        index.truncated = true
        break
      end
      local handle, err = io.open(file, "rb")
      if not handle then
        errors[#errors + 1] = file .. ": " .. tostring(err)
      else
        for line in handle:lines() do
          bytes = bytes + #line + 1
          if bytes > request.max_bytes or #index.words >= request.max_words then
            index.truncated = true
            break
          end
          local word = line:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$")
          if word ~= "" and #word <= request.max_word_bytes and not word:find("%z") and not seen[word] then
            seen[word] = true
            index.words[#index.words + 1] = word
            local prefix = word:lower():sub(1, 3)
            index.prefixes[prefix] = index.prefixes[prefix] or {}
            table.insert(index.prefixes[prefix], word)
          end
        end
        handle:close()
      end
      if index.truncated then
        break
      end
    end
    index.errors = errors
    local oldest, count
    count = 0
    for k, value in pairs(indexes) do
      count = count + 1
      if not oldest or value.used < indexes[oldest].used then
        oldest = k
      end
    end
    if count >= 4 then
      indexes[oldest] = nil
    end
    indexes[key] = index
  end
  clock = clock + 1
  index.used = clock
  local query = request.query:lower()
  local cache_key =
    vim.json.encode({ request.query, request.matching, request.max_items, request.capitalize })
  local items = index.cache[cache_key]
  if not items then
    local candidates = index.words
    if request.matching == "prefix" and #query >= 3 then
      candidates = index.prefixes[query:sub(1, 3)] or {}
    end
    local top = {}
    for _, word in ipairs(candidates or {}) do
      local score
      if request.matching ~= "prefix" or word:lower():sub(1, #query) == query then
        score = matcher.score(word, query)
      end
      if score then
        local last = top[#top]
        if #top < request.max_items or score > last.score or (score == last.score and word < last.word) then
          local at = #top + 1
          while
            at > 1 and (score > top[at - 1].score or (score == top[at - 1].score and word < top[at - 1].word))
          do
            at = at - 1
          end
          table.insert(top, at, { word = word, score = score })
          if #top > request.max_items then
            top[#top] = nil
          end
        end
      end
    end
    items = {}
    for _, candidate in ipairs(top) do
      local word = candidate.word
      if request.capitalize and not word:find("%u") then
        if request.query:match("^%u%u") then
          word = word:upper()
        elseif request.query:match("^%u") then
          word = word:gsub("^%l", string.upper)
        end
      end
      items[#items + 1] = { label = word, kind = 1 }
    end
    local old = index.order[index.slot]
    if old then
      index.cache[old] = nil
    end
    index.order[index.slot], index.cache[cache_key] = cache_key, items
    index.slot = index.slot % 64 + 1
  end
  return { items = items, errors = index.errors, truncated = index.truncated }
end

local spell_versions = {}
local function spell(request)
  vim.fn.chdir(request.cwd)
  vim.opt.runtimepath = request.runtimepath
  vim.bo.spelllang, vim.bo.spellfile = request.spelllang, request.spellfile
  vim.bo.spellcapcheck, vim.bo.spelloptions = request.spellcapcheck, request.spelloptions
  vim.o.spellsuggest, vim.wo.spell = request.spellsuggest, true
  local paths, version = vim.opt_local.spellfile:get(), {}
  for lang in request.spelllang:gmatch("[^,]+") do
    lang = lang:gsub("_[%a]+$", "")
    for _, root_path in ipairs(request.runtimepath) do
      paths[#paths + 1] = root_path .. "/spell/" .. lang .. ".utf-8.add"
      paths[#paths + 1] = root_path .. "/spell/" .. lang .. ".utf-8"
    end
  end
  for _, path in ipairs(paths) do
    local stat = vim.uv.fs_stat(vim.fn.expand(path) .. ".spl")
    version[#version + 1] = { path, stat and stat.size, stat and stat.mtime }
  end
  local version_key = vim.json.encode({ request.cwd, paths })
  local stamp = vim.json.encode(version)
  if not spell_versions[version_key] and vim.tbl_count(spell_versions) >= 32 then
    return { restart = true }
  end
  if spell_versions[version_key] and spell_versions[version_key] ~= stamp then
    return { restart = true }
  end
  spell_versions[version_key] = stamp
  local correct = #vim.spell.check(request.query) == 0
  local suggestions = {}
  if not correct or request.suggest_when_correct then
    suggestions = vim.fn.spellsuggest(request.query, request.max_items)
  end
  if request.sort == "match" then
    local query = request.query:lower()
    table.sort(suggestions, function(a, b)
      local sa, sb = matcher.score(a, query) or -math.huge, matcher.score(b, query) or -math.huge
      return sa == sb and a < b or sa > sb
    end)
  end
  local items, seen = {}, {}
  local function add(word, preselect)
    if not seen[word] then
      seen[word] = true
      items[#items + 1] = {
        label = word,
        kind = 1,
        filterText = request.query,
        sortText = string.format("%06d", #items + 1),
        preselect = preselect,
      }
    end
  end
  if correct and request.preselect_current_word then
    add(request.query, true)
  end
  for _, word in ipairs(suggestions) do
    if #items >= request.max_items then
      break
    end
    add(word, false)
  end
  return { items = items }
end

for line in io.lines() do
  local request
  local ok, result = xpcall(function()
    request = vim.json.decode(line)
    return request.kind == "dictionary" and dictionary(request) or spell(request)
  end, debug.traceback)
  if not ok then
    result = { items = {}, error = tostring(result) }
  end
  result.id = request and request.id
  io.stdout:write(vim.json.encode(result), "\n")
  io.stdout:flush()
end
vim.cmd("qa!")
