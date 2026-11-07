local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local native = require("completion_tools.copilot")
local context = require("completion_tools.copilot_context")
local tmp, log = vim.fn.tempname(), vim.fn.tempname()
for _, path in ipairs({ "a/.git", "a/src", "b/.git", "extra" }) do
  vim.fn.mkdir(tmp .. "/" .. path, "p")
end
local function messages(method)
  local found = {}
  -- Only newline-terminated records are complete while the server is appending.
  local lines = vim.fn.filereadable(log) == 1 and vim.fn.readfile(log, "b") or {}
  for index = 1, #lines - 1 do
    local line = lines[index]
    local m = vim.json.decode(line)
    if m.method == method then
      found[#found + 1] = m
    end
  end
  return found
end
-- A poll can observe the next JSON record before its final bytes and newline.
vim.fn.writefile({ '{"method":"fixture/complete"}', '{"method":' }, log, "b")
eq(1, #messages("fixture/complete"))
vim.fn.writefile({ '{"method":"fixture/complete"}', '{"method":"fixture/complete"}' }, log)
eq(2, #messages("fixture/complete"))
vim.fn.delete(log)
local function wait(fn)
  assert(vim.wait(2500, fn, 5), "workspace protocol timeout")
end
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/a/src/main.sh"))
vim.bo.filetype = "sh"
local a = vim.api.nvim_get_current_buf()
local manager = native.new({
  command = { "python3", "tests/fixtures/copilot_server.py", log },
  workspace_folders = { tmp .. "/extra", tmp .. "/extra/." },
  language_ids = { ["sh.custom"] = "custom-shell" },
})
local client
manager.ensure(a, function(c)
  client = c
end)
wait(function()
  return client ~= nil and #messages("textDocument/didOpen") > 0
end)
local initialize = messages("initialize")[1].params
eq(vim.uri_from_fname(context.directory(tmp .. "/a")), initialize.rootUri)
eq(2, #initialize.workspaceFolders)
eq("shellscript", messages("textDocument/didOpen")[1].params.textDocument.languageId)
eq("src/main.sh", manager.params({ bufnr = a, row = 0, col = 0, line = "" }).doc.relativePath)

vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/b/main.lua"))
vim.bo.filetype = "lua"
local b = vim.api.nvim_get_current_buf()
manager.ensure(b, function(c)
  eq(client.id, c.id)
end)
wait(function()
  return #messages("workspace/didChangeWorkspaceFolders") == 1
end)
eq(
  vim.uri_from_fname(context.directory(tmp .. "/b")),
  messages("workspace/didChangeWorkspaceFolders")[1].params.event.added[1].uri
)
eq("main.lua", manager.params({ bufnr = b, row = 0, col = 0, line = "" }).doc.relativePath)
vim.api.nvim_set_current_buf(a)
manager.ensure(a, function(c)
  eq(client.id, c.id)
end)
vim.bo.filetype = "sh.custom"
wait(function()
  local opens = messages("textDocument/didOpen")
  return opens[#opens].params.textDocument.languageId == "custom-shell"
end)
eq(1, #messages("initialize"))
eq(1, #messages("workspace/didChangeWorkspaceFolders"))
eq(3, #manager.get_status().workspace_folders)
eq("shellscript", context.language("sh.template"))
eq("plaintext", context.language(""))
eq("csharp", context.language("cs"))
manager.dispose()

local root_calls = 0
manager = native.new({
  command = { "python3", "tests/fixtures/copilot_server.py", log },
  root_dir = function(buf)
    eq(b, buf)
    root_calls = root_calls + 1
    return tmp .. "/a"
  end,
})
local overridden
manager.ensure(b, function(c)
  overridden = c
end)
wait(function()
  return overridden ~= nil
end)
eq(context.directory(tmp .. "/a"), overridden.config.root_dir)
eq("main.lua", manager.params({ bufnr = b, row = 0, col = 0, line = "" }).doc.relativePath)
assert(root_calls >= 2)
manager.dispose()
for _, opts in ipairs({
  { root_dir = 1 },
  { root_dir = "" },
  { workspace_folders = { false } },
  { workspace_folders = { "" } },
  { language_ids = { sh = false } },
}) do
  assert(not pcall(require("completion_tools.config").validate, { copilot = opts }))
end
vim.fn.delete(tmp, "rf")
vim.fn.delete(log)
print("copilot workspace: multi-root sync, canonical deduplication, language IDs and relative paths passed")
