-- Icons match the former Copilot statusline. Text labels remain metadata for
-- diagnostics/tests; only the icon and the optional spinner enter the footer.
local M = {}
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
function M.format(client, record, count)
  client, record = client or {}, record or {}
  local label, icon, group, busy = "Waiting", "", "Special", true
  local server = client.server or {}
  if client.enabled == false or record.status == "skipped" then
    label, icon, group, busy = "Disabled", "", "Comment", false
  elseif record.status == "timeout" then
    label, icon, group, busy = "Timed out", "", "DiagnosticWarn", false
  elseif server.kind == "Error" then
    label, icon, group, busy = "Sign in required", "", "DiagnosticError", false
  elseif client.last_error or record.status == "error" or server.kind == "Warning" then
    label, icon, group, busy = "Unavailable", "", "DiagnosticWarn", false
  elseif record.status == "pending" then
    if client.running and not client.initialized then
      label = "Starting"
    elseif client.initialized then
      label = "Generating"
    end
  elseif record.status == "done" then
    label = (count or 0) > 0 and "Ready" or "No suggestions"
    group, busy = (count or 0) > 0 and "DiagnosticOk" or "Comment", false
  elseif server.busy then
    label = "Generating"
  end
  return { text = icon, label = label, highlight = group, frames = busy and spinner or nil }
end
return M
