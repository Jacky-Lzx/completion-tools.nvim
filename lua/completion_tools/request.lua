local context = require("completion_tools.context")
local ui = require("completion_tools.ui")
local M = {}

local function close_timer(id)
  if id and not id:is_closing() then
    id:stop()
    id:close()
  end
end

function M.new(state, actions, view)
  local requests = {}
  local request_timer
  local cancels, watched = {}, {}

  function requests.setup(timer)
    request_timer = timer
  end

  function requests.dispose()
    if request_timer then
      request_timer:close()
      request_timer = nil
    end
    watched = {}
  end

  local function cancel_requests(keep)
    for _, cancel in ipairs(cancels) do
      pcall(cancel, keep)
    end
    cancels = {}
  end

  local function valid(generation, ctx)
    return not state.disposed and generation == state.generation and context.same(ctx, actions.current())
  end

  function requests.watch(buf)
    if watched[buf] or not vim.api.nvim_buf_is_loaded(buf) then
      return
    end

    local token = {}
    watched[buf] = token
    vim.api.nvim_buf_attach(buf, false, {
      on_bytes = function(_, _, _, row, col, _, old_rows, _, old_bytes, new_rows, new_col)
        if watched[buf] ~= token then
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
        if watched[buf] ~= token then
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
        if watched[buf] == token then
          watched[buf] = nil
        end
      end,

      on_reload = function()
        if watched[buf] == token then
          state.cache = {}
        end
      end,
    })
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
          actions.report(id .. ": " .. err)
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
          actions.report(id .. ": " .. tostring(response))
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
          actions.hide("trigger_filtered")
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
        actions.hide("min_keyword_length")
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
    view.cancel_documentation()

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
      view.reset_documentation()
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
          if view.render(run and run.pending() or false) then
            state.last_render = vim.uv.hrtime()
          end
        end
      end

      -- The first frame of a session is immediate. Share the deadline across
      -- requests too, so each keystroke cannot restart an unbounded paint burst.
      local interval = state.config.menu.update_interval_ms
      local remaining = ui.visible() and state.last_render and interval - (vim.uv.hrtime() - state.last_render) / 1e6
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
        actions.report(id .. ": " .. tostring(err))
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
    cancels[#cancels + 1] = function(preserve)
      close_timer(render_timer)
      render_timer = nil
      run.cancel(preserve)
      state.diagnostics.update(run.records)
    end
  end

  function requests.start(manual, override, select_first, explicit)
    local ctx = actions.current()
    local source_selection = package.loaded["completion_tools.source_selection"]
    local name, switched
    if source_selection then
      name, switched = source_selection._menu_group(ctx, override, explicit)
    end

    local reason
    if not actions.enabled() then
      reason = "disabled"
    elseif not ctx then
      reason = "unsupported_context"
    elseif vim.fn.pumvisible() == 1 or (ctx.mode == "cmdline" and vim.fn.wildmenumode() == 1) then
      reason = "native_completion"
    end

    if reason then
      actions.hide(reason)
      if switched then
        view.notify_source_group(name)
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

  function requests.queue()
    if state.disposed then
      return
    end

    local ctx = actions.current()
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

    view.cancel_documentation()

    state.ready = false
    state.reason = "pending"

    if not same then
      state.selection_manual = false
    end

    if same or cached_forward or context.continues(state.context, ctx) then
      ui.reposition(ctx, state.config)
    else
      ui.hide()
      view.reset_documentation()
    end

    local generation = state.generation

    request_timer:start(state.config.debounce_ms, function()
      if generation == state.generation and not state.disposed then
        requests.start(manual, sources)
      end
    end)
  end

  function requests.show(opts)
    if request_timer then
      request_timer:cancel()
    end

    local ctx = actions.current()
    if ctx and ctx.mode == "insert" then
      -- A mapping can run before TextChangedI for the characters preceding it.
      -- Those edits are already included in this explicit request's snapshot.
      state.edit_buf, state.edit_tick = ctx.bufnr, ctx.tick
    end

    return requests.start(true, opts and opts.sources, nil, true)
  end

  function requests.invalidate()
    state.generation = state.generation + 1
    cancel_requests()
    view.cancel_documentation()
  end

  function requests.stop()
    requests.invalidate()

    if request_timer then
      request_timer:cancel()
    end

    for id, cache in pairs(state.cache) do
      if cache.response then
        state.cache[id] = nil
      end
    end
  end

  return requests
end

return M
