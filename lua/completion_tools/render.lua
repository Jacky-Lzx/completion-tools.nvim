local M = {}
local CompletionItemKind = require("vim.lsp.protocol").CompletionItemKind
local base_text = require("base_tools.text")
local text = require("completion_tools.text")
local kinds = require("completion_tools.kinds")
local highlight = require("completion_tools.highlight")
local keep_path_suffix = { side = "start" }

M.components = {
  kind_icon = true,
  label = true,
  kind = true,
  source = true,
  label_detail = true,
  label_description = true,
}

--- Prepare the fields displayed in a completion menu row.
---@param entry completion_tools.Entry Candidate and its source metadata.
---@param opts completion_tools.MenuOptions Menu options after defaults are applied.
---@param separate_detail boolean Whether the layout has an explicit detail column.
local function fields(entry, opts, separate_detail)
  local item = entry.item
  local name, icon, kind_group = kinds.get(item.kind, opts.kind_icons)
  local label = text.clean(item.label, opts.max_label_bytes)
  local details = item.labelDetails or {}
  local detail = details.detail
  local detail_code = detail ~= nil

  -- Keep display text separate from the CompletionItem used for acceptance.
  -- Older servers put a one-line signature in detail instead of labelDetails.
  local item_detail = item.detail
  if not detail and type(item_detail) == "string" and not item_detail:find("[\r\n]") then
    detail = item_detail
    -- Kind describes the candidate, not its detail: even functions can carry
    -- prose here. Require signature syntax rather than a callable kind.
    detail_code = detail:find("^%s*[%(:<{%[]") ~= nil
      or detail:find("^%s*function%s+[%w_.:]+%s*%(") ~= nil
      or detail:find("^%s*fn%s+[%w_]+%s*%(") ~= nil
    if detail:sub(1, #label) == label then
      detail = detail:sub(#label + 1)
      detail_code = detail_code or detail:find("^%s*[%(:<{%[]") ~= nil
    elseif detail ~= "" then
      detail = "  " .. detail
    end
  end

  detail = text.clean(detail, opts.max_label_bytes)
  if detail ~= "" and label:sub(-#detail) == detail then
    detail = ""
  end

  local description = text.clean(details.description, opts.max_label_bytes)
  local file = kinds.is_path(item.kind, entry.source_id)
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
  if file and opts.label_details and not separate_detail and detail ~= "" and detail ~= description then
    metadata = detail .. (description ~= "" and "  " .. description or "")
  end

  return {
    kind_icon = text.clean(icon, 32),
    label = text.clean(label .. (opts.label_details and not file and detail or ""), opts.max_label_bytes),
    kind = name,
    source = text.clean(entry.source_name or entry.source_id, opts.max_label_bytes),
    label_detail = detail,
    detail_code = detail_code,
    label_description = metadata,
    file = file,
    label_bytes = #label,
    kind_group = kind_group,
  }
end

-- Reserve the existing widths and gaps before allocating extra space.
local function retain_column_widths(columns, retained, available)
  local reserved = 0
  for _, column in ipairs(columns) do
    local old = retained[column.name]
    reserved = reserved + (old and old.width + old.gap or 0)
  end

  local spare = math.max(0, available - reserved)
  for _, column in ipairs(columns) do
    local old = retained[column.name]
    local width, gap = old and old.width or 0, old and old.gap or 0
    local grow_gap = math.min(spare, math.max(0, column.gap - gap))
    spare, column.gap = spare - grow_gap, gap + grow_gap
    local grow_width = math.min(spare, math.max(0, column.width - width))
    spare, column.width = spare - grow_width, width + grow_width
  end
end

local function shrink_columns(columns, columns_by_name, excess)
  -- Reclaim space from metadata first, keeping a location hint when possible.
  local description = columns_by_name.label_description
  if description then
    local take = math.min(excess, math.max(0, description.width - 12))
    description.width, excess = description.width - take, excess - take
  end

  local label = columns_by_name.label
  if label and excess > 0 then
    local take = math.min(excess, math.max(0, label.width - 8))
    label.width, excess = label.width - take, excess - take
  end

  for _, name in ipairs({ "label_description", "label_detail", "source", "kind", "kind_icon", "label" }) do
    local column = columns_by_name[name]
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
end

---@class completion_tools.MenuLayout
---@field rows table[] Prepared display fields in candidate order.
---@field columns { name: string, width: integer, gap: integer }[] Ordered columns with widths and preceding gaps in display cells.
---@field width integer Total menu width in display cells, including padding.
---@field padding integer Padding on each side in display cells.

--- Measure all retained candidates once so columns stay aligned while scrolling.
--- Highlighting is deferred until a row becomes visible.
---@param items completion_tools.Entry[] Candidates in menu order.
---@param opts completion_tools.MenuOptions Menu options after defaults are applied.
---@param available integer Available width in display cells.
---@param previous? completion_tools.MenuLayout Previous layout used to keep column widths stable during the same menu session.
---@return completion_tools.MenuLayout layout The prepared rows, column widths and total menu width.
function M.prepare(items, opts, available, previous)
  local rows, columns, columns_by_name = {}, {}, {}
  local retained = {}
  for _, column in ipairs(previous and previous.columns or {}) do
    retained[column.name] = column
  end

  local groups, explicit_description, separate_detail = {}, false, false
  for _, group in ipairs(opts.columns) do
    explicit_description = explicit_description or vim.tbl_contains(group, "label_description")
    separate_detail = separate_detail or vim.tbl_contains(group, "label_detail")
  end

  for i, entry in ipairs(items) do
    rows[i] = fields(entry, opts, separate_detail)
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
            or (package.loaded["theme_tools.icons"] and package.loaded["theme_tools.icons"].current() == "none")
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
            gap = #columns == 0 and 0 or (group.automatic and 2 or j == 1 and opts.column_gap or group.gap or 1),
          }
          columns_by_name[name] = columns[#columns]
        end
      end
    end
  end

  local limit = math.min(available, opts.max_width)
  local padding = math.min(opts.padding, math.floor(limit / 2))
  if previous then
    retain_column_widths(columns, retained, limit - padding * 2)
  end

  local natural = padding * 2
  for _, column in ipairs(columns) do
    natural = natural + column.width + column.gap
  end

  local width = math.min(limit, math.max(opts.min_width, natural))
  if natural > width then
    shrink_columns(columns, columns_by_name, natural - width)
  elseif natural < width and columns_by_name.label then
    -- Give spare space to the label, keeping auxiliary columns aligned at the right.
    columns_by_name.label.width = columns_by_name.label.width + width - natural
  end

  return { rows = rows, columns = columns, width = width, padding = padding }
end

local function boundary(value, at)
  local byte = value:byte(at + 1)
  return not byte or byte < 128 or byte >= 192
end

local function normalize_priority(value)
  value = tonumber(value)
  if not value or value ~= value then
    return 190
  end
  return math.floor(math.max(0, math.min(65535, value)))
end

local function language(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function syntax_languages(item, ctx, file)
  local syntax = item._syntax
  if type(syntax) == "table" then
    return language(syntax.label), language(syntax.detail)
  end

  local explicit = language(syntax)
  if explicit then
    return explicit, explicit
  end

  if syntax == false or ctx.completion_syntax == false or file then
    return nil, nil
  end

  local filetype = ctx.completion_syntax or ctx.filetype or ""
  if item.kind == nil or item.kind == CompletionItemKind.Text then
    return nil, filetype
  end

  return filetype, filetype
end

function M.row(layout, index, entry, ctx, opts)
  local row, line, spans = layout.rows[index], string.rep(" ", layout.padding), {}

  local function add(first, last, group, priority)
    if last > first then
      spans[#spans + 1] = { first, last, group, priority or 110 }
    end
  end

  local function add_spans(marks, code, start, first, last)
    for _, span in ipairs(marks) do
      if
        type(span) == "table"
        and type(span[1]) == "number"
        and type(span[2]) == "number"
        and type(span[3]) == "string"
        and span[3] ~= ""
      then
        local left, right = math.max(first, span[1]), math.min(last, span[2])
        if left % 1 == 0 and right % 1 == 0 and boundary(code, left) and boundary(code, right) then
          add(start + left, start + right, span[3], normalize_priority(span[4]))
        end
      end
    end
  end

  local function add_syntax(code, filetype, start, first, last)
    if filetype and last > first then
      add_spans(highlight.get(code, filetype, opts.highlight), code, start, first, last)
    end
  end

  local label_language, detail_language = syntax_languages(entry.item, ctx, row.file)
  local kind_group = row.kind_group
  if opts.highlight.enabled and opts.kind_icons == false then
    local _, _, group = kinds.get(entry.item.kind)
    kind_group = group
  end

  local function add_label_highlights(code, start, last, label_bytes, label_ft, detail_ft)
    local label_end = math.min(label_bytes, last)
    add(start, start + (detail_ft and label_end or last), kind_group)

    if label_ft == detail_ft or last == label_end then
      add_syntax(code, label_ft, start, 0, last)
    elseif label_ft and detail_ft then
      add_syntax(code:sub(1, label_end), label_ft, start, 0, label_end)
      add_syntax(code:sub(label_end + 1), detail_ft, start + label_end, 0, last - label_end)
    else
      -- Keep the full signature as parser context and clip colors to the enabled field.
      add_syntax(code, label_ft, start, 0, label_end)
      add_syntax(code, detail_ft, start, label_end, last)
    end
  end

  for _, column in ipairs(layout.columns) do
    line = line .. string.rep(" ", column.gap)
    local start = #line
    local path_metadata = row.file and (column.name == "label_detail" or column.name == "label_description")
    local value, _, retained = base_text.clip(row[column.name], column.width, path_metadata and keep_path_suffix or nil)
    line = line .. value .. string.rep(" ", math.max(0, column.width - vim.fn.strdisplaywidth(value)))

    if column.name == "kind" or column.name == "kind_icon" then
      add(start, start + #value, row.kind_group)
    elseif
      column.name == "source"
      or column.name == "label_description"
      or ((row.file or not row.detail_code) and column.name == "label_detail")
    then
      add(start, start + #value, "CompletionToolsSource")
    elseif column.name == "label" or column.name == "label_detail" then
      local code = row[column.name]
      if column.name == "label" and not row.detail_code then
        add(start + row.label_bytes, start + #value, "CompletionToolsSource")
        code = code:sub(1, row.label_bytes)
      end

      if opts.highlight.enabled then
        local last = math.min(retained, #code)
        if column.name == "label" then
          add_label_highlights(code, start, last, row.label_bytes, label_language, detail_language)
        elseif detail_language then
          add_syntax(code, detail_language, start, 0, last)
        else
          add(start, start + last, kind_group)
        end

        if opts.highlight.custom then
          local ok, extra = pcall(opts.highlight.custom, entry, ctx, code)
          if ok and type(extra) == "table" then
            add_spans(extra, code, start, 0, last)
          end
        end
      end

      if column.name == "label" then
        local query, pos = (ctx.before or ""):sub((entry.start_col or 0) + 1), 1
        local label_end = math.min(retained, row.label_bytes)
        local visible_label = row.label:sub(1, label_end):lower()
        -- Match whole UTF-8 characters, with byte positions for extmarks.
        for char in query:gmatch(text.characters) do
          local at = visible_label:find(char:lower(), pos, true)
          if not at then
            break
          end

          add(start + at - 1, start + at - 1 + #char, "CompletionToolsMatch", 200)
          pos = at + #char
        end

        if entry.item.deprecated or vim.tbl_contains(entry.item.tags or {}, 1) then
          add(start, start + label_end, "CompletionToolsDeprecated", 210)
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
