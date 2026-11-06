local M = {}
local ns = vim.api.nvim_create_namespace("completion-tools-menu")
local doc_ns = vim.api.nvim_create_namespace("completion-tools-documentation")
local win, buf, doc_win, doc_buf, viewport = nil, nil, nil, nil, 1
local geometry, doc_item, menu_status
local doc_view, doc_token
local frame_items, frame_selected
local frame_layout, frame_lines, frame_spans, frame_config
local shrink_timer, shrink_token
local status_timer, status_token, status_frame = nil, nil, 1
local render = require("completion_tools.render")

local function cancel_shrink()
  shrink_token = nil
  if shrink_timer and not shrink_timer:is_closing() then
    shrink_timer:stop()
    shrink_timer:close()
  end
  shrink_timer = nil
end

local function valid(id)
  return id and vim.api.nvim_win_is_valid(id)
end
local function stop_status_animation()
  status_token = nil
  if status_timer and not status_timer:is_closing() then
    status_timer:stop()
    status_timer:close()
  end
  status_timer, status_frame = nil, 1
end
local function status_text()
  if not menu_status then
    return ""
  end
  local frame = menu_status.frames and menu_status.frames[status_frame] or nil
  return menu_status.text .. (frame and " " .. frame or "")
end
local function status_footer(width)
  if not menu_status then
    return ""
  end
  local label = require("completion_tools.text").truncate(status_text(), width - 2)
  return { { " " .. label .. " ", menu_status.highlight } }
end
local function sync_status_animation()
  if not valid(win) or not menu_status or not menu_status.frames then
    stop_status_animation()
    return
  end
  if status_timer then
    return
  end
  local token = {}
  status_token = token
  status_timer = vim.uv.new_timer()
  status_timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if status_token ~= token then
        return
      end
      if not valid(win) or not menu_status or not menu_status.frames then
        stop_status_animation()
        return
      end
      status_frame = status_frame % #menu_status.frames + 1
      local footer = status_footer(vim.api.nvim_win_get_width(win))
      -- Animation changes only the border, leaving text, selection and geometry intact.
      vim.api.nvim_win_set_config(win, { footer = footer, footer_pos = "right" })
      frame_config.footer = footer
    end)
  )
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
    CompletionToolsSelected = "PmenuSel",
    CompletionToolsSource = "Comment",
    CompletionToolsDocCode = "String",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
  -- Foreground-only syntax groups preserve the selected row's PmenuSel background.
  require("completion_tools.theme").highlights()
  vim.api.nvim_set_hl(0, "CompletionToolsMatch", { default = true, bold = true, underline = true })
  vim.api.nvim_set_hl(0, "CompletionToolsDeprecated", { default = true, strikethrough = true })
  vim.api.nvim_set_hl(0, "CompletionToolsDocItalic", { default = true, italic = true })
  vim.api.nvim_set_hl(0, "CompletionToolsDocBold", { default = true, bold = true })
  vim.api.nvim_set_hl(0, "CompletionToolsDocBoldItalic", { default = true, bold = true, italic = true })
  require("completion_tools.kinds").highlights()
end

local function close_doc_view()
  doc_token = nil
  if doc_view then
    doc_view:close()
    doc_view = nil
  end
end
function M.hide_documentation()
  close_doc_view()
  close(doc_win)
  doc_win, doc_item = nil, nil
end
function M.set_status(status)
  menu_status = status
  sync_status_animation()
end
function M.hide()
  stop_status_animation()
  menu_status = nil
  cancel_shrink()
  close(win)
  win, viewport, geometry = nil, 1, nil
  frame_items, frame_selected = nil, nil
  frame_layout, frame_lines, frame_spans, frame_config = nil, nil, nil, nil
  M.hide_documentation()
end
function M.visible()
  return valid(win) or false
end
function M.is_inverse()
  return M.visible() and geometry and geometry.inverse or false
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
  -- Choose a side for the tallest menu before any asynchronous results arrive.
  -- Prefer below when it fits; otherwise use the side with more room.
  local upwards = below < opts.max_height and above > below
  local height = math.min(count, opts.max_height, upwards and above or below)
  if height < 1 then
    return
  end
  if menu_status then
    width = math.max(width, vim.fn.strdisplaywidth(status_text()) + 2)
  end
  width = math.min(width, opts.max_width, vim.o.columns - 4)
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
    footer = status_footer(width),
    footer_pos = "right",
  }
  if menu_status and (opts.border == "none" or opts.border == "shadow") then
    window_config.border = { "", "", "", "", "", "─", "", "" }
  end
  local next_geometry = {
    row = math.max(0, row),
    col = col,
    width = width,
    height = height,
    upwards = upwards,
    inverse = opts.inverse == true or (opts.inverse == "auto" and upwards),
    input_row = cursor.row - 1,
    input_top = input_top,
    input_bottom = input_bottom,
    filetype = ctx.filetype,
  }
  return window_config, next_geometry
end

local function paint(items, selected, ctx, config, layout, window_config, next_geometry)
  local opts = config.menu
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
  for row = 1, height do
    local i = viewport + (next_geometry.inverse and height - row or row - 1)
    local line, marks = "", {}
    if items[i] then
      line, marks = render.row(layout, i, items[i], ctx, opts)
    end
    lines[#lines + 1], spans[#spans + 1] = line, marks
  end
  local old_buf = buf
  buf = scratch(buf, "completion-tools-menu")
  local replace = buf ~= old_buf or not frame_lines or #frame_lines ~= #lines
  if replace then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  for i, marks in ipairs(spans) do
    local changed = replace or frame_lines[i] ~= lines[i]
    if changed and not replace then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { lines[i] })
    end
    if changed or not vim.deep_equal(frame_spans[i], marks) then
      if not replace then
        vim.api.nvim_buf_clear_namespace(buf, ns, i - 1, i)
      end
      for _, span in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, span[1], {
          end_col = span[2],
          hl_group = span[3],
          priority = span[4],
        })
      end
    end
  end
  if valid(win) then
    if not vim.deep_equal(frame_config, window_config) then
      vim.api.nvim_win_set_config(win, window_config)
    end
  else
    win = vim.api.nvim_open_win(buf, false, window_config)
    vim.wo[win].winhighlight = "Normal:CompletionToolsMenu,FloatBorder:CompletionToolsBorder,CursorLine:CompletionToolsSelected"
      .. ",Search:None,IncSearch:None,CurSearch:None"
    vim.wo[win].wrap, vim.wo[win].scrolloff = false, 0
  end
  vim.wo[win].cursorline = selected ~= nil
  local selected_row = target - viewport + 1
  if next_geometry.inverse then
    selected_row = height - selected_row + 1
  end
  vim.api.nvim_win_set_cursor(win, { math.max(1, selected_row), 0 })
  local moved = not vim.deep_equal(geometry, next_geometry)
  geometry = next_geometry
  frame_items, frame_selected = items, selected
  frame_layout, frame_lines, frame_spans, frame_config = layout, lines, spans, window_config
  sync_status_animation()
  if moved and valid(doc_win) and doc_item then
    M.documentation(doc_item, config)
  end
  if ctx.mode == "cmdline" then
    if ctx.cmdtype == "/" or ctx.cmdtype == "?" then
      -- Ask the native input loop to repaint the unchanged search and floats
      -- together. A direct screen flush drops incsearch's current-match color.
      vim.fn.setcmdline(vim.fn.getcmdline(), vim.fn.getcmdpos())
      if vim.fn.has("nvim-0.12") == 0 then
        -- 0.11 does not process setcmdline() as a native input change. Its
        -- redraw path restores incsearch highlighting after flushing floats.
        vim.cmd.redraw()
      end
    else
      -- Native command-line input can defer float painting until another key.
      vim.cmd.redraw()
    end
  end
end

local function draw(items, selected, ctx, config, settled)
  cancel_shrink()
  if #items == 0 or vim.o.columns < 8 or vim.o.lines < 6 then
    M.hide()
    return
  end
  local opts = config.menu
  local layout = render.prepare(items, opts, vim.o.columns - 4, frame_layout)
  local window_config, next_geometry = placement(#items, layout.width, ctx, config)
  if not window_config then
    M.hide()
    return
  end
  if
    not settled
    and valid(win)
    and geometry
    and window_config.height < geometry.height
    and opts.shrink_delay_ms > 0
  then
    -- Replace candidate text immediately, retaining only the old window height.
    window_config, next_geometry = placement(math.max(#items, geometry.height), layout.width, ctx, config)
    if window_config.height > #items then
      local token = {}
      shrink_token = token
      shrink_timer = vim.defer_fn(function()
        if shrink_token ~= token then
          return
        end
        shrink_timer, shrink_token = nil, nil
        local context = require("completion_tools.context")
        if valid(win) and context.same(ctx, context.get(config)) then
          draw(items, selected, ctx, config, true)
        end
      end, opts.shrink_delay_ms)
    end
  end
  paint(items, selected, ctx, config, layout, window_config, next_geometry)
end

function M.refresh_icons(items, selected, ctx, config)
  frame_layout = nil
  M.render(items, selected, ctx, config)
end

function M.render(items, selected, ctx, config)
  draw(items, selected, ctx, config, false)
end

-- Keep an old frame clear of the live input while its replacement is pending.
-- Repaint the retained items only when the visible rows or their order change.
function M.reposition(ctx, config)
  -- New input invalidates a shrink even before its providers return a result.
  cancel_shrink()
  if not valid(win) or not geometry then
    return false
  end
  local wc, next_geometry = placement(vim.api.nvim_buf_line_count(buf), geometry.width, ctx, config)
  if not wc then
    M.hide()
    return false
  end
  if next_geometry.inverse ~= geometry.inverse or next_geometry.height ~= geometry.height then
    local layout = render.prepare(frame_items, config.menu, vim.o.columns - 4, frame_layout)
    paint(frame_items, frame_selected, ctx, config, layout, wc, next_geometry)
    return true
  end
  if not vim.deep_equal(frame_config, wc) then
    vim.api.nvim_win_set_config(win, wc)
    frame_config = wc
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
  local lines, ranges, visible = documentation.build(item, geometry.filetype)
  if #lines == 0 then
    M.hide_documentation()
    return false
  end
  local opts = config.documentation
  local preview = item._path_preview
  local media = preview and preview.kind == "media"
  local width = 12
  -- Conceal does not reflow wrapped buffer text. Reserve raw columns for prose;
  -- virtual separators occupy exactly one row regardless of their Markdown length.
  for row, line in ipairs(lines) do
    width = math.max(width, visible[row] == "" and 0 or vim.fn.strdisplaywidth(line))
  end
  local right, left = vim.o.columns - geometry.col - geometry.width - 4, geometry.col - 2
  local available = math.max(right, left)
  if available < 12 then
    M.hide_documentation()
    return false
  end
  width = math.min(width, opts.max_width, available)
  if media then
    width = math.min(opts.max_width, available)
  end
  local height = 0
  for row, line in ipairs(lines) do
    local cells = visible[row] == "" and 0 or vim.fn.strdisplaywidth(line)
    height = height + math.max(1, math.ceil(cells / width))
  end
  local top, bottom = 0, vim.o.lines - math.max(vim.o.cmdheight, 1) - 1
  if geometry.upwards then
    bottom = math.min(bottom, geometry.input_top - 1)
  else
    top = geometry.input_bottom + 1
  end
  -- A tall document must remain on the same side of the input as the menu.
  if media then
    height = opts.max_height
  end
  height = math.min(height, opts.max_height, bottom - top - 1)
  if height < 1 then
    M.hide_documentation()
    return false
  end
  local col = right >= width and geometry.col + geometry.width + 2 or geometry.col - width - 2
  local row = math.max(top, math.min(geometry.row, bottom - height - 1))
  local reuse = media and doc_token and doc_item == item and valid(doc_win)
  if not reuse then
    close_doc_view()
  end
  doc_buf = scratch(doc_buf, "markdown")
  if not reuse then
    vim.bo[doc_buf].syntax = ""
    vim.api.nvim_buf_set_lines(doc_buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(doc_buf, doc_ns, 0, -1)
    documentation.highlight(doc_buf, doc_ns, lines, ranges, config.menu.highlight, width)
  end
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
    vim.wo[doc_win].winhighlight = "Normal:CompletionToolsDoc,FloatBorder:CompletionToolsDocBorder"
      .. ",Search:None,IncSearch:None,CurSearch:None"
    vim.wo[doc_win].wrap = true
  end
  vim.wo[doc_win].wrap = not media
  -- File contents are literal even when the reused Markdown pane has syntax
  -- conceal rules from an earlier LSP document.
  vim.wo[doc_win].conceallevel = preview and 0 or 2
  vim.wo[doc_win].concealcursor = "nvic"
  if not reuse then
    vim.api.nvim_win_set_cursor(doc_win, { 1, 0 })
  end
  doc_item = item
  if media then
    if reuse then
      if doc_view then
        doc_view:resize()
      end
    else
      local token, target_buf, target_win = {}, doc_buf, doc_win
      doc_token = token
      doc_view = require("completion_tools.path_preview").render(preview, target_buf, target_win, function()
        return doc_token == token and valid(target_win) and vim.api.nvim_win_get_buf(target_win) == target_buf
      end)
    end
  end
  return true
end

function M.scroll_documentation(delta)
  if not valid(doc_win) or doc_view then
    return false
  end
  vim.api.nvim_win_call(doc_win, function()
    vim.cmd("normal! " .. math.abs(delta) .. (delta > 0 and "\5" or "\25"))
  end)
  return true
end

function M.dispose()
  M.hide()
  require("completion_tools.theme").dispose()
  require("completion_tools.highlight").clear()
  for _, id in ipairs({ buf or -1, doc_buf or -1 }) do
    if vim.api.nvim_buf_is_valid(id) then
      vim.api.nvim_buf_delete(id, { force = true })
    end
  end
  buf, doc_buf = nil, nil
end

return M
