local M = {}
local languages = {
  bash = "shellscript",
  bst = "bibtex",
  cs = "csharp",
  cuda = "cuda-cpp",
  dosbatch = "bat",
  dosini = "ini",
  gitcommit = "git-commit",
  gitrebase = "git-rebase",
  make = "makefile",
  objc = "objective-c",
  objcpp = "objective-cpp",
  ps1 = "powershell",
  raku = "perl6",
  sh = "shellscript",
  text = "plaintext",
}
function M.language(filetype, overrides)
  local short = filetype:match("^[^.]*")
  short = short ~= "" and short or "text"
  return (overrides or {})[filetype] or (overrides or {})[short] or languages[short] or short
end
function M.directory(path)
  path = vim.fn.fnamemodify(path, ":p")
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end
function M.root(buf, opts)
  local root = opts.root_dir
  if type(root) == "function" then
    root = root(buf)
  end
  root = root or vim.fs.root(buf, { ".git" }) or vim.fn.getcwd()
  assert(type(root) == "string" and root ~= "", "completion-tools: invalid copilot.root_dir result")
  return M.directory(root)
end
function M.relative(name, root)
  if name == "" then
    return ""
  end
  local parent = M.directory(vim.fs.dirname(vim.fn.fnamemodify(name, ":p")))
  local path = vim.fs.joinpath(parent, vim.fs.basename(name))
  local prefix = root == "/" and root or root .. "/"
  return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or vim.fs.basename(name)
end
return M
