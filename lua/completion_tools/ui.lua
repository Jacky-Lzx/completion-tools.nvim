local M = {}
local ns = vim.api.nvim_create_namespace("completion-tools-menu")
local win, buf, doc_win, doc_buf, viewport = nil, nil, nil, nil, 1
local geometry

local function valid(id)
  return id and vim.api.nvim_win_is_valid(id)
end
local function close(id)
  if valid(id) then
    vim.api.nvim_win_close(id, true)
  end
end
local function scratch(id, filetype)
  if id and vim.api.nvim_buf_is_valid(id) then
    return id
  end
  id = vim.api.nvim_create_buf(false, true)
  vim.bo[id].bufhidden, vim.bo[id].filetype = "hide", filetype
  return id
end
local function clean(text)
  return (text or ""):gsub("[%c]", " ")
end
local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local result = ""
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if vim.fn.strdisplaywidth(result .. char) > width - 1 then
      break
    end
    result = result .. char
  end
  return result .. "…"
end

function M.highlights()
  for name, target in pairs({
    CompletionToolsMenu = "Pmenu",
    CompletionToolsBorder = "FloatBorder",
    CompletionToolsSelected = "PmenuSel",
    CompletionToolsMatch = "Special",
    CompletionToolsSource = "Comment",
    CompletionToolsDoc = "NormalFloat",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
end

function M.hide_documentation()
  close(doc_win)
  doc_win = nil
end
function M.hide()
  close(win)
  win, viewport, geometry = nil, 1, nil
  M.hide_documentation()
end
function M.visible()
  return valid(win) or false
end

function M.render(items, selected, ctx, config)
  if #items == 0 or vim.o.columns < 8 or vim.o.lines < 6 then
    M.hide()
    return
  end
  local opts = config.menu
  local screen
  if ctx.mode == "cmdline" then
    screen = {
      row = vim.o.lines - math.max(vim.o.cmdheight, 1) + 1,
      col = 2 + vim.fn.strdisplaywidth(ctx.before:sub(1, ctx.start_col)),
    }
  else
    screen = vim.fn.screenpos(ctx.winid, ctx.row + 1, ctx.start_col + 1)
    if screen.row == 0 then
      M.hide()
      return
    end
  end
  local below = vim.o.lines - math.max(vim.o.cmdheight, 1) - screen.row - 2
  local above = screen.row - 3
  local height = math.min(#items, opts.max_height, math.max(above, below))
  if height < 1 then
    M.hide()
    return
  end
  local width = opts.min_width
  for i = 1, math.min(#items, opts.max_height) do
    width = math.max(width, vim.fn.strdisplaywidth(clean(items[i].item.label)) + #items[i].source_id + 5)
  end
  width = math.min(width, opts.max_width, vim.o.columns - 4)
  local row = below >= height and screen.row or screen.row - height - 2
  local col = math.max(0, math.min(screen.col - 1, vim.o.columns - width - 2))
  local target = selected or 1
  if target < viewport then
    viewport = target
  end
  if target >= viewport + height then
    viewport = target - height + 1
  end
  viewport = math.max(1, math.min(viewport, #items - height + 1))
  local lines, spans = {}, {}
  for i = viewport, viewport + height - 1 do
    local entry = items[i]
    local source = "[" .. entry.source_id .. "]"
    local label = truncate(clean(entry.item.label), math.max(1, width - #source - 3))
    local padding = math.max(1, width - vim.fn.strdisplaywidth(label) - #source - 1)
    lines[#lines + 1] = " " .. label .. string.rep(" ", padding) .. source
    spans[#spans + 1] = { start = #lines[#lines] - #source, label = label, entry = entry }
  end
  buf = scratch(buf, "completion-tools-menu")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, span.start, {
      end_col = #lines[i],
      hl_group = "CompletionToolsSource",
    })
    local query = ctx.before:sub(span.entry.start_col + 1):lower()
    local pos = 1
    for j = 1, #query do
      local at = span.label:lower():find(query:sub(j, j), pos, true)
      if not at then
        break
      end
      -- Extmark columns must be on UTF-8 boundaries. Highlight ASCII matches;
      -- leave non-ASCII byte sequences intact.
      if query:byte(j) < 128 then
        vim.api.nvim_buf_set_extmark(
          buf,
          ns,
          i - 1,
          at,
          { end_col = at + 1, hl_group = "CompletionToolsMatch" }
        )
      end
      pos = at + 1
    end
  end
  local window_config = {
    relative = "editor",
    row = math.max(0, row),
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.border,
    focusable = false,
    zindex = 100,
  }
  if valid(win) then
    vim.api.nvim_win_set_config(win, window_config)
  else
    win = vim.api.nvim_open_win(buf, false, window_config)
    vim.wo[win].winhighlight =
      "Normal:CompletionToolsMenu,FloatBorder:CompletionToolsBorder,CursorLine:CompletionToolsSelected"
    vim.wo[win].wrap, vim.wo[win].scrolloff = false, 0
  end
  vim.wo[win].cursorline = selected ~= nil
  vim.api.nvim_win_set_cursor(win, { math.max(1, target - viewport + 1), 0 })
  geometry = { row = math.max(0, row), col = col, width = width, height = height }
end

function M.documentation(item, config)
  if not M.visible() or not geometry then
    return false
  end
  local lines = {}
  if item.detail and item.detail ~= "" then
    lines[#lines + 1] = "```"
    vim.list_extend(lines, vim.split(item.detail, "\n", { plain = true }))
    vim.list_extend(lines, { "```", "" })
  end
  local documentation = item.documentation
  local text = type(documentation) == "table" and documentation.value or documentation
  if type(text) == "string" then
    vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  end
  while lines[#lines] == "" do
    lines[#lines] = nil
  end
  if #lines == 0 then
    M.hide_documentation()
    return false
  end
  local opts = config.documentation
  local width = 12
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local right, left = vim.o.columns - geometry.col - geometry.width - 4, geometry.col - 2
  local available = math.max(right, left)
  if available < 12 then
    M.hide_documentation()
    return false
  end
  width = math.min(width, opts.max_width, available)
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  height = math.min(height, opts.max_height, vim.o.lines - math.max(vim.o.cmdheight, 1) - 3)
  local col = right >= width and geometry.col + geometry.width + 2 or geometry.col - width - 2
  local row = math.min(geometry.row, vim.o.lines - math.max(vim.o.cmdheight, 1) - height - 2)
  doc_buf = scratch(doc_buf, "markdown")
  vim.api.nvim_buf_set_lines(doc_buf, 0, -1, false, lines)
  local wc = {
    relative = "editor",
    row = math.max(0, row),
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.border,
    focusable = false,
    zindex = 101,
  }
  if valid(doc_win) then
    vim.api.nvim_win_set_config(doc_win, wc)
  else
    doc_win = vim.api.nvim_open_win(doc_buf, false, wc)
    vim.wo[doc_win].winhighlight = "Normal:CompletionToolsDoc,FloatBorder:CompletionToolsBorder"
    vim.wo[doc_win].wrap = true
  end
  return true
end

function M.scroll_documentation(delta)
  if not valid(doc_win) then
    return false
  end
  vim.api.nvim_win_call(doc_win, function()
    vim.cmd("normal! " .. math.abs(delta) .. (delta > 0 and "\5" or "\25"))
  end)
  return true
end

function M.dispose()
  M.hide()
  for _, id in ipairs({ buf or -1, doc_buf or -1 }) do
    if vim.api.nvim_buf_is_valid(id) then
      vim.api.nvim_buf_delete(id, { force = true })
    end
  end
  buf, doc_buf = nil, nil
end

return M
