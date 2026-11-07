local diagnostics = require("completion_tools.diagnostics")
local collector = diagnostics.new()
collector.start("lsp", false)
collector.receive("lsp", 10)
collector.shown({ { source_id = "lsp" }, { source_id = "lsp" } })
local record = { status = "pending", started = vim.uv.hrtime(), matches = true }
collector.update({ lsp = record })
local snapshot = collector.snapshot()
assert(snapshot.lsp.requests == 1 and snapshot.lsp.raw_count == 10 and snapshot.lsp.shown_count == 2)
assert(snapshot.lsp.elapsed_ms >= 0 and snapshot.lsp._record == nil)
snapshot.lsp.requests = 99
assert(collector.snapshot().lsp.requests == 1)
record.status = "timeout"
collector.update({ lsp = record })
collector.update({ lsp = record })
assert(collector.snapshot().lsp.timeouts == 1)
collector.start("lsp", true)
collector.update({ lsp = { status = "error", error = "fixture error" } })
snapshot = collector.snapshot()
assert(snapshot.lsp.requests == 1 and snapshot.lsp.cache_hits == 1 and snapshot.lsp.errors == 1)
assert(snapshot.lsp.last_error == "fixture error")
local cmp = require("completion_tools")
assert(cmp.get_status().reason == "not_configured")
cmp.setup({ sources = { "missing", "lsp" } })
local status = cmp.get_status()
assert(status.configured and status.reason == "idle" and not status.sources.missing.registered)
assert(vim.api.nvim_get_commands({}).CompletionToolsInfo)
local original_notify, message = vim.notify, nil
vim.notify = function(value)
  message = value
end
vim.cmd("CompletionToolsInfo")
vim.notify = original_notify
assert(message:find("lsp: not_requested", 1, true))
local original_health, warnings = vim.health, {}
vim.health = {
  start = function() end,
  ok = function() end,
  info = function() end,
  warn = function(value)
    warnings[#warnings + 1] = value
  end,
}
require("completion_tools.health").check()
vim.health = original_health
assert(#warnings == 1 and warnings[1]:find("missing", 1, true))
cmp.dispose()
assert(cmp.get_status().reason == "disposed")
assert(not vim.api.nvim_get_commands({}).CompletionToolsInfo)
cmp.setup({ sources = {} })
vim.api.nvim_create_user_command(
  "CompletionToolsInfo",
  function() end,
  { force = true, desc = "owned by user" }
)
cmp.dispose()
local user_command = vim.api.nvim_get_commands({}).CompletionToolsInfo
assert(user_command and user_command.definition == "owned by user", vim.inspect(user_command))
vim.api.nvim_del_user_command("CompletionToolsInfo")
cmp.setup({ sources = {} })
vim.api.nvim_create_user_command(
  "CompletionToolsInfo",
  function() end,
  { force = true, desc = "Show completion source status, timings and cache statistics" }
)
cmp.dispose()
assert(vim.api.nvim_get_commands({}).CompletionToolsInfo, "same-description user command was removed")
vim.api.nvim_del_user_command("CompletionToolsInfo")
print("diagnostics: snapshots, counts, errors, health, command lifecycle and user ownership passed")
