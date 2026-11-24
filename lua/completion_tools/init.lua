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
  cancels = {},
  groups = {},
  retained = {},
  selected = nil,
  selection_manual = false,
  config = nil,
  context = nil,
  disposed = true,
  watched = {},
}
local request_timer, documentation

local function close_timer(id)
  if id and not id:is_closing() then
    id:stop()
    id:close()
  end
end

local function cancel_requests(keep)
  for _, cancel in ipairs(state.cancels) do
    pcall(cancel, keep)
  end
  state.cancels = {}
end

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

local function valid(generation, ctx)
  return not state.disposed and generation == state.generation and context.same(ctx, current())
end

local function selected_entry()
  return state.selected and state.items[state.selected]
end

local function watch(buf)
  if state.watched[buf] or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end

  local token = {}
  state.watched[buf] = token
  vim.api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, _, _, row, col, _, old_rows, _, old_bytes, new_rows, new_col)
      if state.watched[buf] ~= token then
        return true
      end

      for id, cache in pairs(state.cache) do
        if cache.response and cache.context.bufnr == buf then
          -- Custom reuse requires an uninterrupted series of insertions at the
          -- last cursor. Even an edit that is later undone must invalidate it.
          if
            row ~= cache.context.row
            or col ~= cache.cursor_col
            or old_rows ~= 0
            or old_bytes ~= 0
            or new_rows ~= 0
          then
            state.cache[id] = nil
          else
            cache.cursor_col = col + new_col
          end
        end
      end
    end,

    on_lines = function(_, _, _, first, old_last, new_last)
      if state.watched[buf] ~= token then
        return true
      end

      for id, cache in pairs(state.cache) do
        local ctx = cache.context
        if ctx.bufnr == buf and (first ~= ctx.row or old_last ~= first + 1 or new_last ~= old_last) then
          state.cache[id] = nil
        end
      end
    end,

    on_detach = function()
      if state.watched[buf] == token then
        state.watched[buf] = nil
      end
    end,

    on_reload = function()
      if state.watched[buf] == token then
        state.cache = {}
      end
    end,
  })
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

local function source_ids(ctx, override)
  if ctx.mode == "cmdline" then
    return state.config.cmdline.sources[ctx.cmdtype]
  end

  local configured = override or state.config.sources
  return type(configured) == "function" and configured(ctx) or configured
end

local function prepare_sources(ctx, ids)
  local options, reused = {}, {}
  for _, id in ipairs(ids) do
    local configured = state.config.providers[id] or {}
    local active = configured.enabled
    if active == nil then
      active = true
    end

    local err
    if type(active) == "function" then
      local ok, value = pcall(active, ctx)
      active = ok and value
      if not ok then
        err = tostring(value)
        report(id .. ": " .. err)
      end
    end

    local provider, old = state.providers[id], state.cache[id]
    options[id] = {
      enabled = provider ~= nil and active,
      error = err,
      timeout_ms = configured.timeout_ms or state.config.timeout_ms,
      fallback_for = configured.fallback_for,
    }

    if not options[id].enabled and old and old.response then
      state.cache[id] = nil
    end

    if options[id].enabled and provider.reuse and old and old.response then
      local ok, response = pcall(provider.reuse, ctx, old.response, old.context)
      if ok then
        reused[id] = response
      else
        report(id .. ": " .. tostring(response))
      end

      if not reused[id] then
        state.cache[id] = nil
      end
    end
  end

  local cached_ids = vim.tbl_filter(function(id)
    return reused[id] ~= nil
  end, ids)

  return options, reused, cached_ids
end

local function filter_sources(ctx, ids, cached_ids, manual)
  local character_trigger = false
  if not manual then
    local allowed
    if ctx.mode == "insert" then
      allowed, character_trigger = context.can_auto_show(state.config, ctx)
    else
      allowed = ctx.before:find("%S") ~= nil
    end

    if not allowed then
      if #cached_ids == 0 then
        M.hide("trigger_filtered")
        return
      end

      -- A cached literal continuation may cross spaces and punctuation, but
      -- that must not launch other providers at otherwise blocked characters.
      ids = cached_ids
    end
  end

  if not manual and context.same(state.accepted, ctx) then
    state.reason = "accepted"
    return
  end

  state.accepted = nil
  local triggered = character_trigger or ctx.argument_trigger or false
  for _, id in ipairs(ids) do
    local provider = state.providers[id]
    if provider and provider.trigger and provider.trigger(ctx) then
      triggered = true
      break
    end
  end

  local minimum = ctx.mode == "cmdline" and state.config.cmdline.min_keyword_length or state.config.min_keyword_length
  if not manual and #ctx.prefix < minimum and not triggered and not ctx.before:match("[/\\][^%s]*$") then
    if #cached_ids == 0 then
      M.hide("min_keyword_length")
      return
    end

    ids = cached_ids
  end

  return ids
end

local function begin_request(ctx, ids, options, has_cached, manual, select_first)
  state.generation = state.generation + 1
  local generation = state.generation
  local keep = {}
  for _, id in ipairs(ids) do
    if options[id].enabled then
      keep[id] = ctx
    end
  end

  cancel_requests(keep)
  documentation.cancel()

  local previous_context = state.context
  if not context.same(previous_context, ctx) then
    state.selection_manual = false
  end

  -- Keep per-source candidates for visual continuity, separately from safe
  -- cache reuse. Each source must refresh its items before they are accepted.
  local retained = {}
  if ui.visible() and (context.same(previous_context, ctx) or context.continues(previous_context, ctx)) then
    for _, id in ipairs(ids) do
      if options[id].enabled then
        retained[id] = state.groups[id] or state.retained[id]
      end
    end
  end

  state.context, state.groups, state.source_ids, state.retained = ctx, {}, ids, retained
  state.manual = manual
  state.select_first = select_first
  state.ready = false
  state.reason = "pending"
  if not has_cached and not context.same(previous_context, ctx) and not context.continues(previous_context, ctx) then
    state.items, state.selected = {}, nil
    state.selection_manual = false
    documentation.reset()
    ui.hide()
  else
    ui.reposition(ctx, state.config)
  end

  return generation
end

local function receive_response(generation, ctx, id, priority, response)
  if not valid(generation, ctx) then
    return false
  end

  response = response or { items = {} }
  if response.cached then
    state.groups[id] = response.cached.group
    state.diagnostics.receive(id, #response.cached.group.items)
    return require("completion_tools.matcher").has_match(response.cached.group, ctx, {
      max_typos = ctx.mode ~= "cmdline" and state.config.ranking.max_typos or 0,
    })
  end

  local configured = state.config.providers[id] or {}
  local provider = state.providers[id]
  local items = response.items or response
  if configured.transform_items then
    items = configured.transform_items(ctx, items)
  end

  local result = {
    items = items,
    source_id = id,
    display_name = configured.display_name or provider.display_name or state.builtin_display_names[id],
    excluded_label = provider.excluded_label,
    priority = priority,
    insert_at = configured.insert_at,
    client_order = id == "lsp" and configured.client_order or nil,
    score_offset = configured.score_offset or provider.score_offset or 0,
    start_col = response.start_col or ctx.start_col,
    context = response.context or ctx,
  }

  for _, item in ipairs(items) do
    local edit = item.textEdit
    local range = edit and (edit.range or edit.replace or edit.insert)
    if range and range.start.line == ctx.row then
      result.start_cols = result.start_cols or {}
      local encoding = item._encoding or "utf-8"
      result.start_cols[item] = encoding == "utf-8" and range.start.character
        or vim.str_byteindex(ctx.line, encoding, range.start.character, false)
    end
  end

  local matches = require("completion_tools.matcher").has_match(result, ctx, {
    max_typos = ctx.mode ~= "cmdline" and state.config.ranking.max_typos or 0,
  })

  -- Empty partials are not an authoritative replacement for a retained
  -- source, even when other sources already have fresh matches to show.
  if not (response.pending and not matches and state.retained[id]) then
    state.groups[id] = result
    state.retained[id] = nil
  end

  state.diagnostics.receive(id, #items)
  state.cache[id] = {
    group = result,
    context = ctx,
    reusable = response.reusable and not response.pending,
    incomplete = response.is_incomplete,
    response = provider.reuse and (not response.pending or response.stable) and response or nil,
    cursor_col = ctx.col,
  }

  return matches
end

local function run_request(generation, ctx, ids, options, reused)
  local render_queued, run, render_timer = false, nil, nil

  local function queue_render()
    if run then
      state.diagnostics.update(run.records)
      for id, record in pairs(run.records) do
        if record.status ~= "pending" then
          state.retained[id] = nil
        end
      end
    end

    if render_queued then
      return
    end

    render_queued = true

    local function flush()
      render_timer = nil
      render_queued = false
      if valid(generation, ctx) then
        if render(run and run.pending() or false) then
          state.last_render = vim.uv.hrtime()
        end
      end
    end

    -- The first frame of a session is immediate. Share the deadline across
    -- requests too, so each keystroke cannot restart an unbounded paint burst.
    local interval = state.config.menu.update_interval_ms
    local remaining = ui.visible() and state.last_render and interval - (vim.uv.hrtime() - state.last_render) / 1e6 or 0
    if remaining > 0 then
      render_timer = vim.defer_fn(flush, math.ceil(remaining))
    else
      vim.schedule(flush)
    end
  end

  local priorities = {}
  for priority, id in ipairs(ids) do
    priorities[id] = priority
  end

  run = require("completion_tools.scheduler").run({
    ids = ids,
    options = options,
    changed = queue_render,
    failed = function(id, err)
      report(id .. ": " .. tostring(err))
    end,
    start = function(id, receive)
      local old = state.cache[id]
      local cached = reused[id] or (old and old.reusable and context.extends(old.context, ctx))
      state.diagnostics.start(id, cached)

      if reused[id] then
        receive(reused[id])
      elseif cached then
        receive({ cached = old })
      else
        ctx.incomplete = old and old.incomplete or false
        return state.providers[id].complete(ctx, receive)
      end
    end,
    receive = function(id, response)
      return receive_response(generation, ctx, id, priorities[id], response)
    end,
  })

  state.run = run
  state.diagnostics.update(run.records)
  queue_render()
  state.cancels[#state.cancels + 1] = function(preserve)
    close_timer(render_timer)
    render_timer = nil
    run.cancel(preserve)
    state.diagnostics.update(run.records)
  end
end

local function request(manual, override, select_first, explicit)
  local ctx = current()
  local source_selection = package.loaded["completion_tools.source_selection"]
  local name, switched
  if source_selection then
    name, switched = source_selection._menu_group(ctx, override, explicit)
  end

  local reason
  if not enabled() then
    reason = "disabled"
  elseif not ctx then
    reason = "unsupported_context"
  elseif vim.fn.pumvisible() == 1 or (ctx.mode == "cmdline" and vim.fn.wildmenumode() == 1) then
    reason = "native_completion"
  end

  if reason then
    M.hide(reason)
    if switched then
      notify_source_group(name)
    end
    return false
  end

  local ids = source_ids(ctx, override)
  local options, reused, cached_ids = prepare_sources(ctx, ids)
  ids = filter_sources(ctx, ids, cached_ids, manual)
  if not ids then
    return false
  end

  state.source_group = name
  if switched then
    state.announce_source_group = name
  elseif
    state.announce_source_group and (state.announce_source_group ~= name or not context.same(state.context, ctx))
  then
    state.announce_source_group = nil
  end

  local generation = begin_request(ctx, ids, options, #cached_ids > 0, manual, select_first)
  run_request(generation, ctx, ids, options, reused)

  return true
end

local function queue()
  if state.disposed then
    return
  end

  local ctx = current()
  local same = context.same(state.context, ctx)
  local cached_forward = false
  for _, cache in pairs(state.cache) do
    if cache.response and context.advances(cache.context, ctx) then
      cached_forward = true
      break
    end
  end

  -- LSP attachment and other background refreshes do not create a new edit.
  -- Keep an explicit session's trigger policy and source override at that snapshot.
  local manual = same and state.manual or false
  local sources = manual and state.source_ids or nil
  state.generation = state.generation + 1
  if not same then
    cancel_requests()
  end

  documentation.cancel()

  state.ready = false
  state.reason = "pending"

  if not same then
    state.selection_manual = false
  end

  if same or cached_forward or context.continues(state.context, ctx) then
    ui.reposition(ctx, state.config)
  else
    ui.hide()
    documentation.reset()
  end

  local generation = state.generation

  request_timer:start(state.config.debounce_ms, function()
    if generation == state.generation and not state.disposed then
      request(manual, sources)
    end
  end)
end

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
  request_timer = timer.new()
  documentation = require("completion_tools.documentation_session").new(state, selected_entry, report)

  for _, id in ipairs({ "lsp", "buffer", "path", "snippets", "cmdline", "dictionary", "spell", "copilot" }) do
    local provider = require("completion_tools.sources." .. id).new(config[id] or {}, function()
      if state.context and state.context.bufnr == vim.api.nvim_get_current_buf() then
        local same = context.same(state.context, current())
        if same or config.auto_show then
          request(same and state.manual or false, same and state.source_ids or nil)
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
    queue = queue,
    hide = M.hide,
    watch = watch,
    warmup = warmup,
    update_menu_status = update_menu_status,
    refresh_cmdline = M.refresh_cmdline,
    dispose = M.dispose,
  })
  require("completion_tools.keymap").setup(config)
  warmup(vim.api.nvim_get_current_buf())
  watch(vim.api.nvim_get_current_buf())
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
      queue()
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

function M.show(opts)
  if request_timer then
    request_timer:cancel()
  end

  local ctx = current()
  if ctx and ctx.mode == "insert" then
    -- A mapping can run before TextChangedI for the characters preceding it.
    -- Those edits are already included in this explicit request's snapshot.
    state.edit_buf, state.edit_tick = ctx.bufnr, ctx.tick
  end

  return request(true, opts and opts.sources, nil, true)
end

function M.refresh_keymaps()
  if state.disposed then
    return false
  end

  require("completion_tools.keymap").setup(state.config)
  return true
end

local function invalidate()
  state.generation = state.generation + 1
  cancel_requests()
  if documentation then
    documentation.cancel()
  end
end

function M.hide(reason)
  local visible = ui.visible()
  invalidate()

  if request_timer then
    request_timer:cancel()
  end

  for id, cache in pairs(state.cache) do
    if cache.response then
      state.cache[id] = nil
    end
  end

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
  invalidate = invalidate,
  request = request,
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

  if request_timer then
    request_timer:close()
    documentation.close()
    request_timer, documentation = nil, nil
  end

  ui.dispose()
  state.providers, state.cache, state.source_ids = {}, {}, {}
  state.builtin_display_names = {}
  state.accepted = nil
  state.watched = {}
end

return M
