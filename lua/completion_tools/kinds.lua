local M = {}

-- LSP CompletionItemKind values. Icons are measured in display cells by the layout.
local definitions = {
  { "Text", "󰉿", "Comment" },
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
  { "Snippet", "", "Special" },
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
  local shared = package.loaded["theme_tools.icons"]
  local group = "CompletionToolsKind" .. name
  local mode
  if type(shared) == "table" and type(shared.get) == "function" and icons ~= false then
    mode = shared.current()
    local shared_group
    icon, shared_group = shared.get("lsp", name)
    if icon ~= "" then
      group = shared_group
    end
  end
  if icons == false then
    icon = ""
  elseif mode ~= "ascii" and mode ~= "none" and type(icons) == "table" and icons[name] ~= nil then
    icon = icons[name]
  end
  return name, icon, group
end

function M.highlights()
  for _, definition in ipairs(vim.list_extend(vim.deepcopy(definitions), { unknown })) do
    vim.api.nvim_set_hl(0, "CompletionToolsKind" .. definition[1], { default = true, link = definition[3] })
  end
end

return M
