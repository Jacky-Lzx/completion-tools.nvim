local M = {}
local ns = vim.api.nvim_create_namespace("completion-tools-snippet-indent")

-- Completion inserts delimiters as text, independently of insert-mode mappings.
function M.brackets(text, item, suffix)
  if item.insertTextFormat == 2 or (item.kind ~= 2 and item.kind ~= 3) or suffix:match("^%s*%(") then
    return text, 0
  end
  if text ~= "" and not text:find("[()\n]") then
    return text .. "()", 1
  end
  if text:sub(-1) == "(" and not text:sub(1, -2):find("[()\n]") then
    return text .. ")", 1
  end
  return text, 0
end

-- Preserve relative indentation, shifting continuation lines from the first
-- line's indentation to that of the receiving line before the cursor.
function M.indent(text, indentation)
  local lines = vim.split(text, "\n", { plain = true })
  local base = lines[1]:match("^[ \t]*")
  for i = 2, #lines do
    local line = lines[i]
    if line:sub(1, #base) == base then
      line = line:sub(#base + 1)
    end
    lines[i] = line ~= "" and indentation .. line or ""
  end
  return table.concat(lines, "\n")
end

function M.expand(text, config, options)
  if config.snippets.expand then
    -- Custom engines receive already-adjusted text and can disable their own
    -- indentation when an explicit insert_text_mode is present.
    return config.snippets.expand(text, options)
  end
  local mode = options.insert_text_mode
  if not mode then
    return vim.snippet.expand(text)
  end
  local buf, win = options.bufnr, vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local base = vim.api.nvim_get_current_line():match("^[ \t]*")
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, row, col, { right_gravity = true })
  local expandtab = vim.bo[buf].expandtab
  if mode == 1 then
    vim.bo[buf].expandtab = false
  end
  -- Native expand queues selection keys using absolute positions. Defer that
  -- first jump until indentation edits have moved the placeholder extmarks.
  local jump = vim.snippet.jump
  vim.snippet.jump = function() end
  local ok, err = pcall(vim.snippet.expand, text)
  vim.snippet.jump = jump
  vim.bo[buf].expandtab = expandtab
  if ok then
    -- vim.snippet always adds the current indentation. Remove that implicit
    -- prefix while retaining native placeholder extmarks and their selections.
    local finish = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    for line = finish[1], row + 1, -1 do
      local value = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
      if #base > 0 and value:sub(1, #base) == base then
        pcall(vim.cmd, "undojoin")
        vim.api.nvim_buf_set_text(buf, line, 0, line, #base, { "" })
      end
    end
  end
  vim.api.nvim_buf_del_extmark(buf, ns, mark)
  if not ok then
    error(err)
  end
  jump(1)
end

return M
