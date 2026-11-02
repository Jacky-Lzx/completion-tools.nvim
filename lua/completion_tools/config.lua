local M = {}

M.defaults = {
  enabled = true,
  auto_show = true,
  min_keyword_length = 1,
  debounce_ms = 0,
  max_items = 50,
  preselect = true,
  keyword_pattern = [[\k*$]],
  sources = { "lsp", "path", "buffer", "snippets" },
  providers = {},
  keymap = {
    ["<C-Space>"] = { "show", "show_documentation" },
    ["<C-n>"] = { "select_next", "fallback" },
    ["<C-p>"] = { "select_prev", "fallback" },
    ["<C-y>"] = { "accept", "fallback" },
    ["<C-e>"] = { "hide", "fallback" },
    ["<Tab>"] = { "accept", "snippet_forward", "fallback" },
    ["<S-Tab>"] = { "snippet_backward", "fallback" },
  },
  menu = {
    max_height = 12,
    min_width = 18,
    max_width = 72,
    border = "single",
    columns = { { "kind_icon" }, { "label", gap = 1 }, { "kind" } },
    column_gap = 1,
    padding = 1,
    kind_icons = true,
    label_details = true,
    max_label_bytes = 1024,
    highlight = { enabled = true, treesitter = true, max_bytes = 1024, cache_size = 512 },
  },
  documentation = { auto_show = true, delay_ms = 150, max_width = 72, max_height = 18, border = "single" },
  buffer = { max_bytes = 1024 * 1024, max_words = 20000, max_buffers = 8, batch_lines = 128, min_length = 3 },
  path = { max_entries = 10000, cache_ms = 1000, show_hidden = false },
  snippets = { preset = "default", collection = {} },
  cmdline = { enabled = false, min_keyword_length = 1 },
}

function M.validate(opts)
  assert(type(opts) == "table", "completion-tools: setup expects a table")
  local config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Lists and keymaps are replacements. An empty table must disable them.
  if opts.sources ~= nil then
    config.sources = opts.sources
  end
  if opts.keymap ~= nil then
    config.keymap = opts.keymap
  end
  if opts.menu and opts.menu.columns ~= nil then
    config.menu.columns = vim.deepcopy(opts.menu.columns)
  end
  for _, name in ipairs({ "max_items", "min_keyword_length", "debounce_ms" }) do
    assert(type(config[name]) == "number" and config[name] >= 0, "completion-tools: invalid " .. name)
  end
  assert(
    config.max_items >= 1 and config.max_items % 1 == 0,
    "completion-tools: max_items must be a positive integer"
  )
  for _, field in ipairs({ "max_bytes", "max_words", "max_buffers", "batch_lines", "min_length" }) do
    assert(
      type(config.buffer[field]) == "number" and config.buffer[field] >= 1,
      "completion-tools: buffer." .. field .. " must be positive"
    )
  end
  assert(
    type(config.sources) == "table" or type(config.sources) == "function",
    "completion-tools: invalid sources"
  )
  assert(type(config.keymap) == "table", "completion-tools: invalid keymap")
  assert(type(config.keyword_pattern) == "string", "completion-tools: invalid keyword_pattern")
  for _, section in ipairs({ "menu", "documentation" }) do
    for _, field in ipairs({ "max_width", "max_height" }) do
      assert(
        type(config[section][field]) == "number"
          and config[section][field] >= 1
          and config[section][field] % 1 == 0,
        "completion-tools: invalid " .. section .. "." .. field
      )
    end
  end
  assert(
    config.menu.min_width >= 1 and config.menu.min_width <= config.menu.max_width,
    "completion-tools: invalid menu.min_width"
  )
  local menu, components, seen = config.menu, require("completion_tools.render").components, {}
  local function integer(value, minimum)
    return type(value) == "number" and value >= minimum and value % 1 == 0
  end
  assert(type(menu.columns) == "table" and #menu.columns > 0, "completion-tools: empty menu.columns")
  for _, column in ipairs(menu.columns) do
    assert(type(column) == "table" and #column > 0, "completion-tools: invalid menu column")
    assert(column.gap == nil or integer(column.gap, 0), "completion-tools: invalid column gap")
    for _, name in ipairs(column) do
      assert(components[name] and not seen[name], "completion-tools: unknown or repeated menu component")
      seen[name] = true
    end
  end
  for _, field in ipairs({ "column_gap", "padding" }) do
    assert(integer(menu[field], 0), "completion-tools: invalid menu." .. field)
  end
  assert(integer(menu.max_label_bytes, 4), "completion-tools: invalid menu.max_label_bytes")
  assert(
    type(menu.kind_icons) == "boolean" or type(menu.kind_icons) == "table",
    "completion-tools: invalid kind_icons"
  )
  if type(menu.kind_icons) == "table" then
    for _, icon in pairs(menu.kind_icons) do
      assert(type(icon) == "string", "completion-tools: kind icons must be strings")
    end
  end
  assert(type(menu.label_details) == "boolean", "completion-tools: invalid label_details")
  assert(type(menu.highlight) == "table", "completion-tools: invalid menu.highlight")
  assert(
    type(menu.highlight.enabled) == "boolean" and type(menu.highlight.treesitter) == "boolean",
    "completion-tools: invalid highlight flags"
  )
  assert(
    integer(menu.highlight.cache_size, 0) and integer(menu.highlight.max_bytes, 1),
    "completion-tools: invalid highlight limits"
  )
  assert(
    menu.highlight.custom == nil or type(menu.highlight.custom) == "function",
    "completion-tools: invalid highlight callback"
  )
  assert(config.path.max_entries >= 1 and config.path.cache_ms >= 0, "completion-tools: invalid path limits")
  assert(config.documentation.delay_ms >= 0, "completion-tools: invalid documentation delay")
  assert(
    config.snippets.preset == "default" or config.snippets.preset == "luasnip",
    "completion-tools: invalid snippets.preset"
  )
  if config.snippets.preset == "luasnip" then
    config.snippets.expand = config.snippets.expand
      or function(text)
        require("luasnip").lsp_expand(text)
      end
    config.snippets.active = config.snippets.active
      or function(direction)
        return require("luasnip").locally_jumpable(direction)
      end
    config.snippets.jump = config.snippets.jump
      or function(direction)
        local ls = require("luasnip")
        if ls.locally_jumpable(direction) then
          ls.jump(direction)
          return true
        end
        return false
      end
  end
  return config
end

return M
