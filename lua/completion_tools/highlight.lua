local M = {}
local cache, order, next_slot = {}, {}, 1
local keywords, types = {}, {}

for word in
  ("async await const def enum export fn func function impl import let local mut new pub return self static struct type var void"):gmatch(
    "%S+"
  )
do
  keywords[word] = true
end

for word in
  ("any bool boolean byte char double error float float32 float64 i8 i16 i32 i64 int integer never nil number object str string u8 u16 u32 u64 unknown usize"):gmatch(
    "%S+"
  )
do
  types[word] = true
end

local function add(spans, first, last, group, priority)
  if last > first then
    spans[#spans + 1] = { first, last, group, priority or 120 }
  end
end

local function lexical(text, spans)
  local pos = 1
  while pos <= #text do
    local rest, char = text:sub(pos), text:sub(pos, pos)
    local token, group

    if char == '"' or char == "'" or char == "`" then
      local ending, escaped = pos + 1, false
      while ending <= #text do
        local c = text:sub(ending, ending)
        if c == char and not escaped then
          ending = ending + 1
          break
        end

        escaped = c == "\\" and not escaped
        ending = ending + 1
      end

      token, group = text:sub(pos, ending - 1), "@string"
    elseif char == "\\" then
      token, group = rest:match("^\\[%a@]+"), "@function"
    elseif char:match("%d") and not text:sub(pos - 1, pos - 1):match("[%w_]") then
      token, group = rest:match("^%d[%w_.]*"), "@number"
    elseif char:match("[%a_]") then
      token = rest:match("^[%a_][%w_]*")

      local after = rest:sub(#token + 1)
      if keywords[token] then
        group = "@keyword"
      elseif types[token] then
        group = "@type.builtin"
      elseif token:match("^[A-Z][A-Z_0-9]+$") then
        group = "@constant"
      elseif token:match("^[A-Z]") then
        group = "@type"
      elseif after:match("^%s*:%s*[^:]") then
        group = "@variable.parameter"
      elseif after:match("^%s*%(") then
        group = "@function"
      end
    elseif char:match("[%(%)%[%]{},;.]") then
      token, group = char, "@punctuation.delimiter"
    elseif char:match("[:<>=+*/&|!?~%%%-]") then
      token, group = char, "@operator"
    end

    if token then
      if group then
        add(spans, pos - 1, pos + #token - 1, group)
      end

      pos = pos + #token
    else
      pos = pos + 1
    end
  end
end

local function stack_captures(spans, captures, priority)
  local boundaries, starts = {}, {}
  for index, capture in ipairs(captures) do
    local first, last = capture[1], capture[2]
    boundaries[first], boundaries[last] = true, true
    starts[first] = starts[first] or {}
    table.insert(starts[first], index)
  end

  local columns, active = vim.tbl_keys(boundaries), {}
  table.sort(columns)
  for i = 1, #columns - 1 do
    local first, last = columns[i], columns[i + 1]
    for j = #active, 1, -1 do
      if captures[active[j]][2] <= first then
        table.remove(active, j)
      end
    end
    if starts[first] then
      vim.list_extend(active, starts[first])
      table.sort(active, function(left, right)
        local left_priority, right_priority = captures[left][4], captures[right][4]
        return left_priority < right_priority or (left_priority == right_priority and left < right)
      end)
    end

    if #active == 1 then
      add(spans, first, last, captures[active[1]][3], priority)
    elseif #active > 1 then
      -- Stacked extmark groups apply in list order, like Tree-sitter captures.
      local groups = vim.tbl_map(function(index)
        return captures[index][3]
      end, active)
      add(spans, first, last, groups, priority)
    end
  end
end

local function treesitter(text, filetype, spans)
  -- Plain identifiers need only kind coloring; do not load a parser for buffer words.
  if not text:find("[%(%):<{}]") or filetype == "" then
    return
  end

  local parser
  pcall(function()
    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return
    end

    parser = vim.treesitter.get_string_parser(text, lang, { injections = { [lang] = "" } })
    local tree = parser:parse()[1]

    local by_priority = {}
    for id, node, metadata in query:iter_captures(tree:root(), text, 0, 1) do
      local capture = query.captures[id]
      if capture:sub(1, 1) ~= "_" and capture ~= "spell" and capture ~= "nospell" then
        local range = vim.treesitter.get_range(node, text, metadata[id])
        if range[1] == 0 and range[4] == 0 and range[2] < range[5] then
          local query_priority = math.floor(tonumber(metadata.priority or (metadata[id] or {}).priority) or 100)
          local priority = 130 + math.min(50, math.max(0, query_priority - 100))
          local captures = by_priority[priority] or {}
          captures[#captures + 1] = { range[2], range[5], "@" .. capture .. "." .. lang, query_priority }
          by_priority[priority] = captures
        end
      end
    end

    local priorities = vim.tbl_keys(by_priority)
    table.sort(priorities)
    for _, priority in ipairs(priorities) do
      stack_captures(spans, by_priority[priority], priority)
    end
  end)

  if parser then
    parser:destroy()
  end
end

function M.clear()
  cache, order, next_slot = {}, {}, 1
end

-- Spans are zero-based, exclusive byte ranges. No trees or parser objects are cached.
function M.get(text, filetype, opts)
  if not opts.enabled or not filetype then
    return {}
  end

  local key = table.concat({
    filetype,
    tostring(opts.treesitter),
    tostring(opts.max_bytes),
    text,
  }, "\0")

  local spans = cache[key]
  if not spans then
    spans = {}
    lexical(text, spans)

    if opts.treesitter and #text <= opts.max_bytes then
      treesitter(text, filetype, spans)
    end

    if opts.cache_size > 0 then
      local old = order[next_slot]
      if old then
        cache[old] = nil
      end

      order[next_slot], cache[key] = key, spans
      next_slot = next_slot % opts.cache_size + 1
    end
  end

  return spans
end

return M
