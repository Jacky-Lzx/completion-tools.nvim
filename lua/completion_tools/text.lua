local M = {}
M.characters = "[%z\1-\127\194-\244][\128-\191]*"

function M.clean(text, max_bytes)
  text = type(text) == "string" and text or ""
  if #text <= max_bytes then
    return (text:gsub("[%c]", " "))
  end
  local ending = math.max(0, max_bytes - 3)
  while ending > 0 and (text:byte(ending + 1) or 0) >= 128 and text:byte(ending + 1) < 192 do
    ending = ending - 1
  end
  return (text:sub(1, ending):gsub("[%c]", " ")) .. "…"
end

-- Return the number of retained original bytes as well as the display text.
function M.truncate(text, width)
  if width <= 0 then
    return "", 0
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text, #text
  end
  local result = ""
  for char in text:gmatch(M.characters) do
    if vim.fn.strdisplaywidth(result .. char) > width - 1 then
      break
    end
    result = result .. char
  end
  return result .. "…", #result
end

-- Paths are distinguished by their last components, not their shared prefix.
function M.truncate_path(value, width)
  if width <= 0 then
    return "", 0
  end
  if vim.fn.strdisplaywidth(value) <= width then
    return value, #value
  end
  local chars, suffix = {}, ""
  for char in value:gmatch(M.characters) do
    chars[#chars + 1] = char
  end
  for i = #chars, 1, -1 do
    if vim.fn.strdisplaywidth(chars[i] .. suffix) > width - 1 then
      break
    end
    suffix = chars[i] .. suffix
  end
  return "…" .. suffix, 0
end

return M
