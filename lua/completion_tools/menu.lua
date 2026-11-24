local context = require("completion_tools.context")
local ui = require("completion_tools.ui")
local M = {}

function M.new(state, current, report)
  local menu = { visible = ui.visible }
  local documentation

  function menu.setup()
    documentation = require("completion_tools.documentation_session").new(state, menu.selected_entry, report)
  end

  function menu.cancel_documentation()
    if documentation then
      documentation.cancel()
    end
  end

  function menu.dispose()
    if documentation then
      documentation.close()
      documentation = nil
    end

    ui.dispose()
  end

  function menu.begin_request(ctx, ids, options, has_cached, manual, select_first)
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
  end

  function menu.pending(ctx, same, cached_forward)
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
  end

  function menu.hide(reason)
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
  end

  function menu.redraw_cmdline(ctx)
    ui.hide_documentation()
    ui.render(state.items, state.selected, ctx, state.config)
  end

  function menu.selected_entry()
    return state.selected and state.items[state.selected]
  end

  function menu.update_status()
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

  function menu.notify_source_group(name)
    vim.notify("Completion sources: " .. name, vim.log.levels.INFO)
  end

  function menu.publish(pending)
    local ctx = state.context
    if not ctx or not context.same(ctx, current()) then
      return
    end

    menu.update_status()

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

    local previous = menu.selected_entry()
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
        menu.notify_source_group(name)
      end
    end

    documentation.refresh(false)

    return #items > 0 or not pending
  end

  function menu.get_items()
    local items = {}
    for i, entry in ipairs(state.items) do
      items[i] = entry.resolved or entry.item
    end

    return items
  end

  function menu.get_selected_item()
    local entry = menu.selected_entry()
    return entry and (entry.resolved or entry.item)
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

  function menu.select_next(opts)
    return select(1, opts)
  end

  function menu.select_prev(opts)
    return select(-1, opts)
  end

  function menu.show_documentation()
    if not menu.selected_entry() then
      return false
    end

    documentation.refresh(true)
    return true
  end

  function menu.scroll_documentation_up()
    return ui.scroll_documentation(-4)
  end

  function menu.scroll_documentation_down()
    return ui.scroll_documentation(4)
  end

  return menu
end

return M
