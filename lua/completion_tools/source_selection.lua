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
  if index == 1 then
    return M.sources(config, ctx)
  end
  return vim.deepcopy((config.groups or {})[index - 1] or M.sources(config, ctx))
end
function M.cycle(config, direction, ctx)
  assert(type(direction) == "number" and direction % 1 == 0, "Source direction must be an integer")
  local buf = buffer(ctx)
  local count = #(config.groups or {}) + 1
  local index = vim.b[buf].completion_tools_source_index or 1
  vim.b[buf].completion_tools_source_index = (index - 1 + direction) % count + 1
  return M.active_sources(config, ctx)
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
  return vim.deepcopy(sources)
end
function M.reset(ctx)
  local buf = buffer(ctx)
  vim.b[buf].completion_tools_sources, vim.b[buf].completion_tools_source_index = nil, nil
end
return M
