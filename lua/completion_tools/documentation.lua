local M = {}

-- Keep literal metadata inside code blocks when it shares a Markdown buffer.
local function fence(lines, filetype)
  if #lines == 0 then
    return
  end
  local length = 3
  for _, line in ipairs(lines) do
    for run in line:gmatch("~+") do
      length = math.max(length, #run + 1)
    end
  end
  local marker = string.rep("~", length)
  local language = filetype and filetype:match("^[%w_.+-]+$") or ""
  table.insert(lines, 1, marker .. language)
  lines[#lines + 1] = marker
end

function M.build(item, filetype)
  local lines, description, seen = {}, {}, {}
  local function metadata(target, value)
    if type(value) == "string" and value ~= "" and not seen[value] then
      seen[value] = true
      vim.list_extend(target, vim.split(value, "\n", { plain = true }))
    end
  end
  local details = item.labelDetails or {}
  metadata(lines, item.detail)
  metadata(lines, details.detail)
  metadata(description, details.description)

  local documentation = item.documentation
  local body = type(documentation) == "table" and documentation.value or documentation
  local has_body = type(body) == "string" and body ~= ""
  local preview = item._path_preview
  local markdown = has_body and not preview and (type(documentation) ~= "table" or documentation.kind ~= "plaintext")
  local signature = #lines > 0 and item.kind ~= 17 and item.kind ~= 19 and filetype ~= "markdown" and filetype
  local language
  if markdown then
    fence(lines, signature)
    fence(description)
    language = "markdown"
  elseif preview and preview.kind == "text" then
    language = preview.filetype
  elseif not has_body and not preview and #description == 0 then
    language = signature
  end

  vim.list_extend(lines, description)
  if has_body then
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  end
  if preview and preview.kind == "text" then
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, preview.lines)
    if preview.truncated then
      lines[#lines + 1] = "… preview truncated"
    end
  end
  while lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines, language and language ~= "" and language or nil
end

return M
