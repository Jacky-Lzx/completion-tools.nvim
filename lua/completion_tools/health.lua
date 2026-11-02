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
end
return M
