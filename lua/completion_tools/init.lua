local M = {}
local context = require("completion_tools.context")
local events = require("completion_tools.events")
local ui = require("completion_tools.ui")
local state = {
  generation = 0,
  items = {},
  providers = {},
  builtin_display_names = {},
  cache = {},
  groups = {},
  retained = {},
  selected = nil,
  selection_manual = false,
  config = nil,
  context = nil,
  disposed = true,
}

local function report(message)
  vim.schedule(function()
    vim.notify("completion-tools: " .. tostring(message), vim.log.levels.ERROR)
  end)
end

local function enabled()
  local value = state.config and state.config.enabled
  return not state.disposed
    and (type(value) == "function" and value() or value == true)
    and vim.fn.reg_recording() == ""
    and vim.fn.reg_executing() == ""
    and not vim.o.paste
end

local function current()
  return state.config and context.get(state.config) or nil
end

local menu = require("completion_tools.menu").new(state, current, report)
local requests = require("completion_tools.request").new(state, {
  current = current,
  enabled = enabled,
  hide = function(reason)
    return M.hide(reason)
  end,
  report = report,
}, menu)

M.show = requests.show
M.is_menu_visible = menu.visible
M.get_items = menu.get_items
M.get_selected_item = menu.get_selected_item
M.select_next = menu.select_next
M.select_prev = menu.select_prev
M.show_documentation = menu.show_documentation
M.scroll_documentation_up = menu.scroll_documentation_up
M.scroll_documentation_down = menu.scroll_documentation_down

local dispose_runtime

local function apply_config(config, timer)
  dispose_runtime()
  state.config, state.disposed = config, false
  state.diagnostics = require("completion_tools.diagnostics").new()
  state.run, state.reason, state.last_request_reason = nil, "idle", nil
  state.dispose_command = require("completion_tools.diagnostics").command()
  state.ranking = require("completion_tools.ranking").new(config.ranking)
  -- setup may itself run inside Lazy's first InsertEnter callback.
  state.edit_buf, state.edit_tick = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_changedtick(0)
  requests.setup(timer.new())
  menu.setup()

  for _, id in ipairs({ "lsp", "buffer", "path", "snippets", "cmdline", "dictionary", "spell", "copilot" }) do
    local provider = require("completion_tools.sources." .. id).new(config[id] or {}, function()
      if state.context and state.context.bufnr == vim.api.nvim_get_current_buf() then
        local same = context.same(state.context, current())
        if same or config.auto_show then
          requests.start(same and state.manual or false, same and state.source_ids or nil)
        else
          M.hide()
        end
      end
    end)

    state.providers[id] = provider
    state.builtin_display_names[id] = provider.display_name
  end

  for id, provider in pairs(config.providers) do
    if provider.complete then
      M.register_source(id, provider)
    elseif provider.module then
      local factory = require(provider.module)
      M.register_source(id, factory.new and factory.new(provider.opts or {}) or factory)
    end
  end

  local function warmup(buf)
    if
      type(config.sources) ~= "table"
      or not vim.list_contains(config.sources, "buffer")
      or (config.providers.buffer or {}).enabled == false
    then
      return
    end

    local provider = state.providers.buffer
    if provider and provider.warmup then
      provider.warmup(buf)
    end
  end

  ui.highlights()

  events.setup(state, {
    current = current,
    queue = requests.queue,
    hide = M.hide,
    watch = requests.watch,
    warmup = warmup,
    update_menu_status = menu.update_status,
    refresh_cmdline = M.refresh_cmdline,
    dispose = M.dispose,
  })
  require("completion_tools.keymap").setup(config)
  warmup(vim.api.nvim_get_current_buf())
  requests.watch(vim.api.nvim_get_current_buf())
end

function M.setup(opts)
  if vim.fn.has("nvim-0.12") ~= 1 then
    error("completion-tools requires Neovim 0.12+")
  end

  assert(opts == nil or type(opts) == "table", "completion-tools.nvim: setup expects a table")
  local config = require("completion_tools.config")
  local timer = require("base_tools.timer")
  local store = config.instance()
  store:commit(store:resolve(opts), function(candidate)
    apply_config(config.compile(candidate), timer)
  end)
  return M
end

function M.get_config(...)
  return require("completion_tools.config").instance():get(...)
end

function M.validate_config(path, value)
  require("completion_tools.config").instance():validate(path, value)
end

-- External command-line renderers can call this after their geometry settles.
-- Only an existing completion session is refreshed; layout events cannot open
-- an idle command line's menu.
function M.refresh_cmdline()
  if not state.context or state.context.mode ~= "cmdline" or not menu.visible() then
    return false
  end

  local ctx = current()
  if not ctx then
    return M.hide()
  end

  menu.redraw_cmdline(ctx)

  if not context.same(ctx, state.context) then
    if state.config.cmdline.auto_show then
      requests.queue()
    else
      M.hide()
    end
  end

  return true
end

function M._cmdline_active()
  return enabled()
    and vim.api.nvim_get_mode().mode == "c"
    and vim.fn.pumvisible() == 0
    and vim.fn.wildmenumode() == 0
    and current() ~= nil
end

function M.register_source(id, provider)
  assert(
    type(id) == "string" and type(provider) == "table" and type(provider.complete) == "function",
    "completion-tools: source must have complete(ctx, callback)"
  )

  M.hide()
  if state.providers[id] and state.providers[id].dispose then
    state.providers[id].dispose()
  end

  state.providers[id], state.cache[id] = provider, nil
end

function M.refresh_keymaps()
  if state.disposed then
    return false
  end

  require("completion_tools.keymap").setup(state.config)
  return true
end

function M.hide(reason)
  local visible = menu.visible()
  requests.stop()

  menu.hide(reason)

  return visible
end

function M.get_context()
  return state.context
end

function M.get_status()
  local sources = state.diagnostics and state.diagnostics.snapshot() or {}
  local configured = state.config and state.config.sources or {}
  local ids = state.source_ids or (type(configured) == "table" and configured or {})
  local selected = {}

  for _, id in ipairs(ids) do
    selected[id] = true
  end

  if type(configured) == "table" then
    for _, id in ipairs(configured) do
      sources[id] = sources[id] or { status = "not_requested" }
    end
  end

  for id, item in pairs(sources) do
    item.registered = state.providers[id] ~= nil
    item.selected = selected[id] == true
    local options = state.config and state.config.providers[id] or {}
    options = options or {}
    item.configured_enabled = options.enabled ~= false
    if item.status == "not_requested" and not item.configured_enabled then
      item.status = "disabled"
    end

    item.timeout_ms = options.timeout_ms or (state.config and state.config.timeout_ms)
    item.max_items = options.max_items
    if id == "copilot" and state.providers[id] and state.providers[id].get_status then
      item.client = state.providers[id].get_status()
    end
  end

  local ok, active = pcall(enabled)
  local entry = menu.selected_entry()
  local ready = state.ready == true and not (entry and entry.stale)

  return {
    configured = state.config ~= nil and not state.disposed,
    enabled = ok and active or false,
    reason = not state.config and "not_configured" or (state.disposed and "disposed" or state.reason),
    last_request_reason = state.last_request_reason,
    menu_visible = menu.visible(),
    ready = ready,
    stale = menu.visible() and not ready,
    mode = state.context and state.context.mode,
    filetype = state.context and state.context.filetype,
    sources = sources,
  }
end

function M.show_status()
  local status = M.get_status()
  local text, spans = require("completion_tools.diagnostics").format(status)
  vim.notify(text, vim.log.levels.INFO, { title = "Completion tools", markdown = false, spans = spans })
  return status
end

local acceptance = require("completion_tools.accept").new(state, {
  current = current,
  selected_entry = menu.selected_entry,
  hide = M.hide,
  show = M.show,
  invalidate = requests.invalidate,
  request = requests.start,
  report = report,
})

function M.accept(opts)
  return acceptance.accept(opts)
end

function M.accept_word()
  return acceptance.accept_partial("word")
end

function M.accept_line()
  return acceptance.accept_partial("line")
end

function M.snippet_forward()
  if state.config.snippets.jump then
    return state.config.snippets.jump(1)
  end

  if vim.snippet.active({ direction = 1 }) then
    vim.snippet.jump(1)
    return true
  end

  return false
end

function M.snippet_backward()
  if state.config.snippets.jump then
    return state.config.snippets.jump(-1)
  end

  if vim.snippet.active({ direction = -1 }) then
    vim.snippet.jump(-1)
    return true
  end

  return false
end

function M._can(action)
  if action == "show" then
    return (not M.is_menu_visible() or #state.items == 0) and enabled()
  end

  if action == "hide" then
    return M.is_menu_visible()
  end

  if action == "accept" then
    local entry = menu.selected_entry()
    return state.ready and entry ~= nil and not entry.stale and context.same(state.context, current())
  end

  if action == "accept_word" or action == "accept_line" then
    local entry = menu.selected_entry()
    return state.ready
      and entry ~= nil
      and not entry.stale
      and context.same(state.context, current())
      and state.providers[entry.source_id].partial ~= nil
  end

  if action == "select_next" or action == "select_prev" then
    return #state.items > 0 and state.ready and M.is_menu_visible() and context.same(state.context, current())
  end

  if action == "show_documentation" then
    return menu.selected_entry() ~= nil
  end

  if action == "snippet_forward" or action == "snippet_backward" then
    if vim.api.nvim_get_mode().mode == "c" then
      return false
    end

    if state.config.snippets.active then
      return state.config.snippets.active(action == "snippet_forward" and 1 or -1)
    end

    return vim.snippet.active({ direction = action == "snippet_forward" and 1 or -1 })
  end

  if action:match("^scroll_documentation_") then
    return M.is_menu_visible()
  end

  return false
end

function M.get_lsp_capabilities(base)
  return require("completion_tools.capabilities").get_lsp_capabilities(base)
end

dispose_runtime = function()
  M.hide()
  if state.dispose_command then
    state.dispose_command()
    state.dispose_command = nil
  end

  if state.ranking then
    state.ranking.dispose()
    state.ranking = nil
  end

  state.disposed = true
  acceptance.cancel()
  events.dispose()

  require("completion_tools.keymap").dispose()
  for _, provider in pairs(state.providers) do
    if provider.dispose then
      provider.dispose()
    end
  end

  requests.dispose()
  menu.dispose()
  state.providers, state.cache, state.source_ids = {}, {}, {}
  state.builtin_display_names = {}
  state.accepted = nil
end

function M.dispose()
  dispose_runtime()
  local config = package.loaded["completion_tools.config"]
  if config then
    config.reset()
  end
end

return M
