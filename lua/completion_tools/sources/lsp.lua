local M = {}
local CompletionItemKind = require("vim.lsp.protocol").CompletionItemKind
local context = require("completion_tools.context")
local kinds = require("completion_tools.kinds")
local function last_character(text)
  return text:match("[%z\1-\127\194-\244][\128-\191]*$") or ""
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

---@class completion_tools.LspCompletionItem: lsp.CompletionItem
---@field _client_id integer ID of the client that returned the item.
---@field _client_name string Name of the client that returned the item.
---@field _encoding lsp.PositionEncodingKind Encoding used for edit positions.
---@field _syntax? string|false|{ label?: string|false, detail?: string|false } Syntax hints for the completion menu.

--- Apply supported list defaults and attach client metadata to completion items.
---@param result lsp.CompletionList|lsp.CompletionItem[]|nil|vim.NIL Raw completion response from the server.
---@param client vim.lsp.Client Client that returned the response.
---@param filetype string Filetype of the completion request.
---@return completion_tools.LspCompletionItem[] items Normalized items, or an empty array for a null response.
local function normalise(result, client, filetype)
  if not result or result == vim.NIL then
    return {}
  end
  local defaults, items = result.itemDefaults or {}, {}
  for _, raw in ipairs(result.items or result) do
    if type(raw.label) == "string" then
      local item = vim.tbl_extend("force", {}, raw)
      for _, key in ipairs({ "insertTextFormat", "insertTextMode", "data" }) do
        if item[key] == nil then
          item[key] = defaults[key]
        end
      end
      if not item.textEdit and defaults.editRange then
        item.textEdit = { newText = item.textEditText or item.insertText or item.label }
        if defaults.editRange.start then
          item.textEdit.range = defaults.editRange
        else
          item.textEdit.insert, item.textEdit.replace = defaults.editRange.insert, defaults.editRange.replace
        end
      end
      item._client_id, item._encoding = client.id, client.offset_encoding
      item._client_name = client.name
      if kinds.is_path(item.kind) then
        item._syntax = false
      elseif filetype ~= "" then
        if item.kind == nil or item.kind == CompletionItemKind.Text then
          item._syntax = { label = false, detail = filetype }
        else
          item._syntax = filetype
        end
      end
      items[#items + 1] = item
    end
  end
  return items
end

function M.new()
  local source = {
    display_name = function(item)
      local name = item._client_name
      return type(name) == "string" and name ~= "" and name or "LSP"
    end,
    score_offset = 40,
  }

  --- Last successful completion state, keyed by LSP client ID.
  --- Each entry holds the request context and the response's isIncomplete flag.
  ---@type table<integer, { context: table, incomplete: boolean }>
  local history = {}

  function source.complete(ctx, callback)
    local clients = vim.lsp.get_clients({ bufnr = ctx.bufnr, method = "textDocument/completion" })
    if #clients == 0 then
      history = {}
      callback({ items = {}, reusable = true })
      return
    end

    table.sort(clients, function(a, b)
      return a.id < b.id
    end)

    local active = {}
    for _, client in ipairs(clients) do
      active[client.id] = true
    end

    for id in pairs(history) do
      if not active[id] then
        history[id] = nil
      end
    end

    local cancelled, cancels, results, incomplete, pending = false, {}, {}, {}, #clients
    local function publish()
      local items, is_incomplete = {}, false
      for _, client in ipairs(clients) do
        for _, item in ipairs(results[client.id] or {}) do
          items[#items + 1] = item
        end
        is_incomplete = is_incomplete or incomplete[client.id] or false
      end
      callback({
        items = items,
        pending = pending > 0,
        is_incomplete = is_incomplete,
        reusable = pending == 0 and not is_incomplete,
      })
    end

    for _, client in ipairs(clients) do
      local params = vim.lsp.util.make_position_params(ctx.winid, client.offset_encoding)
      local character = last_character(ctx.before)
      local triggers = (client.server_capabilities.completionProvider or {}).triggerCharacters or {}
      local trigger = vim.list_contains(triggers, character)
      local previous = history[client.id]
      local retrigger = previous and previous.incomplete and context.extends(previous.context, ctx)
      params.context = {
        triggerKind = trigger and 2 or (retrigger and 3 or 1),
        triggerCharacter = trigger and character or nil,
      }

      local finished = false
      local ok, id = client:request("textDocument/completion", params, function(err, result)
        finished = true
        if cancelled then
          return
        end
        pending = pending - 1
        if not err then
          results[client.id] = normalise(result, client, ctx.filetype)
          incomplete[client.id] = result and result ~= vim.NIL and result.isIncomplete or false
          history[client.id] = { context = ctx, incomplete = incomplete[client.id] }
        end
        publish()
      end, ctx.bufnr)

      if ok then
        cancels[#cancels + 1] = function()
          if not finished then
            finished = true
            client:cancel_request(id)
          end
        end
      else
        pending = pending - 1
      end
    end

    if pending == 0 then
      publish()
    end

    return function()
      cancelled = true
      for _, cancel in ipairs(cancels) do
        cancel()
      end
    end
  end

  function source.trigger(ctx)
    local character = last_character(ctx.before)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = ctx.bufnr, method = "textDocument/completion" })) do
      if
        vim.list_contains((client.server_capabilities.completionProvider or {}).triggerCharacters or {}, character)
      then
        return true
      end
    end
    return false
  end

  function source.documentation(item)
    if item.detail ~= "function" or item.kind ~= CompletionItemKind.Function or type(item.label) ~= "string" then
      return
    end
    local documentation = item.documentation
    local plaintext = type(documentation) == "table" and documentation.kind == "plaintext"
    if plaintext or item._path_preview or item._documentation_filetype then
      return
    end
    local body = type(documentation) == "table" and documentation.value or documentation
    if type(body) == "string" and has_function_signature(body, item.label) then
      local document = require("completion_tools.documentation").markdown(body)
      document.labelDetails = item.labelDetails
      return document
    end
  end

  function source.resolve(entry, callback)
    local client = entry.item._client_id and vim.lsp.get_client_by_id(entry.item._client_id)
    if not client or not (client.server_capabilities.completionProvider or {}).resolveProvider then
      callback(entry.item)
      return
    end

    local raw = vim.tbl_extend("force", {}, entry.item)
    raw._client_id, raw._encoding = nil, nil
    raw._client_name, raw._syntax = nil, nil
    local finished = false
    local ok, id = client:request("completionItem/resolve", raw, function(err, item)
      finished = true
      if err or not item or item == vim.NIL then
        callback(entry.item)
        return
      end
      callback(vim.tbl_extend("force", {}, entry.item, item))
    end, entry.context.bufnr)

    if not ok then
      callback(entry.item)
      return
    end

    return function()
      if not finished then
        finished = true
        client:cancel_request(id)
      end
    end
  end

  function source.dispose()
    history = {}
  end

  return source
end

return M
