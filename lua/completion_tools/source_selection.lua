local M = {}

local function buffer(ctx)
  return ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
end

function M.sources(config, ctx)
  local explicit = vim.b[buffer(ctx)].completion_tools_sources
  return vim.deepcopy(explicit or (config.defaults and config.defaults(ctx)) or config.default)
end

function M.active_sources(config, ctx)
  local index = vim.b[buffer(ctx)].completion_tools_source_index or 1
  local group = (config.groups or {})[index - 1]
  return group and vim.deepcopy(group.sources or group) or M.sources(config, ctx)
end

function M.cycle(config, direction, ctx)
  assert(type(direction) == "number" and direction % 1 == 0, "Source direction must be an integer")
  local buf = buffer(ctx)
  local groups = config.groups or {}
  local index = vim.b[buf].completion_tools_source_index or 1
  index = (index - 1 + direction) % (#groups + 1) + 1
  vim.b[buf].completion_tools_source_index = index

  local sources = M.active_sources(config, ctx)
  local group = groups[index - 1]
  if not group then
    vim.b[buf].completion_tools_source_group = nil
    return sources
  end

  local name = group.name or table.concat(sources, " + ")
  vim.b[buf].completion_tools_source_group = {
    name = name ~= "" and vim.fn.strtrans(name) or "Empty",
    sources = sources,
    switched = true,
  }
  return sources
end

--- Read the selected group for a completion request and optionally consume switch feedback.
---@private
function M._menu_group(ctx, override, explicit)
  if ctx and ctx.mode == "cmdline" then
    return
  end

  local vars = vim.b[buffer(ctx)]
  local group = vars.completion_tools_source_group
  if not group or (override and not vim.deep_equal(group.sources, override)) then
    return
  end

  local switched = explicit and group.switched
  if switched then
    group.switched = nil
    vars.completion_tools_source_group = group
  end

  return group.name, switched
end

function M.toggle_source(config, name, ctx)
  assert(config.providers[name], "Completion source is not configured: " .. name)
  local sources = M.sources(config, ctx)

  if vim.list_contains(sources, name) then
    sources = vim.tbl_filter(function(source)
      return source ~= name
    end, sources)
  else
    table.insert(sources, 1, name)
  end

  local buf = buffer(ctx)
  vim.b[buf].completion_tools_sources = sources
  vim.b[buf].completion_tools_source_index = 1
  vim.b[buf].completion_tools_source_group = nil

  return vim.deepcopy(sources)
end

function M.reset(ctx)
  local buf = buffer(ctx)
  vim.b[buf].completion_tools_sources, vim.b[buf].completion_tools_source_index = nil, nil
  vim.b[buf].completion_tools_source_group = nil
end

return M
