local M = {}

-- CompletionItem.data is JSON, but object key order is not significant. Keep
-- identities stable when a streaming provider rebuilds its item tables.
local function encode(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  local keys, parts = {}, {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = encode(key) .. ":" .. encode(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.key(item)
  local text = item.textEdit and item.textEdit.newText or item.insertText or item.label
  local base = encode({ item.label, text, item.kind or 0 })
  local semantic = {}
  for _, field in ipairs({
    "detail",
    "labelDetails",
    "data",
    "textEdit",
    "additionalTextEdits",
    "command",
    "insertTextFormat",
    "insertTextMode",
  }) do
    if item[field] ~= nil then
      semantic[field] = item[field]
    end
  end
  if next(semantic) then
    semantic.client = item._client_id
    return base .. encode(semantic)
  end
  -- Plain words still deduplicate across sources, including buffer and LSP.
  return base
end

return M
