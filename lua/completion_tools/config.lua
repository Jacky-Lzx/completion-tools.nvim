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
  dictionary = {
    files = {},
    min_keyword_length = 3,
    max_items = 10,
    matching = "fuzzy",
    capitalize = true,
    max_bytes = 16 * 1024 * 1024,
    max_words = 500000,
    max_word_bytes = 256,
    timeout_ms = 5000,
  },
  spell = {
    min_keyword_length = 2,
    max_items = 3,
    debounce_ms = 60,
    timeout_ms = 5000,
    sort = "match",
    preselect_current_word = true,
    suggest_when_correct = false,
  },
  snippets = { preset = "default", collection = {} },
  cmdline = {
    enabled = false,
    auto_show = true,
    min_keyword_length = 1,
    types = { ":", "/", "?" },
    keymap = {
      ["<C-Space>"] = { "show", "fallback" },
      ["<Tab>"] = { "accept", "show", "fallback" },
      ["<S-Tab>"] = { "select_prev", "show", "fallback" },
      ["<C-n>"] = { "select_next", "fallback" },
      ["<C-p>"] = { "select_prev", "fallback" },
      ["<Up>"] = { "select_prev", "fallback" },
      ["<Down>"] = { "select_next", "fallback" },
    },
  },
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
  if opts.dictionary and opts.dictionary.files ~= nil then
    config.dictionary.files = opts.dictionary.files
  end
  if opts.cmdline then
    for _, field in ipairs({ "keymap", "types" }) do
      if opts.cmdline[field] ~= nil then
        config.cmdline[field] = vim.deepcopy(opts.cmdline[field])
      end
    end
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
  for _, section in ipairs({ "dictionary", "spell" }) do
    for _, field in ipairs({ "min_keyword_length", "max_items", "timeout_ms" }) do
      assert(integer(config[section][field], 1), "completion-tools: invalid " .. section .. "." .. field)
    end
  end
  local dict, spell = config.dictionary, config.spell
  local cmdline = config.cmdline
  assert(
    type(cmdline.enabled) == "boolean" and type(cmdline.auto_show) == "boolean",
    "completion-tools: invalid cmdline flags"
  )
  assert(integer(cmdline.min_keyword_length, 0), "completion-tools: invalid cmdline.min_keyword_length")
  assert(
    type(cmdline.keymap) == "table" and type(cmdline.types) == "table",
    "completion-tools: invalid cmdline maps/types"
  )
  assert(
    cmdline.get_anchor == nil or type(cmdline.get_anchor) == "function",
    "completion-tools: invalid cmdline.get_anchor"
  )
  for _, cmdtype in ipairs(cmdline.types) do
    assert(vim.tbl_contains({ ":", "/", "?" }, cmdtype), "completion-tools: unsupported cmdline type")
  end
  assert(
    type(dict.files) == "table" or type(dict.files) == "function",
    "completion-tools: invalid dictionary.files"
  )
  if type(dict.files) == "table" then
    for _, file in ipairs(dict.files) do
      assert(type(file) == "string" and file ~= "", "completion-tools: invalid dictionary path")
    end
  end
  for _, field in ipairs({ "max_bytes", "max_words", "max_word_bytes" }) do
    assert(integer(dict[field], 1), "completion-tools: invalid dictionary." .. field)
  end
  assert(
    dict.matching == "prefix" or dict.matching == "fuzzy",
    "completion-tools: invalid dictionary.matching"
  )
  assert(type(dict.capitalize) == "boolean", "completion-tools: invalid dictionary.capitalize")
  assert(integer(spell.debounce_ms, 0), "completion-tools: invalid spell.debounce_ms")
  assert(spell.sort == "match" or spell.sort == "suggestion", "completion-tools: invalid spell.sort")
  for _, field in ipairs({ "preselect_current_word", "suggest_when_correct" }) do
    assert(type(spell[field]) == "boolean", "completion-tools: invalid spell." .. field)
  end
  assert(
    spell.enable_in_context == nil or type(spell.enable_in_context) == "function",
    "completion-tools: invalid spell.enable_in_context"
  )
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
