local M = {}
function M.check()
  vim.health.start("completion-tools.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim >= 0.11")
  else
    vim.health.error("Neovim 0.11 or newer is required")
  end
  vim.health.ok("Pure Lua; no build step or external runtime dependencies")
  if package.loaded["blink.cmp"] or package.loaded.cmp then
    vim.health.warn("Another completion engine is loaded; disable it before enabling completion-tools")
  end
  local status = require("completion_tools").get_status()
  if not status.configured then
    vim.health.info("setup() has not configured an active completion session")
    return
  end
  vim.health.info("Engine state: " .. status.reason)
  local ids = vim.tbl_keys(status.sources)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local item = status.sources[id]
    local message = string.format(
      "%s: %s; requests=%d cache hits=%d; %.2f ms",
      id,
      item.status,
      item.requests or 0,
      item.cache_hits or 0,
      item.elapsed_ms or 0
    )
    if not item.registered then
      vim.health.warn(id .. ": source is configured but not registered")
    elseif item.last_error then
      vim.health.warn(message .. "; last error: " .. item.last_error)
    elseif item.status == "timeout" then
      vim.health.warn(message .. "; exceeded the configured request deadline")
    else
      vim.health.info(message)
    end
  end
  vim.health.info("Use :CompletionToolsStatus or require('completion-tools').get_status() for live details")
end
return M
