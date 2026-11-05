-- The plugin owns its first-input lifecycle; package managers only register it.
local M = {}
local options, group
function M.ensure()
  local engine = require("completion_tools")
  if not engine.get_status().configured then
    engine.setup(vim.deepcopy(options or {}))
  end
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  return engine
end
function M.setup(opts)
  options = vim.deepcopy(opts or {})
  if group then
    vim.api.nvim_del_augroup_by_id(group)
  end
  group = vim.api.nvim_create_augroup("CompletionToolsBootstrap", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertEnter", "CmdlineEnter" }, { group = group, callback = M.ensure })
  vim.api.nvim_create_autocmd(
    "CmdUndefined",
    { group = group, pattern = "CompletionTools*", callback = M.ensure }
  )
end
return M
