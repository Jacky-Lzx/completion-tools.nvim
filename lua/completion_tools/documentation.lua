local M = {}

local function fence(line)
  local indent, marker, info = line:match("^( *)([`~]+)(.*)$")
  if indent and #indent <= 3 and #marker >= 3 and (marker:match("^`+$") or marker:match("^~+$")) then
    if marker:sub(1, 1) == "`" and info:find("`", 1, true) then
      return
    end
    return marker, info
  end
end

-- Render inline code without its delimiters; unmatched/escaped delimiters stay literal.
local function inline(line)
  local pieces, spans, pos, bytes = {}, {}, 1, 0
  local function append(value)
    pieces[#pieces + 1], bytes = value, bytes + #value
  end
  while pos <= #line do
    local first, last = line:find("`+", pos)
    if not first then
      append(line:sub(pos))
      break
    end
    local escaping = line:sub(1, first - 1):match("\\+$") or ""
    local closing, ending, search = nil, nil, last + 1
    if #escaping % 2 == 0 then
      while search <= #line do
        local a, b = line:find("`+", search)
        if not a then
          break
        end
        if b - a == last - first then
          closing, ending = a, b
          break
        end
        search = b + 1
      end
    end
    if closing then
      append(line:sub(pos, first - 1))
      local code = line:sub(last + 1, closing - 1)
      if code:match("^ .+ $") and code:find("%S") then
        code = code:sub(2, -2)
      end
      local start = bytes
      append(code)
      spans[#spans + 1] = { start, bytes }
      pos = ending + 1
    else
      append(line:sub(pos, last))
      pos = last + 1
    end
  end
  return table.concat(pieces), spans
end

-- Return display lines and their code ranges after removing Markdown code markers.
-- CompletionItem.detail and plaintext documentation are literal, never Markdown.
function M.build(item, filetype)
  local lines, ranges = {}, {}
  local function code(line, ft)
    lines[#lines + 1] = line
    ranges[#ranges + 1] = {
      row = #lines - 1,
      first = 0,
      last = #line,
      filetype = ft,
    }
  end
  if type(item.detail) == "string" and item.detail ~= "" then
    for _, line in ipairs(vim.split(item.detail, "\n", { plain = true })) do
      code(line, filetype)
    end
  end
  local documentation = item.documentation
  local value = type(documentation) == "table" and documentation.value or documentation
  local markdown = type(documentation) ~= "table" or documentation.kind ~= "plaintext"
  if type(value) == "string" and value ~= "" then
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    local opened, language
    for _, line in ipairs(vim.split(value, "\n", { plain = true })) do
      local marker, info
      if markdown then
        marker, info = fence(line)
      end
      if opened then
        if marker and marker:sub(1, 1) == opened:sub(1, 1) and #marker >= #opened and not info:find("%S") then
          opened = nil
        else
          code(line, language)
        end
      elseif marker then
        opened, language = marker, info:match("^%s*([^%s]+)") or filetype
      elseif markdown then
        local display, spans = inline(line)
        lines[#lines + 1] = display
        for _, span in ipairs(spans) do
          ranges[#ranges + 1] =
            { row = #lines - 1, first = span[1], last = span[2], filetype = filetype, inline_code = true }
        end
      else
        lines[#lines + 1] = line
      end
    end
  end
  while lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines,
    vim.tbl_filter(function(range)
      return range.row < #lines and range.last > range.first
    end, ranges)
end

function M.highlight(buf, ns, lines, ranges, opts)
  local highlight = require("completion_tools.highlight")
  -- Menu callbacks receive real candidate entries, so they do not run for documents.
  opts = vim.tbl_extend("force", opts, { custom = false })
  for _, range in ipairs(ranges) do
    if range.inline_code then
      vim.api.nvim_buf_set_extmark(buf, ns, range.row, range.first, {
        end_col = range.last,
        hl_group = "CompletionToolsDocCode",
      })
    end
    local original = lines[range.row + 1]:sub(range.first + 1, range.last)
    local code = require("completion_tools.text").clean(original, opts.max_bytes)
    if #original > opts.max_bytes then
      code = code:sub(1, -4)
    end
    for _, span in ipairs(highlight.get(code, 0, { item = {} }, { filetype = range.filetype or "" }, opts)) do
      vim.api.nvim_buf_set_extmark(buf, ns, range.row, range.first + span[1], {
        end_col = range.first + span[2],
        hl_group = span[3],
        priority = span[4],
      })
    end
  end
end

return M
