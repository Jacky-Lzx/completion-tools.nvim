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

local function rule(line)
  local indent, body = line:match("^( *)(.-)%s*$")
  if #indent > 3 then
    return false
  end
  body = body:gsub("[ \t]", "")
  return #body >= 3 and (body:match("^%-+$") or body:match("^%*+$") or body:match("^_+$"))
end

-- Keep prose markup in the buffer, with byte ranges for conceal and styling.
-- Code spans are opaque; punctuation/whitespace flanking avoids identifier underscores.
local function emphasis(line, code_ranges)
  local spans, stack, hidden, pos, code_index = {}, {}, {}, 1, 1
  while pos <= #line do
    local code = code_ranges[code_index]
    if code and pos > code[2] then
      code_index = code_index + 1
    elseif code and pos > code[1] then
      pos = code[2] + 1
    else
      local char = line:sub(pos, pos)
      local ending = pos
      if char == "*" or char == "_" then
        while line:sub(ending + 1, ending + 1) == char do
          ending = ending + 1
        end
        local size = ending - pos + 1
        local escaping = line:sub(1, pos - 1):match("\\+$") or ""
        if size <= 3 and #escaping % 2 == 0 then
          local before, after = line:sub(pos - 1, pos - 1), line:sub(ending + 1, ending + 1)
          local before_space, after_space =
            before == "" or before:match("%s"), after == "" or after:match("%s")
          local before_punct, after_punct = before:match("%p"), after:match("%p")
          local left = not after_space and (not after_punct or before_space or before_punct)
          local right = not before_space and (not before_punct or after_space or after_punct)
          local opens = left and (char ~= "_" or not right or before_punct)
          local closes = right and (char ~= "_" or not left or after_punct)
          local matched
          if closes then
            for index = #stack, 1, -1 do
              if stack[index].char == char and stack[index].size == size then
                matched = index
                break
              end
            end
          end
          if matched then
            local opening = stack[matched]
            for index = #stack, matched, -1 do
              stack[index] = nil
            end
            for _, edge in ipairs({ { opening.first, opening.last }, { pos - 1, ending } }) do
              spans[#spans + 1] = { first = edge[1], last = edge[2], conceal = true }
              for byte = edge[1] + 1, edge[2] do
                hidden[byte] = true
              end
            end
            spans[#spans + 1] = {
              first = opening.last,
              last = pos - 1,
              group = size == 1 and "CompletionToolsDocItalic"
                or size == 2 and "CompletionToolsDocBold"
                or "CompletionToolsDocBoldItalic",
            }
          elseif opens then
            stack[#stack + 1] = { first = pos - 1, last = ending, char = char, size = size }
          end
        end
      end
      pos = ending + 1
    end
  end
  local visible = {}
  for byte = 1, #line do
    if not hidden[byte] then
      visible[#visible + 1] = line:sub(byte, byte)
    end
  end
  return table.concat(visible), spans
end

-- Return buffer lines, decoration ranges and unconcealed text. Rules use an
-- empty text row because the UI draws their separator at the final window width.
-- CompletionItem.detail and plaintext documentation are literal, never Markdown.
function M.build(item, filetype)
  local lines, ranges, visible = {}, {}, {}
  local function append(line, display)
    lines[#lines + 1], visible[#visible + 1] = line, display or line
  end
  local function code(line, ft)
    append(line)
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
      append("")
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
      elseif markdown and (line:match("^    ") or line:match("^\t")) then
        code(line, filetype)
      elseif markdown and rule(line) then
        append(line, "")
        ranges[#ranges + 1] = { row = #lines - 1, first = 0, last = #line, rule = true }
      elseif markdown then
        local display, spans = inline(line)
        local rendered, styles = emphasis(display, spans)
        append(display, rendered)
        for _, span in ipairs(spans) do
          ranges[#ranges + 1] =
            { row = #lines - 1, first = span[1], last = span[2], filetype = filetype, inline_code = true }
        end
        for _, span in ipairs(styles) do
          span.row = #lines - 1
          ranges[#ranges + 1] = span
        end
      else
        append(line)
      end
    end
  end
  while lines[#lines] == "" do
    lines[#lines] = nil
    visible[#visible] = nil
  end
  return lines,
    vim.tbl_filter(function(range)
      return range.row < #lines and range.last > range.first
    end, ranges),
    visible
end

function M.highlight(buf, ns, lines, ranges, opts, width)
  local highlight = require("completion_tools.highlight")
  -- Menu callbacks receive real candidate entries, so they do not run for documents.
  opts = vim.tbl_extend("force", opts, { custom = false })
  for _, range in ipairs(ranges) do
    if range.rule then
      vim.api.nvim_buf_set_extmark(buf, ns, range.row, range.first, {
        end_col = range.last,
        conceal = "",
        virt_text = { { string.rep("─", width or 12), "CompletionToolsDocSeparator" } },
        virt_text_pos = "overlay",
      })
    elseif range.conceal or range.group then
      vim.api.nvim_buf_set_extmark(buf, ns, range.row, range.first, {
        end_col = range.last,
        conceal = range.conceal and "" or nil,
        hl_group = range.group,
        priority = 190,
      })
    else
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
end

return M
