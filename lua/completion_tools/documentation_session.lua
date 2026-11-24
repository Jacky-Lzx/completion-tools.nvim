local ui = require("completion_tools.ui")
local M = {}

function M.new(state, selected_entry, report)
  local timer = require("base_tools.timer").new()
  local displayed, cancel_resolve
  local session = {}

  function session.cancel()
    timer:cancel()
    if cancel_resolve then
      pcall(cancel_resolve)
      cancel_resolve = nil
    end
  end

  function session.reset()
    displayed = nil
  end

  function session.close()
    timer:close()
  end

  function session.refresh(force)
    session.cancel()

    local entry = selected_entry()
    local previous = displayed
    if not entry or not previous or entry.key ~= previous.key or entry.source_id ~= previous.source_id then
      ui.hide_documentation()
      session.reset()
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
    local provider = state.providers[entry.source_id]

    local function draw()
      if generation == state.generation and selected_entry() == entry and ui.visible() then
        local item = entry.resolved or entry.item
        local document
        if provider and type(provider.documentation) == "function" then
          local ok, result = pcall(provider.documentation, item, entry.context)
          if ok then
            document = type(result) == "table" and result or nil
          else
            report(result)
          end
        end

        displayed = ui.documentation(item, state.config, document) and entry or nil
      end
    end

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
        cancel_resolve = type(cancel) == "function" and cancel or nil
      else
        report(cancel)
      end
    end

    if force then
      draw()
    elseif state.config.documentation.auto_show then
      timer:start(state.config.documentation.delay_ms, function()
        may_draw = true
        draw()
      end)
    end
  end

  return session
end

return M
