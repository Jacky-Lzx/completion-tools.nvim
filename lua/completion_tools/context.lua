local M = {}

-- Return eligibility and whether an explicitly allowed character was typed.
-- Apply this before provider triggers and path/keyword length exceptions.
function M.can_auto_show(config, ctx)
  local character = ctx.before:match("[%z\1-\127\194-\244][\128-\191]*$") or ""
  local characters = config.trigger_characters
  if type(characters) == "function" then
    characters = characters(ctx)
  end
  if vim.list_contains(characters, character) then
    return true, true
  end
  -- Keep '_' as a word character, but block other ASCII punctuation even if
  -- a filetype includes it in 'iskeyword' or a custom keyword_pattern.
  local word = character ~= ""
    and (character == "_" or not character:find("[%p%s]"))
    and vim.fn.match(character, [[\k]]) == 0
  return word, false
end

function M.get(config)
  local mode = vim.api.nvim_get_mode().mode
  local cmdline = mode == "c"
  if not cmdline and mode:sub(1, 1) ~= "i" then
    return
  end
  local cmdtype = cmdline and vim.fn.getcmdtype() or nil
  if cmdline and (not config.cmdline.enabled or not vim.tbl_contains(config.cmdline.types, cmdtype)) then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not cmdline and (not vim.bo[bufnr].modifiable or vim.bo[bufnr].buftype == "prompt") then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cmdline and vim.fn.getcmdline() or vim.api.nvim_get_current_line()
  local col = cmdline and vim.fn.getcmdpos() - 1 or cursor[2]
  local before = line:sub(1, col)
  local details = cmdline and require("completion_tools.cmdline").describe(before, cmdtype)
  if cmdline and not details then
    return
  end
  local prefix = details and details.prefix or vim.fn.matchstr(before, config.keyword_pattern)
  return vim.tbl_extend("force", {
    bufnr = bufnr,
    winid = vim.api.nvim_get_current_win(),
    mode = cmdline and "cmdline" or "insert",
    row = cmdline and 0 or cursor[1] - 1,
    col = col,
    line = line,
    before = before,
    prefix = prefix,
    start_col = col - #prefix,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    filetype = vim.bo[bufnr].filetype,
    cmdtype = cmdtype,
  }, details or {})
end

function M.same(a, b)
  return a
    and b
    and a.bufnr == b.bufnr
    and a.winid == b.winid
    and a.mode == b.mode
    and a.cmdtype == b.cmdtype
    and a.filetype == b.filetype
    and a.row == b.row
    and a.col == b.col
    and a.line == b.line
    and a.tick == b.tick
end

-- Literal forward typing can cross keyword boundaries, unlike word-list reuse.
function M.advances(old, new)
  return old
    and new
    and old.bufnr == new.bufnr
    and old.winid == new.winid
    and old.filetype == new.filetype
    and old.mode == new.mode
    and old.row == new.row
    and new.col > old.col
    and new.before:sub(1, old.col) == old.before
    and old.line:sub(old.col + 1) == new.line:sub(new.col + 1)
end

-- Visual continuity only. Cache reuse deliberately keeps the stricter extends()
-- check, since cached edits are not safe across arbitrary prefix replacements.
function M.continues(old, new)
  return old
    and new
    and new.prefix ~= ""
    and old.bufnr == new.bufnr
    and old.winid == new.winid
    and old.mode == new.mode
    and old.cmdtype == new.cmdtype
    and old.filetype == new.filetype
    and old.row == new.row
    and old.start_col == new.start_col
    and old.line:sub(1, old.start_col) == new.line:sub(1, new.start_col)
    and old.line:sub(old.col + 1) == new.line:sub(new.col + 1)
end

function M.extends(old, new)
  return old
    and new
    and old.bufnr == new.bufnr
    and old.winid == new.winid
    and old.mode == new.mode
    and old.cmdtype == new.cmdtype
    and old.filetype == new.filetype
    and old.row == new.row
    and old.start_col == new.start_col
    and new.prefix:sub(1, #old.prefix) == old.prefix
    and old.line:sub(1, old.start_col) == new.line:sub(1, new.start_col)
    and old.line:sub(old.col + 1) == new.line:sub(new.col + 1)
end

return M
