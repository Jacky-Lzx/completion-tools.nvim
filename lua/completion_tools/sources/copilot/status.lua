-- Icons match the former Copilot statusline. Text labels remain metadata for
-- diagnostics/tests; only the icon and the optional spinner enter the footer.
local M = {}
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local empty = {}
-- stylua: ignore
local statuses = {
  waiting        = { text = "", label = "Waiting",          highlight = "Special", frames = spinner },
  disabled       = { text = "", label = "Disabled",         highlight = "Comment"                   },
  timeout        = { text = "", label = "Timed out",        highlight = "DiagnosticWarn"            },
  sign_in        = { text = "", label = "Sign in required", highlight = "DiagnosticError"           },
  unavailable    = { text = "", label = "Unavailable",      highlight = "DiagnosticWarn"            },
  starting       = { text = "", label = "Starting",         highlight = "Special", frames = spinner },
  generating     = { text = "", label = "Generating",       highlight = "Special", frames = spinner },
  ready          = { text = "", label = "Ready",            highlight = "DiagnosticOk"              },
  no_suggestions = { text = "", label = "No suggestions",   highlight = "Comment"                   },
}

--- Return a shared footer status. Treat the result and its frames as read-only.
function M.format(client, record, count)
  client = client or empty
  local status = record and record.status
  local server = client.server or empty

  if client.enabled == false or status == "skipped" then
    return statuses.disabled
  elseif status == "timeout" then
    return statuses.timeout
  elseif server.kind == "Error" then
    return statuses.sign_in
  elseif client.last_error or status == "error" or server.kind == "Warning" then
    return statuses.unavailable
  elseif status == "pending" then
    if client.running and not client.initialized then
      return statuses.starting
    elseif client.initialized then
      return statuses.generating
    end
  elseif status == "done" then
    return (count or 0) > 0 and statuses.ready or statuses.no_suggestions
  elseif server.busy then
    return statuses.generating
  end
  return statuses.waiting
end

return M
