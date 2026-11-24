local context = require("completion_tools.context")
local ui = require("completion_tools.ui")
local M = {}

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

function M.new(state, session)
  local actions = {}
  local pending = {}

  function actions.accept(opts)
    assert(
      opts == nil or (type(opts) == "table" and (opts.mode == nil or opts.mode == "insert" or opts.mode == "replace")),
      "completion-tools: invalid accept mode"
    )

    if not state.ready or not context.same(state.context, session.current()) then
      return false
    end

    local entry, ctx = session.selected_entry(), state.context
    if not entry or entry.stale or not ui.visible() then
      return false
    end

    local provider = state.providers[entry.source_id]
    session.hide("accepted")
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
        pending[token] = false
        local cancel = provider.resolve(entry, function(resolved)
          vim.schedule(function()
            if pending[token] == nil then
              return
            end

            pending[token] = nil
            if
              state.disposed
              or not vim.api.nvim_buf_is_valid(ctx.bufnr)
              or vim.api.nvim_buf_get_changedtick(ctx.bufnr) ~= tick
            then
              return
            end

            local applied, apply_err = pcall(edits.apply_resolved, entry, ctx, resolved, transaction)
            if not applied then
              session.report(apply_err)
              return
            end

            if client and not item.command and resolved.command then
              client:exec_cmd(resolved.command, { bufnr = ctx.bufnr })
            end

            state.accepted = session.current()
          end)
        end)

        pending[token] = type(cancel) == "function" and cancel or false
      end

      local accepted_ctx = session.current()
      accepted_event(entry, ctx)
      state.accepted = session.current()

      if
        provider
        and provider.retrigger_on_accept
        and provider.retrigger_on_accept(entry, ctx)
        and context.same(accepted_ctx, state.accepted)
      then
        -- Continue explicit directory navigation even when '/' or automatic
        -- completion is disabled. show() accounts for this edit's TextChangedI.
        session.show({ sources = { entry.source_id } })
      end
    end)

    if not ok then
      session.report(err)
    end

    return true
  end

  function actions.accept_partial(part)
    if not state.ready or not context.same(state.context, session.current()) or not ui.visible() then
      return false
    end

    local entry, ctx = session.selected_entry(), state.context
    local provider = entry and state.providers[entry.source_id]
    if not provider or entry.stale or not provider.partial then
      return false
    end

    local plan = provider.partial(entry, ctx, part)
    if not plan then
      return false
    end

    if plan.full then
      return actions.accept()
    end

    local ok, err = pcall(function()
      session.invalidate()
      local partial = vim.tbl_extend("force", {}, entry, { item = plan.item, context = ctx, resolved = false })
      require("completion_tools.edits").apply(partial, ctx, state.config)
      if provider.execute then
        provider.execute(partial, ctx)
      end

      local next_ctx = session.current()
      local response = next_ctx and plan.continue(next_ctx)
      if response then
        state.cache[entry.source_id] = { response = response, context = next_ctx, cursor_col = next_ctx.col }
        state.accepted = nil
        state.edit_buf, state.edit_tick = next_ctx.bufnr, next_ctx.tick
        -- Select after the replacement is actually published; frame throttling
        -- may outlive the next scheduled event-loop callback.
        session.request(true, { entry.source_id }, true)
      else
        session.hide("accepted")
        state.accepted = next_ctx
      end

      accepted_event(partial, ctx, { partial = part, text = plan.item.textEdit.newText })
    end)

    if not ok then
      session.hide("accept_error")
      session.report(err)
    end

    return true
  end

  function actions.cancel()
    for _, cancel in pairs(pending) do
      if cancel then
        pcall(cancel)
      end
    end

    pending = {}
  end

  return actions
end

return M
