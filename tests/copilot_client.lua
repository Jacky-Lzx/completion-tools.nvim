local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local log = vim.fn.tempname()
local native = require("completion_tools.copilot")
local function messages(method)
  local found = {}
  -- Only newline-terminated records are complete while the server is appending.
  local lines = vim.fn.filereadable(log) == 1 and vim.fn.readfile(log, "b") or {}
  for index = 1, #lines - 1 do
    local line = lines[index]
    local item = vim.json.decode(line)
    if method == nil or item.method == method then
      found[#found + 1] = item
    end
  end
  return found
end
local function wait(f)
  assert(vim.wait(2500, f, 5), "Copilot protocol timeout")
end
vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.tempname() .. ".lua"))
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(
  0,
  0,
  -1,
  false,
  { "-- preceding context", "中😀 = pr", "-- following context" }
)
local buf = vim.api.nvim_get_current_buf()
local manager = native.new({
  command = { "python3", "tests/fixtures/copilot_server.py", log },
  filetypes = { ["*"] = false, lua = true },
})
assert(not manager.get_status().running, "Server must start lazily")
local cancelled_called = false
manager.ensure(buf, function()
  cancelled_called = true
end)()
local client
manager.ensure(buf, function(c)
  client = c
end)
wait(function()
  return client ~= nil
end)
assert(not cancelled_called, "Cancelled startup waiter was invoked")
eq(1, #messages("initialize"))
assert(vim.lsp.buf_is_attached(buf, client.id))
local params = native.params({ bufnr = buf, row = 1, col = #"中😀 = pr", line = "中😀 = pr" })
eq(8, params.position.character)
local response
client:request("getCompletionsCycling", params, function(err, result)
  assert(not err, vim.inspect(err))
  response = result
end, buf)
wait(function()
  return response ~= nil
end)
eq(3, #response.completions)
eq("completion-tools.nvim", messages("initialize")[1].params.initializationOptions.editorPluginInfo.name)
eq("utf-16", client.offset_encoding)
wait(function()
  return #messages("textDocument/didFocus") > 0
end)
eq(vim.uri_from_bufnr(buf), messages("textDocument/didOpen")[1].params.textDocument.uri)
eq(
  "-- preceding context\n中😀 = pr\n-- following context\n",
  messages("textDocument/didOpen")[1].params.textDocument.text
)
eq(1, messages("getCompletionsCycling")[1].params.position.line)
-- Built-in LSP synchronization flushes changes before completion requests.
vim.api.nvim_buf_set_text(buf, 1, #"中😀 = pr", 1, #"中😀 = pr", { "i" })
response = nil
params = native.params({ bufnr = buf, row = 1, col = #"中😀 = pri", line = "中😀 = pri" })
client:request("getCompletionsCycling", params, function(_, result)
  response = result
end, buf)
wait(function()
  return response ~= nil
end)
local change = messages("textDocument/didChange")[1].params
assert(change.contentChanges[1].range, "Expected incremental text sync")
eq(change.textDocument.version, messages("getCompletionsCycling")[2].params.textDocument.version)
local old_uri = vim.uri_from_bufnr(buf)
local old_closes = #messages("textDocument/didClose")
vim.api.nvim_buf_set_text(buf, 1, #"中😀 = pri", 1, #"中😀 = pri", { "nt" })
vim.cmd("file " .. vim.fn.fnameescape(vim.fn.tempname() .. ".lua"))
local renamed_uri = vim.uri_from_bufnr(buf)
wait(function()
  local opens = messages("textDocument/didOpen")
  return opens[#opens].params.textDocument.uri == renamed_uri
end)
eq(old_closes + 1, #messages("textDocument/didClose"))
eq(old_uri, messages("textDocument/didClose")[old_closes + 1].params.textDocument.uri)
assert(messages("textDocument/didOpen")[2].params.textDocument.text:find("print", 1, true))
local ordered = {}
for _, m in ipairs(messages()) do
  if m.method == "textDocument/didChange" and m.params.textDocument.uri == old_uri then
    ordered.change = #ordered + 1
  elseif m.method == "textDocument/didClose" and m.params.textDocument.uri == old_uri then
    ordered.close = #ordered + 1
  elseif m.method == "textDocument/didOpen" and m.params.textDocument.uri == renamed_uri then
    ordered.open = #ordered + 1
  end
  ordered[#ordered + 1] = m.method or "response"
end
assert(ordered.change < ordered.close and ordered.close < ordered.open)
local opens_before_failure = #messages("textDocument/didOpen")
vim.api.nvim_create_autocmd("BufFilePre", { once = true, command = "throw 'fixture rename failure'" })
assert(not pcall(vim.cmd, "file " .. vim.fn.fnameescape(vim.fn.tempname() .. ".lua")))
wait(function()
  return vim.lsp.buf_is_attached(buf, client.id) and #messages("textDocument/didOpen") > opens_before_failure
end)
eq(
  vim.uri_from_bufnr(buf),
  messages("textDocument/didOpen")[#messages("textDocument/didOpen")].params.textDocument.uri
)

-- A new unnamed buffer is closed under its old URI before its first :write.
vim.cmd("enew!")
vim.bo.filetype = "lua"
local unnamed = vim.api.nvim_get_current_buf()
manager.ensure(unnamed, function(c)
  eq(client.id, c.id)
end)
local unnamed_uri = vim.uri_from_bufnr(unnamed)
vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, { "local saved = true" })
local saved_name = vim.fn.tempname() .. ".lua"
vim.cmd("silent write " .. vim.fn.fnameescape(saved_name))
local saved_uri = vim.uri_from_bufnr(unnamed)
wait(function()
  local opens = messages("textDocument/didOpen")
  return opens[#opens].params.textDocument.uri == saved_uri
end)
assert(unnamed_uri ~= saved_uri and vim.lsp.buf_is_attached(unnamed, client.id))
local closed_unnamed = false
for _, m in ipairs(messages("textDocument/didClose")) do
  closed_unnamed = closed_unnamed or m.params.textDocument.uri == unnamed_uri
end
assert(closed_unnamed)
vim.fn.delete(saved_name)
vim.api.nvim_set_current_buf(buf)
local notify = vim.notify
local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
manager.command("auth")
wait(function()
  return #messages("workspace/executeCommand") > 0
end)
eq("fixture.finishDeviceFlow", messages("workspace/executeCommand")[1].params.command)
assert(table.concat(notifications):find("TEST%-CODE"))
manager.command("disable")
assert(not manager.eligible(buf))
assert(not vim.lsp.buf_is_attached(buf, client.id))
manager.command("enable")
assert(manager.eligible(buf))
manager.ensure(buf, function(c)
  eq(client.id, c.id)
end)
assert(vim.lsp.buf_is_attached(buf, client.id))
vim.bo.filetype = "markdown"
assert(not manager.eligible(buf))
assert(not vim.lsp.buf_is_attached(buf, client.id))
vim.bo.filetype = "lua"
vim.bo.buftype = "nofile"
assert(not manager.eligible(buf))
vim.bo.buftype = ""
local old_id = client.id
manager.command("restart")
client = nil
manager.ensure(buf, function(c)
  client = c
end)
wait(function()
  return client ~= nil
end)
assert(client.id ~= old_id)
manager.command("signout")
wait(function()
  return #messages("signOut") == 1
end)
manager.dispose()
assert(not vim.api.nvim_get_commands({}).CompletionToolsCopilot)
assert(not package.loaded["copilot.client"] and not package.loaded["copilot.api"])
wait(function()
  return client:is_stopped()
end)
manager = native.new({ command = { "completion-tools-nonexistent-server" } })
local unavailable = false
manager.ensure(buf, function(c, err)
  eq(nil, c)
  assert(err:find("Server executable not found"))
  unavailable = true
end)
assert(unavailable)
assert(manager.get_status().last_error)
manager.dispose()
vim.notify = notify
vim.fn.delete(log)
print(
  "copilot client: lazy startup, cancellation, UTF-16 incremental sync, auth, policies, restart and disposal passed"
)
