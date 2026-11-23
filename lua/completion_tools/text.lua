local M = {}
M.characters = "[%z\1-\127\194-\244][\128-\191]*"

function M.clean(text, max_bytes)
  text = type(text) == "string" and text or ""
  if #text <= max_bytes then
    return (text:gsub("[%c]", " "))
  end

  -- Reserve three bytes for the UTF-8 ellipsis.
  local ending = math.max(0, max_bytes - 3)
  -- If the first excluded byte is a continuation byte, drop the partial character.
  while ending > 0 and (text:byte(ending + 1) or 0) >= 128 and text:byte(ending + 1) < 192 do
    ending = ending - 1
  end
  return (text:sub(1, ending):gsub("[%c]", " ")) .. "…"
end

return M
