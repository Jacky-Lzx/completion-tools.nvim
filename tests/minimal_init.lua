local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(vim.env.BASE_TOOLS_PATH or vim.fs.joinpath(vim.fs.dirname(root), "base-tools.nvim"))
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.shortmess = vim.o.shortmess .. "I"
vim.o.termguicolors = true
vim.o.lines = 36
vim.o.columns = 120
