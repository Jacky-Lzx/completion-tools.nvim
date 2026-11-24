local M = {}
local identity = require("completion_tools.identity")
local top_k = require("completion_tools.top_k")
local byte, find, lower = string.byte, string.find, string.lower

--- A matched candidate together with its source and request metadata.
---@class completion_tools.Entry
---@field item lsp.CompletionItem Candidate supplied by the source.
---@field key string Identity used for deduplication and selection.
---@field source_id string Registered source ID.
---@field source_name? string Source name displayed in the menu.
---@field context table Request context used to apply or resolve the candidate.
---@field start_col integer Zero-based byte column where the candidate starts.
---@field priority integer Source order used to break ranking ties.
---@field score_offset number Score adjustment configured for the source.
---@field stale? boolean Whether the entry belongs to a retained request.
---@field resolved? lsp.CompletionItem Candidate returned by the source's resolve callback.

-- One ASCII typo in a prefix (including a transposition). Restrict the work to
-- short queries and run only after literal subsequence matching has failed.
local function typo_score(text, query)
  if #query < 4 or #query > 32 or query:find("[^%w_]") or text:find("[\128-\255]") then
    return
  end
  text = lower(text)
  for length = math.max(1, #query - 1), math.min(#text, #query + 1) do
    local prefix, i = text:sub(1, length), 1
    while i <= math.min(#query, length) and query:sub(i, i) == prefix:sub(i, i) do
      i = i + 1
    end
    local a, b = query:sub(i), prefix:sub(i)
    local matched = (
      #query == length
      and (
        a:sub(2) == b:sub(2)
        or (#a >= 2 and a:sub(1, 1) == b:sub(2, 2) and a:sub(2, 2) == b:sub(1, 1) and a:sub(3) == b:sub(3))
      )
    )
      or (#query == length + 1 and a:sub(2) == b)
      or (length == #query + 1 and a == b:sub(2))
    if matched then
      return -100 - math.abs(#text - #query)
    end
  end
end

-- ASCII scoring is intentional; non-ASCII bytes still match literally without
-- splitting the inserted text. Unicode case folding is not advertised.
function M.score(text, query)
  if query == "" then
    return 0
  end
  local folded = lower(text)
  if folded:sub(1, #query) == query then
    return 1000 + #query * 16 - math.min(#text - #query, 100)
  end
  local pos, previous, score = 1, 0, 0
  for i = 1, #query do
    local at = find(folded, query:sub(i, i), pos, true)
    if not at then
      return
    end
    local prev, char = byte(text, at - 1), byte(text, at)
    local boundary = at == 1
      or prev == 95
      or prev == 45
      or prev == 46
      or prev == 47
      or (prev and prev >= 97 and prev <= 122 and char >= 65 and char <= 90)
    score = score + 16 + (boundary and 24 or 0) + (at == previous + 1 and 12 or 0) - math.min(at - previous - 1, 20)
    previous, pos = at, at + 1
  end

  return score - math.min(#text - #query, 100)
end

local function better(a, b)
  if a.score ~= b.score then
    return a.score > b.score
  end

  -- sortText is local to a provider/client, not a cross-source priority.
  if a.group.priority ~= b.group.priority then
    return a.group.priority < b.group.priority
  end

  if a.group.source_id ~= b.group.source_id then
    return a.group.source_id < b.group.source_id
  end

  if a.client_priority ~= b.client_priority then
    return a.client_priority < b.client_priority
  end

  if a.client_name ~= b.client_name then
    return a.client_name < b.client_name
  end

  if a.client_id ~= b.client_id then
    return a.client_id < b.client_id
  end

  local ai, bi = a.item, b.item
  local as, bs = ai.sortText or ai.label, bi.sortText or bi.label

  if as ~= bs then
    return as < bs
  end

  if ai.label ~= bi.label then
    return ai.label < bi.label
  end

  return a.index < b.index
end

function M.has_match(group, ctx, opts)
  local excluded_label = group.excluded_label and group.excluded_label(ctx)
  for _, item in ipairs(group.items) do
    if type(item.label) == "string" and item.label ~= excluded_label then
      local start_col = group.start_cols and group.start_cols[item] or group.start_col
      local query = lower(ctx.before:sub(start_col + 1))
      local text = item.filterText or item.label

      if M.score(text, query) or (opts and opts.max_typos == 1 and typo_score(text, query)) then
        return true
      end
    end
  end

  return false
end

-- Keep only the best K in a min-heap, instead of sorting every match.
---@return completion_tools.Entry[]
function M.filter(groups, ctx, limit, opts)
  local top = top_k.new(limit, better)
  local cutoff
  local query_cache, index = {}, 0

  for _, group in ipairs(groups) do
    local excluded_label = group.excluded_label and group.excluded_label(ctx)
    local client_priorities = {}
    for priority, name in ipairs(group.client_order or {}) do
      client_priorities[name] = priority
    end

    local query = query_cache[group.start_col]
    if not query then
      query = lower(ctx.before:sub(group.start_col + 1))
      query_cache[group.start_col] = query
    end

    for _, item in ipairs(group.items) do
      index = index + 1
      local start_col = group.start_cols and group.start_cols[item] or group.start_col
      local item_query = query
      if start_col ~= group.start_col then
        item_query = query_cache[start_col]
        if not item_query then
          item_query = lower(ctx.before:sub(start_col + 1))
          query_cache[start_col] = item_query
        end
      end

      local score = type(item.label) == "string" and M.score(item.filterText or item.label, item_query)
      if score == nil and type(item.label) == "string" and opts and opts.max_typos == 1 then
        score = typo_score(item.filterText or item.label, item_query)
      end

      if score then
        score = score + group.score_offset + (item.preselect and 8 or 0)
        if opts and opts.bonus then
          score = score + opts.bonus(item, group.source_id)
        end

        if item.label ~= excluded_label and (not cutoff or score >= cutoff.score) then
          local candidate = {
            item = item,
            group = group,
            score = score,
            index = index,
            client_priority = client_priorities[item._client_name] or math.huge,
            client_name = item._client_name or "",
            client_id = item._client_id or 0,
          }

          -- Avoid computing semantic identities for equal-score candidates
          -- already below the top-K cutoff (notably empty-query word lists).
          if not cutoff or better(candidate, cutoff) then
            candidate.key = identity.key(item)
            top.offer(candidate.key, candidate)
            cutoff = top.cutoff()
          end
        end
      end
    end
  end

  local result = {}
  for i, candidate in ipairs(top.sorted()) do
    local group = candidate.group
    result[i] = {
      key = candidate.key,
      item = candidate.item,
      source_id = group.source_id,
      context = group.context,
      start_col = group.start_col,
      priority = group.priority,
      score_offset = group.score_offset,
    }
    result[i].start_col = group.start_cols and group.start_cols[candidate.item] or group.start_col
  end

  return result
end

local function insert_blocks(items, blocks)
  local next_at = 1
  for _, block in ipairs(blocks) do
    if #block.items > 0 then
      local at = math.min(math.max(block.group.insert_at, next_at), #items + 1)
      for i, entry in ipairs(block.items) do
        table.insert(items, at + i - 1, entry)
      end

      next_at = at + #block.items
    end
  end
end

-- Fixed provider blocks are placed after matching, before the global cutoff.
-- Rank each block separately so low-scoring AI suggestions survive a full menu.
local function select_with_insert_at(groups, ctx, limit, opts)
  local ordinary, blocks = {}, {}
  for _, group in ipairs(groups) do
    if group.insert_at then
      blocks[#blocks + 1] = { group = group, items = M.filter({ group }, ctx, limit, opts) }
    else
      ordinary[#ordinary + 1] = group
    end
  end

  table.sort(blocks, function(a, b)
    if a.group.insert_at ~= b.group.insert_at then
      return a.group.insert_at < b.group.insert_at
    end

    if a.group.priority ~= b.group.priority then
      return a.group.priority < b.group.priority
    end

    return a.group.source_id < b.group.source_id
  end)

  local extra = 0
  for _, block in ipairs(blocks) do
    extra = extra + #block.items
  end

  -- Oversample ordinary candidates so removing cross-source duplicates can still
  -- fill the menu. No placeholders are created while a source is pending/empty.
  local items = M.filter(ordinary, ctx, limit + extra, opts)
  insert_blocks(items, blocks)

  local result, seen = {}, {}
  for _, entry in ipairs(items) do
    if not seen[entry.key] then
      result[#result + 1], seen[entry.key] = entry, true

      if #result == limit then
        break
      end
    end
  end

  return result
end

local function has_insert_at(groups)
  for _, group in ipairs(groups) do
    if group.insert_at then
      return true
    end
  end

  return false
end

function M.select(groups, ctx, limit, opts)
  if ctx.mode == "cmdline" or not has_insert_at(groups) then
    return M.filter(groups, ctx, limit, opts)
  end

  return select_with_insert_at(groups, ctx, limit, opts)
end

return M
