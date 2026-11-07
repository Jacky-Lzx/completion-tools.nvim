local M = {}
local context = require("completion_tools.context")
local ui = require("completion_tools.ui")
local state = {
  generation = 0,
  items = {},
  providers = {},
  cache = {},
  cancels = {},
  groups = {},
  retained = {},
  selected = nil,
  selection_manual = false,
  config = nil,
  context = nil,
  disposed = true,
  accept_cancels = {},
  watched = {},
}
local timer, doc_timer, doc_cancel, group

local function stop_timer(id)
  if id and not id:is_closing() then
    id:stop()
  end
end
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
local function cancel_doc()
  stop_timer(doc_timer)
  if doc_cancel then
    pcall(doc_cancel)
    doc_cancel = nil
  end
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
local function accepted_event(entry, ctx, extra)
  local item, public = entry.resolved or entry.item, {}
  for key, value in pairs(item) do
    if type(key) == "string" and key:sub(1, 1) ~= "_" then
      public[key] = value
    end
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CompletionToolsAccept",
    modeline = false,
    data = vim.tbl_extend(
      "force",
      { item = public, source = entry.source_id, client_id = item._client_id, bufnr = ctx.bufnr },
      extra or {}
    ),
  })
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

local function documentation(force)
  cancel_doc()
  local entry = selected_entry()
  local previous = state.doc_entry
  if not entry or not previous or entry.key ~= previous.key or entry.source_id ~= previous.source_id then
    ui.hide_documentation()
    state.doc_entry = nil
  end
  if not entry then
    return
  end
  -- Retained candidates are presentation only. Keep an existing document for
  -- the same item, but never resolve an item against an outdated snapshot.
  if entry.stale then
    return
  end
  local generation = state.generation
  local may_draw = force
  local function draw()
    if generation == state.generation and selected_entry() == entry and M.is_menu_visible() then
      state.doc_entry = ui.documentation(entry.resolved or entry.item, state.config) and entry or nil
    end
  end
  local provider = state.providers[entry.source_id]
  if provider and provider.resolve and not entry.resolved then
    local ok, cancel = pcall(provider.resolve, entry, function(item)
      vim.schedule(function()
        if generation ~= state.generation or selected_entry() ~= entry then
          return
        end
        entry.resolved = item
        if may_draw then
          draw()
        end
      end)
    end)
    if ok then
      doc_cancel = type(cancel) == "function" and cancel or nil
    else
      report(cancel)
    end
  end
  if force then
    draw()
  elseif state.config.documentation.auto_show then
    doc_timer:start(
      state.config.documentation.delay_ms,
      0,
      vim.schedule_wrap(function()
        may_draw = true
        draw()
      end)
    )
  end
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
    ui.set_status(require("completion_tools.copilot_status").format(client, record, count))
  else
    ui.set_status(nil)
  end
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
  local items = matcher.filter(groups, ctx, state.config.max_items, match_options)
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
    entry.stale = state.groups[entry.source_id] == nil
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
  ui.render(items, state.selected, ctx, state.config)
  documentation(false)
  return #items > 0 or not pending
end

local function source_ids(ctx, override)
  if ctx.mode == "cmdline" then
    return ctx.cmdtype == ":" and { "cmdline" } or { "buffer" }
  end
  local configured = override or state.config.sources
  local ids = type(configured) == "function" and configured(ctx) or configured
  return ids
end

local function request(manual, override, select_first)
  if not enabled() then
    M.hide("disabled")
    return false
  end
  local ctx = current()
  if not ctx or vim.fn.pumvisible() == 1 or (ctx.mode == "cmdline" and vim.fn.wildmenumode() == 1) then
    M.hide(ctx and "native_completion" or "unsupported_context")
    return false
  end
  local ids = source_ids(ctx, override)
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
        return false
      end
      -- A cached literal continuation may cross spaces and punctuation, but
      -- that must not launch other providers at otherwise blocked characters.
      ids = cached_ids
    end
  end
  if not manual and context.same(state.accepted, ctx) then
    state.reason = "accepted"
    return false
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
  local minimum = ctx.mode == "cmdline" and state.config.cmdline.min_keyword_length
    or state.config.min_keyword_length
  if not manual and #ctx.prefix < minimum and not triggered and not ctx.before:match("[/\\][^%s]*$") then
    if #cached_ids == 0 then
      M.hide("min_keyword_length")
      return false
    end
    ids = cached_ids
  end
  state.generation = state.generation + 1
  local generation = state.generation
  local keep = {}
  for _, id in ipairs(ids) do
    if options[id].enabled then
      keep[id] = ctx
    end
  end
  cancel_requests(keep)
  cancel_doc()
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
  if
    #cached_ids == 0
    and not context.same(previous_context, ctx)
    and not context.continues(previous_context, ctx)
  then
    state.items, state.selected = {}, nil
    state.selection_manual = false
    state.doc_entry = nil
    ui.hide()
  else
    ui.reposition(ctx, state.config)
  end
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
    local remaining = ui.visible()
        and state.last_render
        and interval - (vim.uv.hrtime() - state.last_render) / 1e6
      or 0
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
      local items = response.items or response
      if configured.transform_items then
        items = configured.transform_items(ctx, items)
      end
      local result = {
        items = items,
        source_id = id,
        priority = priorities[id],
        score_offset = configured.score_offset or state.providers[id].score_offset or 0,
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
        response = state.providers[id].reuse and (not response.pending or response.stable) and response
          or nil,
        cursor_col = ctx.col,
      }
      return matches
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
  cancel_doc()
  state.ready = false
  state.reason = "pending"
  stop_timer(timer)
  if not same then
    state.selection_manual = false
  end
  if same or cached_forward or context.continues(state.context, ctx) then
    ui.reposition(ctx, state.config)
  else
    ui.hide()
    state.doc_entry = nil
  end
  local generation = state.generation
  local function run()
    if generation == state.generation and not state.disposed then
      request(manual, sources)
    end
  end
  if state.config.debounce_ms == 0 then
    vim.schedule(run)
  else
    timer:start(state.config.debounce_ms, 0, vim.schedule_wrap(run))
  end
end

function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "completion-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  local config = require("completion_tools.config").validate(opts or {})
  if vim.fn.has("nvim-0.11") ~= 1 then
    error("completion-tools requires Neovim 0.11+")
  end
  M.dispose()
  state.config, state.disposed = config, false
  state.diagnostics = require("completion_tools.diagnostics").new()
  state.run, state.reason, state.last_request_reason = nil, "idle", nil
  state.dispose_command = require("completion_tools.diagnostics").command()
  state.ranking = require("completion_tools.ranking").new(config.ranking)
  -- setup may itself run inside Lazy's first InsertEnter callback.
  state.edit_buf, state.edit_tick = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_changedtick(0)
  timer, doc_timer = vim.uv.new_timer(), vim.uv.new_timer()
  for _, id in ipairs({ "lsp", "buffer", "path", "snippets", "cmdline", "dictionary", "spell", "copilot" }) do
    state.providers[id] = require("completion_tools.sources." .. id).new(config[id] or {}, function()
      if state.context and state.context.bufnr == vim.api.nvim_get_current_buf() then
        local same = context.same(state.context, current())
        if same or config.auto_show then
          request(same and state.manual or false, same and state.source_ids or nil)
        else
          M.hide()
        end
      end
    end)
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
  group = vim.api.nvim_create_augroup("CompletionTools", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function(args)
      M.hide()
      state.edit_buf, state.edit_tick = args.buf, vim.api.nvim_buf_get_changedtick(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args)
      local tick = vim.api.nvim_buf_get_changedtick(args.buf)
      local changed = state.edit_buf ~= args.buf or state.edit_tick ~= tick
      state.edit_buf, state.edit_tick = args.buf, tick
      if config.auto_show and changed then
        queue()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    callback = function()
      if not state.context then
        return
      end
      local ctx = current()
      if not context.same(state.context, ctx) then
        if config.auto_show and ctx and state.context.tick ~= ctx.tick then
          queue()
        else
          M.hide()
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave", "CmdlineLeave" }, {
    group = group,
    callback = function()
      M.hide()
      state.cache = {}
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter" }, {
    group = group,
    callback = function(args)
      watch(args.buf)
      warmup(args.buf)
    end,
  })
  if config.cmdline.enabled then
    vim.api.nvim_create_autocmd("CmdlineEnter", {
      group = group,
      callback = function()
        M.hide()
        state.cache = {}
        state.accepted = nil
      end,
    })
    vim.api.nvim_create_autocmd("CmdlineChanged", {
      group = group,
      callback = function()
        -- Repainting an unchanged search through setcmdline() must retain the
        -- current request and manual selection instead of starting them again.
        if context.same(state.context, current()) then
          return
        end
        if config.cmdline.auto_show then
          queue()
        else
          M.hide()
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ui.highlights })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "ThemeToolsIconsChanged", "ThemeToolsReady" },
    callback = function(event)
      if event.match == "ThemeToolsReady" then
        ui.highlights()
      end
      if state.context and M.is_menu_visible() then
        ui.refresh_icons(state.items, state.selected, state.context, state.config)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      if state.context and args.buf == state.context.bufnr then
        M.hide()
        state.cache = {}
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
    group = group,
    callback = function(args)
      state.cache.lsp = nil
      if
        args.buf == vim.api.nvim_get_current_buf()
        and state.context
        and (config.auto_show or state.manual)
      then
        queue()
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CompletionToolsCopilotStatus",
    callback = function()
      if ui.visible() and state.context and context.same(state.context, current()) then
        update_menu_status()
        ui.reposition(state.context, state.config)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if state.context and state.context.mode == "cmdline" then
        vim.schedule(M.refresh_cmdline)
      else
        M.hide()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.dispose })
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
  stop_timer(timer)
  local ctx = current()
  if ctx and ctx.mode == "insert" then
    -- A mapping can run before TextChangedI for the characters preceding it.
    -- Those edits are already included in this explicit request's snapshot.
    state.edit_buf, state.edit_tick = ctx.bufnr, ctx.tick
  end
  return request(true, opts and opts.sources)
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
  state.generation = state.generation + 1
  cancel_requests()
  cancel_doc()
  stop_timer(timer)
  for id, cache in pairs(state.cache) do
    if cache.response then
      state.cache[id] = nil
    end
  end
  state.items, state.selected, state.context, state.groups, state.ready = {}, nil, nil, {}, false
  state.retained, state.last_render = {}, nil
  state.select_first = nil
  state.selection_manual = false
  state.reason = reason or "hidden"
  if reason then
    state.last_request_reason = reason
  end
  if state.diagnostics then
    state.diagnostics.shown({})
  end
  state.doc_entry = nil
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
  if
    #state.items == 0
    or not state.ready
    or not ui.visible()
    or not context.same(state.context, current())
  then
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
  documentation(false)
  return true
end
function M.select_next(opts)
  return select(1, opts)
end
function M.select_prev(opts)
  return select(-1, opts)
end
function M.accept(opts)
  assert(
    opts == nil
      or (type(opts) == "table" and (opts.mode == nil or opts.mode == "insert" or opts.mode == "replace")),
    "completion-tools: invalid accept mode"
  )
  if not state.ready or not context.same(state.context, current()) then
    return false
  end
  local entry, ctx = selected_entry(), state.context
  if not entry or entry.stale or not ui.visible() then
    return false
  end
  local provider = state.providers[entry.source_id]
  M.hide("accepted")
  state.cache = {}
  local ok, err = pcall(function()
    local edits = require("completion_tools.edits")
    local transaction = edits.apply(entry, ctx, state.config, opts)
    state.ranking.record(entry, ctx)
    if provider and provider.execute then
      provider.execute(entry, ctx)
    end
    local item = entry.resolved or entry.item
    local client = item._client_id and vim.lsp.get_client_by_id(item._client_id)
    if client and item.command then
      client:exec_cmd(item.command, { bufnr = ctx.bufnr })
    end
    if
      transaction
      and not entry.resolved
      and not next(item.additionalTextEdits or {})
      and provider
      and provider.resolve
      and provider.resolve_on_accept ~= false
    then
      local tick = vim.api.nvim_buf_get_changedtick(ctx.bufnr)
      local token = {}
      state.accept_cancels[token] = false
      local cancel = provider.resolve(entry, function(resolved)
        vim.schedule(function()
          if state.accept_cancels[token] == nil then
            return
          end
          state.accept_cancels[token] = nil
          if
            state.disposed
            or not vim.api.nvim_buf_is_valid(ctx.bufnr)
            or vim.api.nvim_buf_get_changedtick(ctx.bufnr) ~= tick
          then
            return
          end
          local applied, apply_err = pcall(edits.apply_resolved, entry, ctx, resolved, transaction)
          if not applied then
            report(apply_err)
            return
          end
          if client and not item.command and resolved.command then
            client:exec_cmd(resolved.command, { bufnr = ctx.bufnr })
          end
          state.accepted = current()
        end)
      end)
      state.accept_cancels[token] = type(cancel) == "function" and cancel or false
    end
    local accepted_ctx = current()
    accepted_event(entry, ctx)
    state.accepted = current()
    if
      provider
      and provider.retrigger_on_accept
      and provider.retrigger_on_accept(entry, ctx)
      and context.same(accepted_ctx, state.accepted)
    then
      -- Continue explicit directory navigation even when '/' or automatic
      -- completion is disabled. show() accounts for this edit's TextChangedI.
      M.show({ sources = { entry.source_id } })
    end
  end)
  if not ok then
    report(err)
  end
  return true
end
local function accept_partial(part)
  if not state.ready or not context.same(state.context, current()) or not ui.visible() then
    return false
  end
  local entry, ctx = selected_entry(), state.context
  local provider = entry and state.providers[entry.source_id]
  if not provider or entry.stale or not provider.partial then
    return false
  end
  local plan = provider.partial(entry, ctx, part)
  if not plan then
    return false
  end
  if plan.full then
    return M.accept()
  end
  local ok, err = pcall(function()
    state.generation = state.generation + 1
    cancel_requests()
    cancel_doc()
    local partial = vim.tbl_extend("force", {}, entry, { item = plan.item, context = ctx, resolved = false })
    require("completion_tools.edits").apply(partial, ctx, state.config)
    if provider.execute then
      provider.execute(partial, ctx)
    end
    local next_ctx = current()
    local response = next_ctx and plan.continue(next_ctx)
    if response then
      state.cache[entry.source_id] = { response = response, context = next_ctx, cursor_col = next_ctx.col }
      state.accepted = nil
      state.edit_buf, state.edit_tick = next_ctx.bufnr, next_ctx.tick
      -- Select after the replacement is actually published; frame throttling
      -- may outlive the next scheduled event-loop callback.
      request(true, { entry.source_id }, true)
    else
      M.hide("accepted")
      state.accepted = next_ctx
    end
    accepted_event(partial, ctx, { partial = part, text = plan.item.textEdit.newText })
  end)
  if not ok then
    M.hide("accept_error")
    report(err)
  end
  return true
end
function M.accept_word()
  return accept_partial("word")
end
function M.accept_line()
  return accept_partial("line")
end
function M.show_documentation()
  if not selected_entry() then
    return false
  end
  documentation(true)
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
  for _, cancel in pairs(state.accept_cancels) do
    if cancel then
      pcall(cancel)
    end
  end
  state.accept_cancels = {}
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  require("completion_tools.keymap").dispose()
  for _, provider in pairs(state.providers) do
    if provider.dispose then
      provider.dispose()
    end
  end
  close_timer(timer)
  close_timer(doc_timer)
  timer, doc_timer = nil, nil
  ui.dispose()
  state.providers, state.cache, state.source_ids = {}, {}, {}
  state.accepted = nil
  state.watched = {}
end

return M
