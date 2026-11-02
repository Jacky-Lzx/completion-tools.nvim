local M = {}
local function argument_start(before)
  local start, escaped = 0, false
  for i = 1, #before do
    local char = before:sub(i, i)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char:match("%s") then
      start = i
    end
  end
  return start
end

local function command(before)
  local parsed
  for _ = 1, 16 do
    local ok, value = pcall(vim.api.nvim_parse_cmd, before, {})
    if not ok then
      return
    end
    parsed = value
    if not value.nextcmd or value.nextcmd == "" then
      return parsed
    end
    before = value.nextcmd
  end
end

function M.describe(before, cmdtype)
  if cmdtype ~= ":" then
    local prefix = vim.fn.matchstr(before, [[\k*$]])
    local start = #before - #prefix
    -- Keep the common Vim regexp mode/case flags outside the word replacement.
    local escaping = before:sub(1, start):match("\\+$") or ""
    if #escaping % 2 == 1 and prefix:match("^[vVmMcC]") then
      prefix, start = prefix:sub(2), start + 1
    end
    return { prefix = prefix, start_col = start }
  end
  local pattern, kind = vim.fn.getcmdcomplpat(), vim.fn.getcmdcompltype()
  local parsed = command(before)
  if kind == "shellcmd" or kind == "shellcmdline" then
    return
  end
  if kind ~= "command" then
    if before:match("^%s*[%%0-9,'<>%-]*!") then
      return
    end
    if parsed then
      if parsed.cmd == "!" or parsed.cmd == "terminal" then
        return
      end
      if parsed.cmd == "read" or parsed.cmd == "write" then
        for _, arg in ipairs(parsed.args or {}) do
          if arg:sub(1, 1) == "!" then
            return
          end
        end
      end
    end
  end
  if
    (kind == "file" or kind == "dir" or kind == "file_in_path" or kind == "dir_in_path")
    and pattern:find("`", 1, true)
  then
    return
  end
  if #pattern > #before or before:sub(#before - #pattern + 1) ~= pattern then
    -- The native pattern may extend beyond the cursor. Reconstruct only the
    -- current argument, keeping escaped whitespace and option assignments.
    local start = argument_start(before)
    if parsed and parsed.cmd:match("^set") and (kind == "file" or kind == "dir") then
      local _, ending = before:sub(start + 1):find("^[%w_]+[+^%-]?=")
      start = ending and start + ending or start
      for i = start + 1, #before do
        if before:sub(i, i) == "," and before:sub(i - 1, i - 1) ~= "\\" then
          start = i
        end
      end
    end
    pattern = before:sub(start + 1)
  end
  local prefix = kind == "lua" and pattern:match("[^%.:]*$") or pattern
  return {
    prefix = prefix,
    start_col = #before - #prefix,
    completion_type = kind,
    command = parsed and parsed.cmd,
    argument_trigger = before:find("%S") ~= nil and prefix == "",
  }
end

return M
