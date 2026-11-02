local M = {}
local ns = vim.api.nvim_create_namespace("completion-tools-menu")
local doc_ns = vim.api.nvim_create_namespace("completion-tools-documentation")
local win, buf, doc_win, doc_buf, viewport = nil, nil, nil, nil, 1
local geometry, doc_item
local render = require("completion_tools.render")

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
function M.highlights()
  for name, target in pairs({
    CompletionToolsMenu = "Pmenu",
    CompletionToolsBorder = "FloatBorder",
    CompletionToolsSelected = "PmenuSel",
    CompletionToolsSource = "Comment",
    CompletionToolsDoc = "NormalFloat",
    CompletionToolsDocCode = "String",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
  -- Foreground-only syntax groups preserve the selected row's PmenuSel background.
  vim.api.nvim_set_hl(0, "CompletionToolsMatch", { default = true, bold = true, underline = true })
  vim.api.nvim_set_hl(0, "CompletionToolsDeprecated", { default = true, strikethrough = true })
  require("completion_tools.kinds").highlights()
end

function M.hide_documentation()
  close(doc_win)
  doc_win, doc_item = nil, nil
end
function M.hide()
  close(win)
  win, viewport, geometry = nil, 1, nil
  M.hide_documentation()
end
function M.visible()
  return valid(win) or false
end

local function placement(count, width, ctx, config)
  if vim.o.columns < 8 or vim.o.lines < 6 then
    return
  end
  local opts = config.menu
  local screen, cursor, input_top, input_bottom, anchor_col
  if ctx.mode == "cmdline" then
    local anchor
    if config.cmdline.get_anchor then
      local ok, value = pcall(config.cmdline.get_anchor, ctx)
      if
        ok
        and type(value) == "table"
        and type(value.row) == "number"
        and type(value.col) == "number"
        and type(value.height) == "number"
        and value.row >= 0
        and value.row % 1 == 0
        and value.col % 1 == 0
        and value.height % 1 == 0
        and value.row < vim.o.lines
        and value.height >= 1
      then
        anchor = value
      end
    end
    if anchor then
      input_top, input_bottom, anchor_col = anchor.row, anchor.row + anchor.height - 1, anchor.col
    else
      local rows =
        math.max(1, vim.o.cmdheight, math.ceil((1 + vim.fn.strdisplaywidth(ctx.line)) / vim.o.columns))
      input_top, input_bottom = math.max(0, vim.o.lines - rows), vim.o.lines - 1
      anchor_col = (1 + vim.fn.strdisplaywidth(ctx.before:sub(1, ctx.start_col))) % vim.o.columns
    end
    screen = {
      row = input_top + 1,
      col = anchor_col + 1,
    }
    cursor = screen
  else
    screen = vim.fn.screenpos(ctx.winid, ctx.row + 1, ctx.start_col + 1)
    cursor = ctx.start_col == ctx.col and screen or vim.fn.screenpos(ctx.winid, ctx.row + 1, ctx.col + 1)
    if cursor.row == 0 then
      return
    end
  end
  input_top, input_bottom = input_top or cursor.row - 1, input_bottom or cursor.row - 1
  -- Rows from screenpos are one-based; floating window rows are zero-based.
  -- Anchor vertically to the cursor, since the keyword can wrap onto earlier rows.
  local below = vim.o.lines - math.max(vim.o.cmdheight, 1) - input_bottom - 3
  local above = input_top - 2
  local height = math.min(count, opts.max_height, math.max(above, below))
  if height < 1 then
    return
  end
  width = math.min(width, opts.max_width, vim.o.columns - 4)
  local upwards = below < height
  -- Both the contents and the bottom border must end before the input row.
  local row = upwards and input_top - height - 2 or input_bottom + 1
  local start_col = screen.col > 0 and screen.col or cursor.col
  local col = math.max(0, math.min(start_col - 1, vim.o.columns - width - 2))
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
  local next_geometry = {
    row = math.max(0, row),
    col = col,
    width = width,
    height = height,
    upwards = upwards,
    input_row = cursor.row - 1,
    input_top = input_top,
    input_bottom = input_bottom,
    filetype = ctx.filetype,
  }
  return window_config, next_geometry
end

function M.render(items, selected, ctx, config)
  if #items == 0 or vim.o.columns < 8 or vim.o.lines < 6 then
    M.hide()
    return
  end
  local opts = config.menu
  local layout = render.prepare(items, opts, vim.o.columns - 4)
  local window_config, next_geometry = placement(#items, layout.width, ctx, config)
  if not window_config then
    M.hide()
    return
  end
  local height = window_config.height
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
    local line, marks = render.row(layout, i, items[i], ctx, opts)
    lines[#lines + 1], spans[#spans + 1] = line, marks
  end
  buf = scratch(buf, "completion-tools-menu")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, marks in ipairs(spans) do
    for _, span in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, span[1], {
        end_col = span[2],
        hl_group = span[3],
        priority = span[4],
      })
    end
  end
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
  local moved = not vim.deep_equal(geometry, next_geometry)
  geometry = next_geometry
  if moved and valid(doc_win) and doc_item then
    M.documentation(doc_item, config)
  end
end

-- Keep an old frame clear of the live input while its replacement is pending.
-- Moving the float does not rewrite candidate text, run matching, or create it.
function M.reposition(ctx, config)
  if not valid(win) or not geometry then
    return false
  end
  local wc, next_geometry = placement(vim.api.nvim_buf_line_count(buf), geometry.width, ctx, config)
  if not wc then
    M.hide()
    return false
  end
  if not vim.deep_equal(geometry, next_geometry) then
    vim.api.nvim_win_set_config(win, wc)
    geometry = next_geometry
    if valid(doc_win) and doc_item then
      M.documentation(doc_item, config)
    end
  end
  return true
end

function M.documentation(item, config)
  if not M.visible() or not geometry then
    return false
  end
  local documentation = require("completion_tools.documentation")
  local lines, ranges = documentation.build(item, geometry.filetype)
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
  local top, bottom = 0, vim.o.lines - math.max(vim.o.cmdheight, 1) - 1
  if geometry.upwards then
    bottom = math.min(bottom, geometry.input_top - 1)
  else
    top = geometry.input_bottom + 1
  end
  -- A tall document must remain on the same side of the input as the menu.
  height = math.min(height, opts.max_height, bottom - top - 1)
  if height < 1 then
    M.hide_documentation()
    return false
  end
  local col = right >= width and geometry.col + geometry.width + 2 or geometry.col - width - 2
  local row = math.max(top, math.min(geometry.row, bottom - height - 1))
  doc_buf = scratch(doc_buf, "markdown")
  vim.api.nvim_buf_set_lines(doc_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(doc_buf, doc_ns, 0, -1)
  documentation.highlight(doc_buf, doc_ns, lines, ranges, config.menu.highlight)
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
  doc_item = item
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
  require("completion_tools.highlight").clear()
  for _, id in ipairs({ buf or -1, doc_buf or -1 }) do
    if vim.api.nvim_buf_is_valid(id) then
      vim.api.nvim_buf_delete(id, { force = true })
    end
  end
  buf, doc_buf = nil, nil
end

return M
