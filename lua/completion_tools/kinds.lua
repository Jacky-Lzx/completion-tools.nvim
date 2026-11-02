local M = {}

-- LSP CompletionItemKind values. Icons are measured in display cells by the layout.
local definitions = {
  { "Text", "󰉿", "@string" },
  { "Method", "󰆧", "@function.method" },
  { "Function", "󰊕", "@function" },
  { "Constructor", "", "@constructor" },
  { "Field", "󰜢", "@variable.member" },
  { "Variable", "󰀫", "@variable" },
  { "Class", "󰠱", "@type" },
  { "Interface", "", "@type" },
  { "Module", "", "@module" },
  { "Property", "󰜢", "@property" },
  { "Unit", "󰑭", "@number" },
  { "Value", "󰎠", "@constant" },
  { "Enum", "", "@type" },
  { "Keyword", "󰌋", "@keyword" },
  { "Snippet", "", "@markup" },
  { "Color", "󰏘", "Special" },
  { "File", "󰈙", "Directory" },
  { "Reference", "󰈇", "@variable" },
  { "Folder", "󰉋", "Directory" },
  { "EnumMember", "", "@constant" },
  { "Constant", "󰏿", "@constant" },
  { "Struct", "󰙅", "@type" },
  { "Event", "", "@type" },
  { "Operator", "󰆕", "@operator" },
  { "TypeParameter", "󰅲", "@type" },
}
local unknown = { "Unknown", "?", "Special" }

function M.get(kind, icons)
  local definition = definitions[kind or 1] or unknown
  local name, icon = definition[1], definition[2]
  if icons == false then
    icon = ""
  elseif type(icons) == "table" and icons[name] ~= nil then
    icon = icons[name]
  end
  return name, icon, "CompletionToolsKind" .. name
end

function M.highlights()
  for _, definition in ipairs(vim.list_extend(vim.deepcopy(definitions), { unknown })) do
    vim.api.nvim_set_hl(0, "CompletionToolsKind" .. definition[1], { default = true, link = definition[3] })
  end
end

return M
