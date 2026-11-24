local M = {}

-- Keep the best value for each key. The lowest-ranked value sits at the root.
function M.new(limit, better)
  local heap, positions = {}, {}

  local function swap(a, b)
    heap[a], heap[b] = heap[b], heap[a]
    positions[heap[a].key], positions[heap[b].key] = a, b
  end

  local function down(index)
    while index * 2 <= #heap do
      local child = index * 2
      if child < #heap and better(heap[child].value, heap[child + 1].value) then
        child = child + 1
      end

      if not better(heap[index].value, heap[child].value) then
        break
      end

      swap(index, child)
      index = child
    end
  end

  local top = {}

  -- The root becomes an admission cutoff once the heap is full.
  function top.cutoff()
    if #heap == limit then
      return heap[1].value
    end
  end

  function top.offer(key, value)
    local existing = positions[key]
    if existing then
      if better(value, heap[existing].value) then
        heap[existing].value = value
        down(existing)
      end
      return
    end

    if #heap == limit then
      local root = heap[1]
      if better(value, root.value) then
        positions[root.key] = nil
        root.key, root.value = key, value
        positions[key] = 1
        down(1)
      end
      return
    end

    local index = #heap + 1
    heap[index], positions[key] = { key = key, value = value }, index
    while index > 1 do
      local parent = math.floor(index / 2)
      if not better(heap[parent].value, heap[index].value) then
        break
      end

      swap(parent, index)
      index = parent
    end
  end

  function top.sorted()
    local values = {}
    for index, entry in ipairs(heap) do
      values[index] = entry.value
    end

    table.sort(values, better)
    return values
  end

  return top
end

return M
