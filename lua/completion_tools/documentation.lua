local M = {}
local CompletionItemKind = require("vim.lsp.protocol").CompletionItemKind
local kinds = require("completion_tools.kinds")

---@class completion_tools.DocumentationItem: lsp.CompletionItem
---@field _path_preview? {kind: "text", lines: string[], filetype: string, truncated: boolean}|{kind: "media", path: string}
---@field _documentation_filetype? string Filetype for highlighting literal documentation text.

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

local function has_function_signature(body, label)
  local marker, name = body:match("^%s*([`~]+)[^\n]*\n%s*function%s+([%a_][%w_.:]*)%s*%b()")
  if not marker or #marker < 3 or not (marker:match("^`+$") or marker:match("^~+$")) then
    return false
  end

  local label_name = label:match("^%s*([%a_][%w_.:]*)")
  local member = name:match("[^.:]+$")

  return member ~= nil and label_name ~= nil and member == label_name:match("[^.:]+$")
end

local function collect_metadata(item, markdown_body)
  local signature, description, seen = {}, {}, {}

  local function metadata(target, value)
    if type(value) == "string" and value ~= "" and not seen[value] then
      seen[value] = true
      vim.list_extend(target, vim.split(value, "\n", { plain = true }))
    end
  end

  local details = item.labelDetails or {}
  local redundant_detail = markdown_body
    and item.kind == CompletionItemKind.Function
    and item.detail == "function"
    and type(item.label) == "string"
    and has_function_signature(markdown_body, item.label)
  if not redundant_detail then
    metadata(signature, item.detail)
  end

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
---@return string[] lines
---@return string? language
function M.build(item, filetype)
  local documentation = item.documentation
  local body = type(documentation) == "table" and documentation.value or documentation
  if type(body) ~= "string" or body == "" then
    body = nil
  end

  local preview = item._path_preview
  local text_preview = preview and preview.kind == "text" and preview or nil
  local plaintext = type(documentation) == "table" and documentation.kind == "plaintext"
  local markdown_body = body
  if preview or item._documentation_filetype or plaintext then
    markdown_body = nil
  end

  local lines, description = collect_metadata(item, markdown_body)
  local signature_language
  if #lines > 0 and not kinds.is_path(item.kind) and filetype ~= "markdown" then
    signature_language = filetype
  end

  local language
  if markdown_body then
    fence(lines, signature_language)
    fence(description)
    language = "markdown"
  elseif text_preview then
    language = text_preview.filetype
  elseif not preview then
    if body then
      language = item._documentation_filetype
    elseif #description == 0 then
      language = signature_language
    end
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

  return lines, language and language ~= "" and language or nil
end

return M
