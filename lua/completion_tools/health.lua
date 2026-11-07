local M = {}

function M.check()
  vim.health.start("completion-tools.nvim")
  if vim.fn.has("nvim-0.11") == 0 then
    vim.health.error("Neovim 0.11+ is required", { "Upgrade Neovim" })
    return
  end
  local issues = {}
  local function problem(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local plugin = package.loaded.completion_tools
  local status = plugin and plugin.get_status()
  if not status or not status.configured then
    vim.health.info("Not configured; completion checks skipped.")
    return
  end
  for id, item in pairs(status.sources) do
    if not item.registered then
      problem(
        "warn",
        id .. ": configured source is not registered; completion is unavailable.",
        { "Register the source or remove it from sources" }
      )
    elseif item.status == "error" or item.status == "timeout" then
      problem(
        "warn",
        id
          .. ": "
          .. (item.status == "timeout" and "request deadline exceeded" or tostring(item.last_error))
          .. "; source results are unavailable.",
        { "Inspect :CompletionToolsInfo for the current source state" }
      )
    elseif item.client and item.client.last_error and not item.client.running then
      problem(
        "warn",
        id .. ": " .. item.client.last_error,
        { "Inspect :CompletionToolsCopilot status and authenticate if needed" }
      )
    end
  end

  table.sort(issues, function(a, b)
    if a.level ~= b.level then
      return a.level == "error"
    end
    return a.message < b.message
  end)
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok("Configured completion sources are available.")
  end
  vim.health.info("Details: :CompletionToolsInfo")
end

return M
