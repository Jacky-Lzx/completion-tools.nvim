local M = {}

---@class completion_tools.MenuColumn
---@field [integer] string Component name in display order.
---@field gap? integer Spacing between components in this column group.

---@class completion_tools.MenuHighlightOptions
---@field enabled boolean Enable highlighting in the menu.
---@field treesitter boolean Use Tree-sitter highlight queries when available.
---@field max_bytes integer Byte limit for Tree-sitter parsing.
---@field cache_size integer Maximum number of cached highlight results.
---@field custom? fun(entry: completion_tools.Entry, ctx: table, text: string): table[]|nil Optional extra highlight spans.

--- Completion menu options with defaults applied.
---@class completion_tools.MenuOptions
---@field max_height integer Maximum height in rows.
---@field inverse boolean|"auto" Candidate order when positioning the menu.
---@field shrink_delay_ms integer Delay before reducing the menu height.
---@field update_interval_ms integer Minimum interval between menu paints.
---@field min_width integer Preferred minimum width in display cells.
---@field max_width integer Maximum width in display cells.
---@field border string|table Neovim floating-window border style or specification.
---@field columns completion_tools.MenuColumn[] Ordered groups of menu components.
---@field column_gap integer Spacing between column groups.
---@field padding integer Left and right padding in display cells.
---@field kind_icons boolean|table<string, string> Enable default icons or override icons by kind name.
---@field label_details boolean Include supplemental label details in the default layout.
---@field max_label_bytes integer Byte limit applied when preparing display text.
---@field highlight completion_tools.MenuHighlightOptions Highlight settings.

M.defaults = {
  enabled = true,
  auto_show = true,
  trigger_characters = { "." },
  min_keyword_length = 1,
  debounce_ms = 0,
  timeout_ms = 2000,
  max_items = 50,
  preselect = true,
  accept = { mode = "replace", auto_brackets = true },
  ranking = {
    history = { enabled = false, max_entries = 1000 },
    proximity = { enabled = false, lines = 50 },
    max_typos = 0,
  },
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
    inverse = "auto",
    shrink_delay_ms = 50,
    update_interval_ms = 16,
    min_width = 18,
    max_width = 72,
    border = "single",
    columns = { { "kind_icon" }, { "label", gap = 1 }, { "kind" }, { "source" } },
    column_gap = 1,
    padding = 1,
    kind_icons = true,
    label_details = true,
    max_label_bytes = 1024,
    highlight = { enabled = true, treesitter = true, max_bytes = 1024, cache_size = 512 },
  },
  documentation = { auto_show = true, delay_ms = 150, max_width = 72, max_height = 18, border = "single" },
  buffer = { max_bytes = 1024 * 1024, max_words = 20000, max_buffers = 8, batch_lines = 128, min_length = 3 },
  path = {
    max_entries = 10000,
    cache_ms = 1000,
    show_hidden = false,
    preview = { enabled = true, max_bytes = 64 * 1024, max_lines = 100 },
  },
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
    documentation = { enabled = true, command = "wn", timeout_ms = 1500 },
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
  snippets = { collection = {} },
  copilot = {
    debounce_ms = 150,
    request_mode = "cycling",
    max_items = 3,
    show_status = true,
    command = { "copilot-language-server", "--stdio" },
    filetypes = {},
    settings = {},
    workspace_folders = {},
    language_ids = {},
  },
  cmdline = {
    enabled = false,
    auto_show = true,
    fuzzy = true,
    min_keyword_length = 1,
    types = { ":", "/", "?" },
    sources = {
      [":"] = { "cmdline" },
      ["/"] = { "buffer" },
      ["?"] = { "buffer" },
    },
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

local function replace_fields(target, overrides, fields, copy)
  if not overrides then
    return
  end

  for _, field in ipairs(fields) do
    local value = overrides[field]
    if value ~= nil then
      if copy then
        value = copy(value)
      end
      target[field] = value
    end
  end
end

local function merge_options(opts)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- These fields replace the defaults even when the override is empty.
  replace_fields(config.copilot, opts.copilot, { "command", "workspace_folders" }, vim.deepcopy)
  replace_fields(config, opts, { "sources", "trigger_characters", "keymap" })
  replace_fields(config.menu, opts.menu, { "columns" }, vim.deepcopy)
  replace_fields(config.dictionary, opts.dictionary, { "files" })
  replace_fields(config.cmdline, opts.cmdline, { "keymap", "types" }, vim.deepcopy)

  local cmdline_sources = opts.cmdline and opts.cmdline.sources
  if type(cmdline_sources) == "table" then
    replace_fields(config.cmdline.sources, cmdline_sources, M.defaults.cmdline.types, vim.deepcopy)
  end

  return config
end

local function integer(value, minimum)
  return type(value) == "number" and value >= minimum and value % 1 == 0
end

local function optional_integer(value, minimum)
  return value == nil or integer(value, minimum)
end

local function optional_function(value)
  return value == nil or type(value) == "function"
end

local function validate_general(config)
  for _, name in ipairs({ "max_items", "min_keyword_length", "debounce_ms" }) do
    assert(type(config[name]) == "number" and config[name] >= 0, "completion-tools: invalid " .. name)
  end
  assert(config.max_items >= 1 and config.max_items % 1 == 0, "completion-tools: max_items must be a positive integer")
  for _, field in ipairs({ "max_bytes", "max_words", "max_buffers", "batch_lines", "min_length" }) do
    assert(
      type(config.buffer[field]) == "number" and config.buffer[field] >= 1,
      "completion-tools: buffer." .. field .. " must be positive"
    )
  end
  assert(type(config.sources) == "table" or type(config.sources) == "function", "completion-tools: invalid sources")
  config._keymap_bindings = require("base_tools.keymap").resolve(config.keymap, { name = "completion-tools.keymap" })
  assert(type(config.keyword_pattern) == "string", "completion-tools: invalid keyword_pattern")
  assert(
    type(config.trigger_characters) == "table" or type(config.trigger_characters) == "function",
    "completion-tools: invalid trigger_characters"
  )
  if type(config.trigger_characters) == "table" then
    for _, character in ipairs(config.trigger_characters) do
      assert(
        type(character) == "string" and vim.fn.strchars(character) == 1,
        "completion-tools: trigger_characters must contain single characters"
      )
    end
  end
  assert(config.accept.mode == "insert" or config.accept.mode == "replace", "completion-tools: invalid accept.mode")
  assert(
    type(config.accept.auto_brackets) == "boolean" or type(config.accept.auto_brackets) == "function",
    "completion-tools: invalid accept.auto_brackets"
  )
  assert(integer(config.timeout_ms, 0), "completion-tools: invalid timeout_ms")
end

local function validate_window_size(window, section)
  for _, field in ipairs({ "max_width", "max_height" }) do
    assert(integer(window[field], 1), "completion-tools: invalid " .. section .. "." .. field)
  end
end

local function validate_providers(providers)
  local visiting, visited = {}, {}
  local function visit(id)
    assert(not visiting[id], "completion-tools: cyclic provider fallback_for: " .. id)
    if visited[id] then
      return
    end
    visiting[id] = true
    local provider = providers[id] or {}
    assert(optional_integer(provider.insert_at, 1), "completion-tools: invalid provider insert_at")
    local client_order = provider.client_order
    if client_order ~= nil then
      assert(
        id == "lsp" and type(client_order) == "table" and vim.islist(client_order),
        "completion-tools: client_order must be an LSP client name list"
      )
      local seen = {}
      for _, name in ipairs(client_order) do
        assert(
          type(name) == "string" and name ~= "" and not seen[name],
          "completion-tools: client_order expects unique nonempty client names"
        )
        seen[name] = true
      end
    end
    assert(optional_integer(provider.timeout_ms, 0), "completion-tools: invalid provider timeout_ms")
    assert(optional_integer(provider.max_items, 1), "completion-tools: invalid provider max_items")
    local fallback_for = provider.fallback_for
    if fallback_for ~= nil then
      assert(type(fallback_for) == "table", "completion-tools: invalid fallback_for")
      for _, dependency in ipairs(fallback_for) do
        assert(type(dependency) == "string", "completion-tools: fallback_for expects source IDs")
        visit(dependency)
      end
    end
    visiting[id], visited[id] = nil, true
  end
  for id in pairs(providers) do
    visit(id)
  end
end

local function validate_ranking(ranking)
  assert(
    type(ranking.history.enabled) == "boolean" and type(ranking.proximity.enabled) == "boolean",
    "completion-tools: invalid ranking flags"
  )
  assert(
    integer(ranking.history.max_entries, 1) and integer(ranking.proximity.lines, 0),
    "completion-tools: invalid ranking limits"
  )
  assert(ranking.max_typos == 0 or ranking.max_typos == 1, "completion-tools: ranking.max_typos must be 0 or 1")
  assert(
    ranking.history.path == nil or (type(ranking.history.path) == "string" and ranking.history.path ~= ""),
    "completion-tools: invalid ranking.history.path"
  )
end

local function validate_copilot(copilot)
  assert(integer(copilot.debounce_ms, 0), "completion-tools: invalid copilot.debounce_ms")
  assert(integer(copilot.max_items, 1), "completion-tools: invalid copilot.max_items")
  assert(
    copilot.request_mode == "cycling" or copilot.request_mode == "staged",
    "completion-tools: invalid copilot.request_mode"
  )
  assert(type(copilot.show_status) == "boolean", "completion-tools: invalid copilot.show_status")
  assert(type(copilot.command) == "table" and #copilot.command > 0, "completion-tools: invalid copilot.command")
  for _, arg in ipairs(copilot.command) do
    assert(type(arg) == "string" and arg ~= "", "completion-tools: invalid copilot.command argument")
  end
  assert(type(copilot.filetypes) == "table", "completion-tools: invalid copilot.filetypes")
  for ft, value in pairs(copilot.filetypes) do
    assert(type(ft) == "string" and type(value) == "boolean", "completion-tools: invalid copilot.filetypes entry")
  end
  assert(type(copilot.settings) == "table", "completion-tools: invalid copilot.settings")
  assert(
    copilot.root_dir == nil
      or type(copilot.root_dir) == "function"
      or (type(copilot.root_dir) == "string" and copilot.root_dir ~= ""),
    "completion-tools: invalid copilot.root_dir"
  )
  assert(type(copilot.workspace_folders) == "table", "completion-tools: invalid copilot.workspace_folders")
  for _, path in ipairs(copilot.workspace_folders) do
    assert(type(path) == "string" and path ~= "", "completion-tools: invalid copilot.workspace_folders entry")
  end
  assert(type(copilot.language_ids) == "table", "completion-tools: invalid copilot.language_ids")
  for ft, language in pairs(copilot.language_ids) do
    assert(
      type(ft) == "string" and type(language) == "string" and language ~= "",
      "completion-tools: invalid copilot.language_ids entry"
    )
  end
  assert(optional_function(copilot.should_attach), "completion-tools: invalid copilot.should_attach")
end

local function validate_cmdline(cmdline)
  assert(
    type(cmdline.enabled) == "boolean" and type(cmdline.auto_show) == "boolean",
    "completion-tools: invalid cmdline flags"
  )
  assert(integer(cmdline.min_keyword_length, 0), "completion-tools: invalid cmdline.min_keyword_length")
  assert(type(cmdline.fuzzy) == "boolean", "completion-tools: invalid cmdline.fuzzy")
  assert(type(cmdline.types) == "table", "completion-tools: invalid cmdline types")
  cmdline._keymap_bindings =
    require("base_tools.keymap").resolve(cmdline.keymap, { name = "completion-tools.cmdline.keymap" })
  assert(optional_function(cmdline.get_anchor), "completion-tools: invalid cmdline.get_anchor")
  for _, cmdtype in ipairs(cmdline.types) do
    assert(vim.tbl_contains(M.defaults.cmdline.types, cmdtype), "completion-tools: unsupported cmdline type")
  end

  assert(type(cmdline.sources) == "table", "completion-tools: invalid cmdline.sources")
  for cmdtype, ids in pairs(cmdline.sources) do
    assert(vim.tbl_contains(M.defaults.cmdline.types, cmdtype), "completion-tools: unsupported cmdline.sources type")
    assert(vim.islist(ids), "completion-tools: cmdline.sources entries must be lists")
    for _, id in ipairs(ids) do
      assert(type(id) == "string" and id ~= "", "completion-tools: invalid cmdline source ID")
    end
  end
end

local function validate_dictionary(dictionary)
  for _, field in ipairs({ "min_keyword_length", "max_items", "timeout_ms" }) do
    assert(integer(dictionary[field], 1), "completion-tools: invalid dictionary." .. field)
  end
  local files = dictionary.files
  assert(type(files) == "table" or type(files) == "function", "completion-tools: invalid dictionary.files")
  if type(files) == "table" then
    for _, file in ipairs(files) do
      assert(type(file) == "string" and file ~= "", "completion-tools: invalid dictionary path")
    end
  end
  for _, field in ipairs({ "max_bytes", "max_words", "max_word_bytes" }) do
    assert(integer(dictionary[field], 1), "completion-tools: invalid dictionary." .. field)
  end
  assert(
    dictionary.matching == "prefix" or dictionary.matching == "fuzzy",
    "completion-tools: invalid dictionary.matching"
  )
  assert(type(dictionary.capitalize) == "boolean", "completion-tools: invalid dictionary.capitalize")
  local documentation = dictionary.documentation
  assert(
    type(documentation) == "table"
      and type(documentation.enabled) == "boolean"
      and type(documentation.command) == "string"
      and documentation.command ~= ""
      and integer(documentation.timeout_ms, 1),
    "completion-tools: invalid dictionary.documentation"
  )
end

local function validate_spell(spell)
  for _, field in ipairs({ "min_keyword_length", "max_items", "timeout_ms" }) do
    assert(integer(spell[field], 1), "completion-tools: invalid spell." .. field)
  end
  assert(integer(spell.debounce_ms, 0), "completion-tools: invalid spell.debounce_ms")
  assert(spell.sort == "match" or spell.sort == "suggestion", "completion-tools: invalid spell.sort")
  for _, field in ipairs({ "preselect_current_word", "suggest_when_correct" }) do
    assert(type(spell[field]) == "boolean", "completion-tools: invalid spell." .. field)
  end
  assert(optional_function(spell.enable_in_context), "completion-tools: invalid spell.enable_in_context")
end

local function validate_menu(menu)
  validate_window_size(menu, "menu")
  assert(menu.min_width >= 1 and menu.min_width <= menu.max_width, "completion-tools: invalid menu.min_width")
  assert(integer(menu.shrink_delay_ms, 0), "completion-tools: invalid menu.shrink_delay_ms")
  assert(integer(menu.update_interval_ms, 0), "completion-tools: invalid menu.update_interval_ms")
  assert(
    menu.inverse == "auto" or type(menu.inverse) == "boolean",
    'completion-tools: menu.inverse must be "auto", true or false'
  )
  local components, seen = require("completion_tools.render").components, {}
  assert(type(menu.columns) == "table" and #menu.columns > 0, "completion-tools: empty menu.columns")
  for _, column in ipairs(menu.columns) do
    assert(type(column) == "table" and #column > 0, "completion-tools: invalid menu column")
    assert(optional_integer(column.gap, 0), "completion-tools: invalid column gap")
    for _, name in ipairs(column) do
      assert(components[name] and not seen[name], "completion-tools: unknown or repeated menu component")
      seen[name] = true
    end
  end
  for _, field in ipairs({ "column_gap", "padding" }) do
    assert(integer(menu[field], 0), "completion-tools: invalid menu." .. field)
  end
  assert(integer(menu.max_label_bytes, 4), "completion-tools: invalid menu.max_label_bytes")
  assert(type(menu.kind_icons) == "boolean" or type(menu.kind_icons) == "table", "completion-tools: invalid kind_icons")
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
  assert(optional_function(menu.highlight.custom), "completion-tools: invalid highlight callback")
end

local function validate_path(path)
  assert(path.max_entries >= 1 and path.cache_ms >= 0, "completion-tools: invalid path limits")
  local preview = path.preview
  assert(type(preview) == "table" and type(preview.enabled) == "boolean", "completion-tools: invalid path.preview")
  assert(
    integer(preview.max_bytes, 1) and integer(preview.max_lines, 1),
    "completion-tools: invalid path preview limits"
  )
end

local function validate_documentation(documentation)
  validate_window_size(documentation, "documentation")
  assert(optional_function(documentation.on_render), "completion-tools: documentation.on_render must be a function")
  assert(documentation.delay_ms >= 0, "completion-tools: invalid documentation delay")
end

function M.validate(opts)
  assert(type(opts) == "table", "completion-tools: setup expects a table")
  local config = merge_options(opts)
  validate_general(config)
  validate_providers(config.providers)
  validate_ranking(config.ranking)
  validate_menu(config.menu)
  validate_documentation(config.documentation)
  validate_copilot(config.copilot)
  validate_cmdline(config.cmdline)
  validate_dictionary(config.dictionary)
  validate_spell(config.spell)
  validate_path(config.path)
  assert(type(config.snippets) == "table", "completion-tools: invalid snippets")
  return config
end

return M
