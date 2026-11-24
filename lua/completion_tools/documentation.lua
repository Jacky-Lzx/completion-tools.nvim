local M = {}
local kinds = require("completion_tools.kinds")

---@class completion_tools.Documentation
---@field kind "text"|"markdown"|"code"
---@field value string
---@field filetype? string
---@field detail? string
---@field labelDetails? lsp.CompletionItemLabelDetails

---@class completion_tools.DocumentationItem: lsp.CompletionItem
---@field _path_preview? {kind: "text", lines: string[], filetype: string, truncated: boolean}|{kind: "media", path: string}
---@field _documentation_filetype? string Filetype for highlighting literal documentation text.

---@param value string
---@return completion_tools.Documentation
function M.text(value)
  return { kind = "text", value = value }
end

---@param value string
---@return completion_tools.Documentation
function M.markdown(value)
  return { kind = "markdown", value = value }
end

---@param value string
---@param filetype? string
---@return completion_tools.Documentation
function M.code(value, filetype)
  return { kind = "code", value = value, filetype = filetype }
end

-- Keep literal metadata inside code blocks when it shares a Markdown buffer.
---@param lines string[]
---@param filetype? string
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

local function collect_metadata(item)
  local signature, description, seen = {}, {}, {}

  local function metadata(target, value)
    if type(value) == "string" and value ~= "" and not seen[value] then
      seen[value] = true
      vim.list_extend(target, vim.split(value, "\n", { plain = true }))
    end
  end

  local details = item.labelDetails or {}
  metadata(signature, item.detail)
  metadata(signature, details.detail)
  metadata(description, details.description)
  return signature, description
end

local function append_section(lines, section)
  if #lines > 0 then
    lines[#lines + 1] = ""
  end

  vim.list_extend(lines, section)
end

---@param item completion_tools.DocumentationItem
---@param filetype? string
---@param document? completion_tools.Documentation
---@return string[] lines
---@return string? language
---@return boolean markdown Whether to conceal Markdown markup in the float.
function M.build(item, filetype, document)
  local preview = not document and item._path_preview or nil
  local body, markdown, language

  if document then
    body = document.value
    markdown = document.kind == "markdown"
    language = document.kind == "code" and document.filetype or nil
  else
    local documentation = item.documentation
    body = type(documentation) == "table" and documentation.value or documentation
    local plaintext = type(documentation) == "table" and documentation.kind == "plaintext"
    markdown = not (preview or item._documentation_filetype or plaintext)
    language = not preview and type(body) == "string" and body ~= "" and item._documentation_filetype or nil
  end

  if type(body) ~= "string" or body == "" then
    body = nil
    markdown = false
  end

  local text_preview = preview and preview.kind == "text" and preview or nil
  local lines, description = collect_metadata(document or item)
  local signature_language
  if #lines > 0 and not kinds.is_path(item.kind) and filetype ~= "markdown" then
    signature_language = filetype
  end

  if markdown then
    fence(lines, signature_language)
    fence(description)
    language = "markdown"
  elseif text_preview then
    language = text_preview.filetype
  elseif not document and not preview and not body and #description == 0 then
    language = signature_language
  end

  vim.list_extend(lines, description)

  if body then
    append_section(lines, vim.split(body, "\n", { plain = true }))
  end

  if text_preview then
    append_section(lines, text_preview.lines)
    if text_preview.truncated then
      lines[#lines + 1] = "… preview truncated"
    end
  end

  while lines[#lines] == "" do
    lines[#lines] = nil
  end

  return lines, language and language ~= "" and language or nil, markdown
end

return M
