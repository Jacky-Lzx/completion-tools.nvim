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
local documentation

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

local function selected_entry()
  return state.selected and state.items[state.selected]
end

local function update_menu_status()
  local ctx = state.context
  local provider = state.providers.copilot
  if
    ctx
    and ctx.mode == "insert"
    and state.config.copilot.show_status
    and vim.tbl_contains(state.source_ids or {}, "copilot")
  then
    local record = state.run and state.run.records.copilot
    local client = provider and provider.get_status and provider.get_status()
    local count = state.groups.copilot and #state.groups.copilot.items or 0
    ui.set_status(require("completion_tools.sources.copilot.status").format(client, record, count))
  else
    ui.set_status(nil)
  end
end

local function notify_source_group(name)
  vim.notify("Completion sources: " .. name, vim.log.levels.INFO)
end

local function render(pending)
  local ctx = state.context
  if not ctx or not context.same(ctx, current()) then
    return
  end

  update_menu_status()

  local groups = {}
  local matcher = require("completion_tools.matcher")
  local match_options = {
    max_typos = ctx.mode ~= "cmdline" and state.config.ranking.max_typos or 0,
    bonus = state.ranking.scorer(ctx),
  }

  for _, id in ipairs(state.source_ids) do
    local suppressed = false
    for _, dependency in ipairs((state.config.providers[id] or {}).fallback_for or {}) do
      local record = state.run and state.run.records[dependency]
      suppressed = suppressed or (record and (record.matches or record.status == "skipped"))
    end

    local record = state.run and state.run.records[id]
    if state.groups[id] or not record or record.status ~= "pending" then
      state.retained[id] = nil
    end

    local source_group = state.groups[id] or (record and record.status == "pending" and state.retained[id])
    if source_group and not suppressed then
      local cap = (state.config.providers[id] or {}).max_items
      if cap then
        source_group = vim.tbl_extend("force", source_group, {
          items = vim.tbl_map(function(entry)
            return entry.item
          end, matcher.filter({ source_group }, ctx, cap, match_options)),
        })
      end

      groups[#groups + 1] = source_group
    end
  end

  local previous = selected_entry()
  local items = matcher.select(groups, ctx, state.config.max_items, match_options)
  state.reason = #items > 0 and "ready" or (pending and "pending" or "no_matches")
  state.last_request_reason = state.reason

  -- An empty partial result is not a final "no matches". Keep the last ready
  -- frame until a useful replacement or the last provider's response arrives.
  if #items == 0 and pending and ui.visible() then
    state.ready = false
    ui.reposition(ctx, state.config)
    return
  end

  state.ready = false
  for _, entry in ipairs(items) do
    local id = entry.source_id
    local source_group = state.groups[id]
    entry.stale = source_group == nil
    local displayed_group = source_group or state.retained[id]
    local name = displayed_group and displayed_group.display_name
    if type(name) == "function" then
      local ok, value = pcall(name, entry.item)
      name = ok and value or nil
    end

    entry.source_name = type(name) == "string" and name ~= "" and name or id
    state.ready = state.ready or not entry.stale
  end

  if #items > 0 and not state.ready then
    state.reason, state.last_request_reason = "pending", "pending"
  end

  state.items = items
  state.diagnostics.shown(items)
  -- A vanished manual choice stays empty until navigation or another edit.
  state.selected = not state.selection_manual and state.config.preselect and #items > 0 and 1 or nil

  if previous then
    for i, entry in ipairs(items) do
      if entry.source_id == previous.source_id and entry.key == previous.key then
        if entry.item == previous.item and entry.context == previous.context then
          entry.resolved = previous.resolved
        end

        if state.selection_manual then
          state.selected = i
        end

        break
      end
    end
  end

  if state.select_first and state.ready and #items > 0 then
    if not state.selected then
      state.selected, state.selection_manual = 1, true
    end

    state.select_first = nil
  end

  ui.set_source_group(state.source_group)
  ui.render(items, state.selected, ctx, state.config)

  if state.announce_source_group then
    if ui.visible() then
      state.announce_source_group = nil
    elseif not pending then
      local name = state.announce_source_group
      state.announce_source_group = nil
      notify_source_group(name)
    end
  end

  documentation.refresh(false)

  return #items > 0 or not pending
end

local requests = require("completion_tools.request").new(state, {
  current = current,
  enabled = enabled,
  hide = function(reason)
    return M.hide(reason)
  end,
  report = report,
}, {
  render = render,
  notify_source_group = notify_source_group,
  cancel_documentation = function()
    if documentation then
      documentation.cancel()
    end
  end,
  reset_documentation = function()
    documentation.reset()
  end,
})

M.show = requests.show

function M.setup(opts)
  if vim.fn.has("nvim-0.12") ~= 1 then
    error("completion-tools requires Neovim 0.12+")
  end

  assert(opts == nil or type(opts) == "table", "completion-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  local config = require("completion_tools.config").validate(opts)
  local timer = require("base_tools.timer")

  M.dispose()
  state.config, state.disposed = config, false
  state.diagnostics = require("completion_tools.diagnostics").new()
  state.run, state.reason, state.last_request_reason = nil, "idle", nil
  state.dispose_command = require("completion_tools.diagnostics").command()
  state.ranking = require("completion_tools.ranking").new(config.ranking)
  -- setup may itself run inside Lazy's first InsertEnter callback.
  state.edit_buf, state.edit_tick = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_changedtick(0)
  requests.setup(timer.new())
  documentation = require("completion_tools.documentation_session").new(state, selected_entry, report)

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
    update_menu_status = update_menu_status,
    refresh_cmdline = M.refresh_cmdline,
    dispose = M.dispose,
  })
  require("completion_tools.keymap").setup(config)
  warmup(vim.api.nvim_get_current_buf())
  requests.watch(vim.api.nvim_get_current_buf())
  return M
end

-- External command-line renderers can call this after their geometry settles.
-- Only an existing completion session is refreshed; layout events cannot open
-- an idle command line's menu.
function M.refresh_cmdline()
  if not state.context or state.context.mode ~= "cmdline" or not ui.visible() then
    return false
  end

  local ctx = current()
  if not ctx then
    return M.hide()
  end

  ui.hide_documentation()
  ui.render(state.items, state.selected, ctx, state.config)

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
  local visible = ui.visible()
  requests.stop()

  state.items, state.selected, state.context, state.groups, state.ready = {}, nil, nil, {}, false
  state.retained, state.last_render = {}, nil
  state.source_group, state.announce_source_group = nil, nil
  state.select_first = nil
  state.selection_manual = false
  state.reason = reason or "hidden"

  if reason then
    state.last_request_reason = reason
  end

  if state.diagnostics then
    state.diagnostics.shown({})
  end

  if documentation then
    documentation.reset()
  end
  ui.hide()

  return visible
end

function M.is_menu_visible()
  return ui.visible()
end

function M.get_items()
  local items = {}
  for i, entry in ipairs(state.items) do
    items[i] = entry.resolved or entry.item
  end

  return items
end

function M.get_selected_item()
  local entry = selected_entry()
  return entry and (entry.resolved or entry.item)
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
  local entry = selected_entry()
  local ready = state.ready == true and not (entry and entry.stale)

  return {
    configured = state.config ~= nil and not state.disposed,
    enabled = ok and active or false,
    reason = not state.config and "not_configured" or (state.disposed and "disposed" or state.reason),
    last_request_reason = state.last_request_reason,
    menu_visible = ui.visible(),
    ready = ready,
    stale = ui.visible() and not ready,
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

local function select(direction, opts)
  if #state.items == 0 or not state.ready or not ui.visible() or not context.same(state.context, current()) then
    return false
  end

  -- Navigation follows screen direction; only the painted row order is reversed.
  if ui.is_inverse() then
    direction = -direction
  end

  local count = opts and opts.count or 1
  local index = state.selected or (direction == 1 and 0 or #state.items + 1)
  local target = index + direction * count
  if opts and opts.wrap == false then
    state.selected = math.max(1, math.min(#state.items, target))
  else
    state.selected = (target - 1) % #state.items + 1
  end

  state.selection_manual = true
  ui.render(state.items, state.selected, state.context, state.config)
  documentation.refresh(false)

  return true
end

function M.select_next(opts)
  return select(1, opts)
end

function M.select_prev(opts)
  return select(-1, opts)
end

local acceptance = require("completion_tools.accept").new(state, {
  current = current,
  selected_entry = selected_entry,
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

function M.show_documentation()
  if not selected_entry() then
    return false
  end

  documentation.refresh(true)
  return true
end

function M.scroll_documentation_up()
  return ui.scroll_documentation(-4)
end

function M.scroll_documentation_down()
  return ui.scroll_documentation(4)
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
    local entry = selected_entry()
    return state.ready and entry ~= nil and not entry.stale and context.same(state.context, current())
  end

  if action == "accept_word" or action == "accept_line" then
    local entry = selected_entry()
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
    return selected_entry() ~= nil
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

function M.dispose()
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
  if documentation then
    documentation.close()
    documentation = nil
  end

  ui.dispose()
  state.providers, state.cache, state.source_ids = {}, {}, {}
  state.builtin_display_names = {}
  state.accepted = nil
end

return M
