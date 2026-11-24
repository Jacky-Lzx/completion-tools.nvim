local context = require("completion_tools.context")
local ui = require("completion_tools.ui")
local M = {}
local group

function M.setup(state, actions)
  local config = state.config
  group = vim.api.nvim_create_augroup("CompletionTools", { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function(args)
      actions.hide()
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
        actions.queue()
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    callback = function()
      if not state.context then
        return
      end

      local ctx = actions.current()
      if not context.same(state.context, ctx) then
        if config.auto_show and ctx and state.context.tick ~= ctx.tick then
          actions.queue()
        else
          actions.hide()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave", "CmdlineLeave" }, {
    group = group,
    callback = function()
      actions.hide()
      state.cache = {}
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter" }, {
    group = group,
    callback = function(args)
      actions.watch(args.buf)
      actions.warmup(args.buf)
    end,
  })

  if config.cmdline.enabled then
    vim.api.nvim_create_autocmd("CmdlineEnter", {
      group = group,
      callback = function()
        actions.hide()
        state.cache = {}
        state.accepted = nil
      end,
    })

    vim.api.nvim_create_autocmd("CmdlineChanged", {
      group = group,
      callback = function()
        -- Repainting an unchanged search through setcmdline() must retain the
        -- current request and manual selection instead of starting them again.
        if context.same(state.context, actions.current()) then
          return
        end
        if config.cmdline.auto_show then
          actions.queue()
        else
          actions.hide()
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
      if state.context and ui.visible() then
        ui.refresh_icons(state.items, state.selected, state.context, state.config)
      end
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      if state.context and args.buf == state.context.bufnr then
        actions.hide()
        state.cache = {}
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
    group = group,
    callback = function(args)
      state.cache.lsp = nil
      if args.buf == vim.api.nvim_get_current_buf() and state.context and (config.auto_show or state.manual) then
        actions.queue()
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CompletionToolsCopilotStatus",
    callback = function()
      if ui.visible() and state.context and context.same(state.context, actions.current()) then
        actions.update_menu_status()
        ui.reposition(state.context, state.config)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if state.context and state.context.mode == "cmdline" then
        vim.schedule(actions.refresh_cmdline)
      else
        actions.hide()
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = actions.dispose })
end

function M.dispose()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
end

return M
