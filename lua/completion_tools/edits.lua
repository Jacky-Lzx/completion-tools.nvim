local M = {}
local ns = vim.api.nvim_create_namespace("completion-tools-accept")

local function units(text, encoding)
  if encoding == "utf-8" then
    return #text
  end
  return vim.str_utfindex(text, encoding, #text, false)
end
local function byte_col(buf, position, encoding)
  local line = vim.api.nvim_buf_get_lines(buf, position.line, position.line + 1, false)[1] or ""
  if encoding == "utf-8" then
    return math.min(position.character, #line)
  end
  return vim.str_byteindex(line, encoding, position.character, false)
end

function M.rebase(range, old, ctx, encoding)
  local result = vim.deepcopy(range)
  local old_col = units(old.before, encoding)
  local delta = units(ctx.before, encoding) - old_col
  for i, position in ipairs({ result.start, result["end"] }) do
    if
      position.line == old.row
      and (position.character > old_col or (i == 2 and position.character == old_col))
    then
      position.character = position.character + delta
    end
  end
  return result
end

function M.range(entry, ctx)
  local item = entry.resolved or entry.item
  local edit = item.textEdit
  local encoding = item._encoding or "utf-8"
  if edit then
    return M.rebase(edit.range or edit.replace or edit.insert, entry.context, ctx, encoding), encoding
  end
  return {
    start = { line = ctx.row, character = units(ctx.line:sub(1, entry.start_col), encoding) },
    ["end"] = { line = ctx.row, character = units(ctx.before, encoding) },
  },
    encoding
end

local function additional_range(entry, range, ctx, encoding)
  local item, old = entry.resolved or entry.item, entry.context
  local edit = item.textEdit
  local primary_start = edit and (edit.range or edit.replace or edit.insert).start
    or { line = old.row, character = units(old.line:sub(1, entry.start_col), encoding) }
  local result = vim.deepcopy(range)
  local finish = range["end"]
  -- Edits before the primary range stay before it, including an import at
  -- the same zero-width start. Edits after it move past newly typed text.
  local before = finish.line < primary_start.line
    or (finish.line == primary_start.line and finish.character <= primary_start.character)
  if not before then
    local old_col = units(old.before, encoding)
    local delta = units(ctx.before, encoding) - old_col
    for _, position in ipairs({ result.start, result["end"] }) do
      if position.line == old.row and position.character >= old_col then
        position.character = position.character + delta
      end
    end
  end
  return result
end

function M.apply(entry, ctx, config)
  local item = entry.resolved or entry.item
  local text = item.textEdit and item.textEdit.newText or item.insertText or item.label
  text = text:gsub("\r\n?", "\n")
  if ctx.mode == "cmdline" then
    vim.fn.setcmdline(
      ctx.line:sub(1, entry.start_col) .. text .. ctx.line:sub(ctx.col + 1),
      entry.start_col + #text + 1
    )
    return
  end
  local range, encoding = M.range(entry, ctx)
  local snippet = item.insertTextFormat == 2
  local edits, mark = {}, nil
  for _, edit in ipairs(item.additionalTextEdits or {}) do
    edits[#edits + 1] = { newText = edit.newText, range = additional_range(entry, edit.range, ctx, encoding) }
  end
  local primary = { range = range, newText = snippet and "" or text }
  edits[#edits + 1] = primary
  for i, edit in ipairs(edits) do
    edit.order = i
  end
  table.sort(edits, function(a, b)
    if a.range.start.line ~= b.range.start.line then
      return a.range.start.line > b.range.start.line
    end
    if a.range.start.character ~= b.range.start.character then
      return a.range.start.character > b.range.start.character
    end
    return a.order > b.order
  end)
  -- Follow native edit ordering, but create the anchor immediately after the
  -- primary edit. An anchor created before all edits cannot distinguish an
  -- import at primary.start from a suffix insertion at primary.end.
  local ok, err = pcall(function()
    for i, edit in ipairs(edits) do
      local row, col
      if edit == primary then
        row, col = range.start.line, byte_col(ctx.bufnr, range.start, encoding)
      end
      if i > 1 then
        pcall(vim.cmd, "undojoin")
      end
      vim.lsp.util.apply_text_edits({ edit }, ctx.bufnr, encoding)
      if edit == primary then
        local lines = vim.split(primary.newText, "\n", { plain = true })
        mark = vim.api.nvim_buf_set_extmark(
          ctx.bufnr,
          ns,
          row + #lines - 1,
          (#lines == 1 and col or 0) + #lines[#lines],
          { right_gravity = true }
        )
      end
    end
  end)
  if not ok then
    if mark then
      vim.api.nvim_buf_del_extmark(ctx.bufnr, ns, mark)
    end
    error(err)
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(ctx.bufnr, ns, mark, {})
  local row, col = position[1], position[2]
  vim.api.nvim_win_set_cursor(ctx.winid, { row + 1, col })
  if snippet then
    local expand = config.snippets.expand or vim.snippet.expand
    local expanded, expand_err = pcall(expand, text)
    if not expanded then
      -- A malformed server snippet falls back to its literal body.
      pcall(vim.cmd, "undojoin")
      local lines = vim.split(text, "\n", { plain = true })
      vim.api.nvim_buf_set_text(ctx.bufnr, row, col, row, col, lines)
      vim.api.nvim_win_set_cursor(ctx.winid, { row + #lines, (#lines == 1 and col or 0) + #lines[#lines] })
      vim.notify("completion-tools: snippet expansion failed: " .. tostring(expand_err), vim.log.levels.WARN)
    end
  end
  local end_position = vim.api.nvim_buf_get_extmark_by_id(ctx.bufnr, ns, mark, {})
  vim.api.nvim_buf_del_extmark(ctx.bufnr, ns, mark)
  local end_line = vim.api.nvim_buf_get_lines(ctx.bufnr, end_position[1], end_position[1] + 1, false)[1]
  return {
    range = range,
    encoding = encoding,
    new_end = { line = end_position[1], character = units(end_line:sub(1, end_position[2]), encoding) },
  }
end

-- A resolve response can arrive after primary insertion. Convert its original
-- coordinates through that insertion, and only apply it while changedtick still
-- equals the acceptance tick (the engine enforces that guard).
function M.apply_resolved(entry, ctx, item, transaction)
  local edits = {}
  local old_end, new_end = transaction.range["end"], transaction.new_end
  for _, edit in ipairs(item.additionalTextEdits or {}) do
    local range = additional_range(entry, edit.range, ctx, transaction.encoding)
    for _, position in ipairs({ range.start, range["end"] }) do
      if position.line > old_end.line then
        position.line = position.line + new_end.line - old_end.line
      elseif position.line == old_end.line and position.character >= old_end.character then
        position.line, position.character =
          new_end.line, new_end.character + position.character - old_end.character
      end
    end
    edits[#edits + 1] = { newText = edit.newText, range = range }
  end
  if #edits > 0 then
    vim.api.nvim_buf_call(ctx.bufnr, function()
      pcall(vim.cmd, "undojoin")
      vim.lsp.util.apply_text_edits(edits, ctx.bufnr, transaction.encoding)
    end)
  end
end

return M
