local M = {}
local byte, find, lower = string.byte, string.find, string.lower

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
    score = score
      + 16
      + (boundary and 24 or 0)
      + (at == previous + 1 and 12 or 0)
      - math.min(at - previous - 1, 20)
    previous, pos = at, at + 1
  end
  return score - math.min(#text - #query, 100)
end

local function better(a, b)
  if a.score ~= b.score then
    return a.score > b.score
  end
  local ai, bi = a.item, b.item
  local as, bs = ai.sortText or ai.label, bi.sortText or bi.label
  if as ~= bs then
    return as < bs
  end
  if a.group.priority ~= b.group.priority then
    return a.group.priority < b.group.priority
  end
  return a.index < b.index
end

-- Keep only the best K in a min-heap, instead of sorting every match.
function M.filter(groups, ctx, limit)
  local heap, keys, index = {}, {}, 0
  local function swap(a, b)
    heap[a], heap[b] = heap[b], heap[a]
    keys[heap[a].key], keys[heap[b].key] = a, b
  end
  local function down(i)
    while i * 2 <= #heap do
      local child = i * 2
      if child < #heap and better(heap[child], heap[child + 1]) then
        child = child + 1
      end
      if not better(heap[i], heap[child]) then
        break
      end
      swap(i, child)
      i = child
    end
  end
  local query_cache = {}
  for _, group in ipairs(groups) do
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
      if score then
        score = score + group.score_offset + (item.preselect and 8 or 0)
        -- Exclude the word being typed from the buffer source only.
        local root = heap[1]
        local sort_key = item.sortText or item.label
        local competitive = #heap < limit
          or score > root.score
          or (
            score == root.score
            and (
              sort_key < (root.item.sortText or root.item.label)
              or (
                sort_key == (root.item.sortText or root.item.label) and group.priority < root.group.priority
              )
            )
          )
        if competitive and not (group.source_id == "buffer" and item.label == ctx.prefix) then
          local text = item.textEdit and item.textEdit.newText or item.insertText or item.label
          local key = item.label .. "\0" .. text .. "\0" .. (item.kind or 0)
          local candidate = { item = item, group = group, score = score, key = key, index = index }
          local existing = keys[key]
          if existing then
            if better(candidate, heap[existing]) then
              heap[existing] = candidate
              down(existing)
            end
          elseif #heap < limit then
            heap[#heap + 1] = candidate
            local i = #heap
            keys[key] = i
            while i > 1 do
              local parent = math.floor(i / 2)
              if not better(heap[parent], heap[i]) then
                break
              end
              swap(parent, i)
              i = parent
            end
          elseif better(candidate, heap[1]) then
            keys[heap[1].key] = nil
            heap[1], keys[key] = candidate, 1
            down(1)
          end
        end
      end
    end
  end
  table.sort(heap, better)
  local result = {}
  for i, candidate in ipairs(heap) do
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

return M
