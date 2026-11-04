local M = {}
local text = require("completion_tools.text")
local kinds = require("completion_tools.kinds")
local highlight = require("completion_tools.highlight")
local source_names = {
  lsp = "LSP",
  buffer = "Buffer",
  path = "Path",
  snippets = "Snippets",
  cmdline = "Cmdline",
  dictionary = "Dict",
  spell = "Spell",
  copilot = "Copilot",
}

M.components = {
  kind_icon = true,
  label = true,
  kind = true,
  source = true,
  label_detail = true,
  label_description = true,
}

local function fields(entry, opts)
  local item = entry.item
  local name, icon, group = kinds.get(item.kind, opts.kind_icons)
  local label = text.clean(item.label, opts.max_label_bytes)
  local details = item.labelDetails or {}
  local detail = details.detail
  -- Keep display text separate from the CompletionItem used for acceptance.
  -- Older servers put a one-line signature in detail instead of labelDetails.
  if not detail and type(item.detail) == "string" and not item.detail:find("[\r\n]") then
    detail = item.detail
    if detail:sub(1, #label) == label then
      detail = detail:sub(#label + 1)
    elseif detail ~= "" then
      detail = "  " .. detail
    end
  end
  detail = text.clean(detail, opts.max_label_bytes)
  if detail ~= "" and label:sub(-#detail) == detail then
    detail = ""
  end
  local description = text.clean(details.description, opts.max_label_bytes)
  local file = item.kind == 17 or item.kind == 19 or entry.source_id == "path"
  if file then
    -- File metadata is a location, not a signature in the buffer's language.
    detail = vim.trim(detail)
    local function path(value)
      if value:sub(1, 1) == "/" or value:match("^~[/\\]") then
        return vim.fn.fnamemodify(value, ":~:.")
      end
      return value
    end
    detail, description = path(detail), path(description)
  end
  local metadata = description
  local separate_detail = false
  for _, group in ipairs(opts.columns) do
    separate_detail = separate_detail or vim.tbl_contains(group, "label_detail")
  end
  if file and opts.label_details and not separate_detail and detail ~= "" and detail ~= description then
    metadata = detail .. (description ~= "" and "  " .. description or "")
  end
  local code = label .. (opts.label_details and not file and detail or "")
  code = text.clean(code, opts.max_label_bytes)
  return {
    kind_icon = text.clean(icon, 32),
    label = code,
    kind = name,
    source = text.clean(source_names[entry.source_id] or entry.source_id, opts.max_label_bytes),
    label_detail = detail,
    label_description = metadata,
    file = file,
    code = code,
    label_bytes = #label,
    kind_group = group,
  }
end

-- Measure all retained candidates once so columns stay aligned while scrolling.
-- Highlighting/parsing is deferred until a row actually becomes visible.
function M.prepare(items, opts, available, previous)
  local rows, columns, seen = {}, {}, {}
  local retained = {}
  for _, column in ipairs(previous and previous.columns or {}) do
    retained[column.name] = column
  end
  for i, entry in ipairs(items) do
    rows[i] = fields(entry, opts)
  end
  local groups, explicit_description = {}, false
  for _, group in ipairs(opts.columns) do
    explicit_description = explicit_description or vim.tbl_contains(group, "label_description")
  end
  for _, group in ipairs(opts.columns) do
    groups[#groups + 1] = group
    if opts.label_details and not explicit_description and vim.tbl_contains(group, "label") then
      -- Reserve a real column for metadata, including in existing user layouts.
      groups[#groups + 1] = { "label_description", gap = 2, automatic = true }
    end
  end
  for _, group in ipairs(groups) do
    for j, name in ipairs(group) do
      if
        not (
          name == "kind_icon"
          and (
            opts.kind_icons == false
            or (
              package.loaded["theme_tools.icons"]
              and package.loaded["theme_tools.icons"].current() == "none"
            )
          )
        )
      then
        local width = 0
        for _, row in ipairs(rows) do
          width = math.max(width, vim.fn.strdisplaywidth(row[name]))
        end
        if width > 0 or not group.automatic or retained[name] then
          columns[#columns + 1] = {
            name = name,
            width = width,
            gap = #columns == 0 and 0
              or (group.automatic and 2 or j == 1 and opts.column_gap or group.gap or 1),
          }
          seen[name] = columns[#columns]
        end
      end
    end
  end
  local limit = math.min(available, opts.max_width)
  local padding = math.min(opts.padding, math.floor(limit / 2))
  if previous then
    -- Existing columns own their space for the lifetime of the menu. Grow into
    -- spare cells instead of moving every following column when results change.
    -- A smaller editor is allowed to reclaim space using the clipping below.
    local reserved = padding * 2
    for _, column in ipairs(columns) do
      local old = retained[column.name]
      reserved = reserved + (old and old.width + old.gap or 0)
    end
    local spare = math.max(0, limit - reserved)
    for _, column in ipairs(columns) do
      local old = retained[column.name]
      local width, gap = old and old.width or 0, old and old.gap or 0
      local grow_gap = math.min(spare, math.max(0, column.gap - gap))
      spare, column.gap = spare - grow_gap, gap + grow_gap
      local grow_width = math.min(spare, math.max(0, column.width - width))
      spare, column.width = spare - grow_width, width + grow_width
    end
  end
  local natural = padding * 2
  for _, column in ipairs(columns) do
    natural = natural + column.width + column.gap
  end
  local width = math.min(limit, math.max(opts.min_width, natural))
  local excess = natural - width
  -- Spend excess metadata width before truncating the candidate itself, while
  -- retaining a small location hint whenever the terminal has room for both.
  if seen.label_description and excess > 0 then
    local take = math.min(excess, math.max(0, seen.label_description.width - 12))
    seen.label_description.width, excess = seen.label_description.width - take, excess - take
  end
  if seen.label and excess > 0 then
    local take = math.min(excess, math.max(0, seen.label.width - 8))
    seen.label.width, excess = seen.label.width - take, excess - take
  end
  for _, name in ipairs({ "label_description", "label_detail", "source", "kind", "kind_icon", "label" }) do
    local column = seen[name]
    if column and excess > 0 then
      local take = math.min(excess, column.width)
      column.width, excess = column.width - take, excess - take
    end
  end
  for i = #columns, 1, -1 do
    if excess > 0 then
      local take = math.min(excess, columns[i].gap)
      columns[i].gap, excess = columns[i].gap - take, excess - take
    end
  end
  -- Give spare space to the label, keeping auxiliary columns aligned at the right.
  if natural < width and seen.label then
    seen.label.width = seen.label.width + width - natural
  end
  return { rows = rows, columns = columns, width = width, padding = padding }
end

local function boundary(value, at)
  local byte = value:byte(at + 1)
  return not byte or byte < 128 or byte >= 192
end
local function priority(value)
  value = tonumber(value)
  if not value or value ~= value then
    return 190
  end
  return math.floor(math.max(0, math.min(65535, value)))
end

function M.row(layout, index, entry, ctx, opts)
  local row, line, spans = layout.rows[index], string.rep(" ", layout.padding), {}
  local function add(first, last, group, priority)
    if last > first then
      spans[#spans + 1] = { first, last, group, priority or 110 }
    end
  end
  for _, column in ipairs(layout.columns) do
    line = line .. string.rep(" ", column.gap)
    local start = #line
    local truncate = row.file
        and (column.name == "label_detail" or column.name == "label_description")
        and text.truncate_path
      or text.truncate
    local value, retained = truncate(row[column.name], column.width)
    line = line .. value .. string.rep(" ", math.max(0, column.width - vim.fn.strdisplaywidth(value)))
    if column.name == "kind" or column.name == "kind_icon" then
      add(start, start + #value, row.kind_group)
    elseif
      column.name == "source"
      or column.name == "label_description"
      or (row.file and column.name == "label_detail")
    then
      add(start, start + #value, "CompletionToolsSource")
    elseif column.name == "label" or column.name == "label_detail" then
      local code = column.name == "label" and row.code or row.label_detail
      for _, span in
        ipairs(
          highlight.get(code, column.name == "label" and row.label_bytes or 0, entry, ctx, opts.highlight)
        )
      do
        if
          type(span) == "table"
          and type(span[1]) == "number"
          and type(span[2]) == "number"
          and type(span[3]) == "string"
          and span[3] ~= ""
        then
          local first, last = math.max(0, span[1]), math.min(retained, span[2])
          if first % 1 == 0 and last % 1 == 0 and boundary(code, first) and boundary(code, last) then
            add(start + first, start + last, span[3], priority(span[4]))
          end
        end
      end
      if column.name == "label" then
        local query, pos = (ctx.before or ""):sub((entry.start_col or 0) + 1), 1
        -- Match whole UTF-8 characters, with byte positions for extmarks.
        for char in query:gmatch(text.characters) do
          local at =
            row.label:sub(1, math.min(retained, row.label_bytes)):lower():find(char:lower(), pos, true)
          if not at then
            break
          end
          add(start + at - 1, start + at - 1 + #char, "CompletionToolsMatch", 200)
          pos = at + #char
        end
        if entry.item.deprecated or vim.tbl_contains(entry.item.tags or {}, 1) then
          add(start, start + math.min(retained, row.label_bytes), "CompletionToolsDeprecated", 210)
        end
      end
    end
    -- Keep every Copilot field purple while retaining match/deprecation styles
    -- and the selected row's background. Other Text sources retain their colors.
    if entry.source_id == "copilot" then
      add(start, start + #value, "CompletionToolsCopilot", 195)
    end
  end
  return line .. string.rep(" ", math.max(0, layout.width - vim.fn.strdisplaywidth(line))), spans
end

return M
