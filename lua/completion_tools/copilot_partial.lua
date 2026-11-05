local M = {}
local function units(text)
  return vim.str_utfindex(text, "utf-16", #text, false)
end
local function word_end(text)
  local seen, finish = false, #text
  for at, char in text:gmatch("()([%z\1-\127\194-\244][\128-\191]*)") do
    local word = char == "_" or (not char:find("[%p%s]") and vim.fn.match(char, [[\k]]) == 0)
    if seen and not word then
      finish = at - 1
      break
    end
    seen = seen or word
  end
  local spaces = text:sub(finish + 1):match("^[ \t]*") or ""
  return finish + #spaces
end
function M.plan(item, ctx, part, normalise)
  local edit, cursor = item.textEdit, units(ctx.before)
  local range = edit.range
  if
    range.start.line ~= ctx.row
    or range.start.character > cursor
    or range["end"].line < ctx.row
    or (range["end"].line == ctx.row and range["end"].character < cursor)
  then
    return
  end
  local start = vim.str_byteindex(ctx.line, "utf-16", range.start.character, false)
  local typed = ctx.before:sub(start + 1)
  if edit.newText:sub(1, #typed) ~= typed then
    return
  end
  local remaining = edit.newText:sub(#typed + 1)
  local piece
  if part == "line" then
    piece = remaining:match("^[^\n]*\n[ \t]*") or remaining
  else
    piece = remaining:sub(1, word_end(remaining))
  end
  if piece == "" then
    return
  end
  local rest = remaining:sub(#piece + 1)
  if vim.trim(rest) == "" then
    return { full = true }
  end
  local offset = (item._copilot_offset or 0) + units(typed)
  local partial = vim.tbl_extend("force", {}, item, {
    textEdit = {
      newText = piece,
      range = {
        start = { line = ctx.row, character = cursor },
        ["end"] = { line = ctx.row, character = cursor },
      },
    },
    _copilot_offset = offset,
  })
  return {
    item = partial,
    continue = function(next)
      local finish = vim.deepcopy(range["end"])
      if finish.line == ctx.row then
        finish.line = next.row
        finish.character = units(next.before) + finish.character - cursor
      else
        finish.line = finish.line + next.row - ctx.row
      end
      local candidate = normalise({
        text = rest,
        uuid = item._copilot_uuid,
        accepted_offset = offset + units(piece),
        range = { start = { line = next.row, character = units(next.before) }, ["end"] = finish },
      }, next, item._copilot_client)
      return candidate and { items = { candidate } } or nil
    end,
  }
end
return M
