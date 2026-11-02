local M = {}
local kinds = require("completion_tools.kinds")
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
    for id, node, metadata in query:iter_captures(tree:root(), text, 0, 1) do
      local capture = query.captures[id]
      if capture:sub(1, 1) ~= "_" and capture ~= "spell" and capture ~= "nospell" then
        local range = vim.treesitter.get_range(node, text, metadata[id])
        if range[1] == 0 and range[4] == 0 then
          local priority = tonumber((metadata[id] or {}).priority or metadata.priority) or 100
          add(
            spans,
            range[2],
            range[5],
            "@" .. capture .. "." .. lang,
            130 + math.min(50, math.max(0, priority - 100))
          )
        end
      end
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
function M.get(text, label_bytes, entry, ctx, opts)
  if not opts.enabled then
    return {}
  end
  local ft = ctx.filetype or ""
  local key = table.concat({
    ft,
    tostring(entry.item.kind),
    tostring(label_bytes),
    tostring(opts.treesitter),
    tostring(opts.max_bytes),
    text,
  }, "\0")
  local spans = cache[key]
  if not spans then
    spans = {}
    local _, _, group = kinds.get(entry.item.kind)
    local plain_text = label_bytes > 0 and (entry.item.kind == nil or entry.item.kind == 1)
    add(spans, 0, plain_text and #text or math.min(label_bytes, #text), group, 110)
    if not plain_text then
      -- Text candidates stay uniformly muted, even when words resemble code.
      -- Documentation passes label_bytes=0 and keeps its syntax highlighting.
      lexical(text, spans)
      if opts.treesitter and #text <= opts.max_bytes then
        treesitter(text, ft, spans)
      end
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
  if opts.custom then
    local ok, extra = pcall(opts.custom, entry, ctx, text)
    if ok and type(extra) == "table" then
      spans = vim.list_extend(vim.deepcopy(spans), extra)
    end
  end
  return spans
end

return M
