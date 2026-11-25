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

local V = require("base_tools.config.validators")
local boolean, string_value = V.type("boolean"), V.type("string")
local table_value, callback = V.type("table"), V.type("function")
local optional_callback = V.optional(callback)
local nonnegative_integer, positive_integer = V.integer(0), V.integer(1)

local function at_least(minimum)
  return function(value)
    return type(value) == "number" and value >= minimum, "must be a number greater than or equal to " .. minimum
  end
end

local function nonempty_string(value)
  return type(value) == "string" and value ~= "", "must be a nonempty string"
end

local function strings(value)
  if type(value) ~= "table" then
    return false, "must be a table of nonempty strings"
  end
  for _, item in ipairs(value) do
    if not nonempty_string(item) then
      return false, "must contain only nonempty strings"
    end
  end
  return true
end

local function source_list(value)
  if not vim.islist(value) then
    return false, "must be a list of source IDs"
  end
  return strings(value)
end

local function trigger_characters(value)
  if type(value) ~= "table" then
    return false, "must be a table of trigger characters"
  end
  for _, character in ipairs(value) do
    if type(character) ~= "string" or vim.fn.strchars(character) ~= 1 then
      return false, "must contain only single characters"
    end
  end
  return true
end

local function compile_keymap(spec, name)
  return require("base_tools.keymap").resolve(spec, { name = "completion-tools." .. name })
end

local function keymap(name)
  return function(spec)
    compile_keymap(spec, name)
    return true
  end
end

local function providers(value)
  if type(value) ~= "table" then
    return false, "must be a table"
  end
  local optional_position = V.optional(positive_integer)
  local optional_timeout = V.optional(nonnegative_integer)
  local visiting, visited = {}, {}
  local function visit(id)
    assert(not visiting[id], "completion-tools: cyclic provider fallback_for: " .. id)
    if visited[id] then
      return
    end
    visiting[id] = true
    local provider = value[id]
    assert(provider == nil or type(provider) == "table", "completion-tools: invalid provider " .. tostring(id))
    provider = provider or {}
    assert(optional_position(provider.insert_at), "completion-tools: invalid provider insert_at")
    assert(optional_timeout(provider.timeout_ms), "completion-tools: invalid provider timeout_ms")
    assert(optional_position(provider.max_items), "completion-tools: invalid provider max_items")
    if provider.client_order ~= nil then
      assert(
        id == "lsp" and vim.islist(provider.client_order),
        "completion-tools: client_order must be an LSP client name list"
      )
      local seen = {}
      for _, name in ipairs(provider.client_order) do
        assert(
          nonempty_string(name) and not seen[name],
          "completion-tools: client_order expects unique nonempty client names"
        )
        seen[name] = true
      end
    end
    if provider.fallback_for ~= nil then
      assert(type(provider.fallback_for) == "table", "completion-tools: invalid fallback_for")
      for _, dependency in ipairs(provider.fallback_for) do
        assert(type(dependency) == "string", "completion-tools: fallback_for expects source IDs")
        visit(dependency)
      end
    end
    visiting[id], visited[id] = nil, true
  end
  for id in pairs(value) do
    visit(id)
  end
  return true
end

local function columns(value)
  if type(value) ~= "table" or #value == 0 then
    return false, "must contain at least one column"
  end
  local components, seen = require("completion_tools.render").components, {}
  local optional_gap = V.optional(nonnegative_integer)
  for _, column in ipairs(value) do
    if type(column) ~= "table" or #column == 0 or not optional_gap(column.gap) then
      return false, "must contain nonempty columns with nonnegative integer gaps"
    end
    for _, name in ipairs(column) do
      if not components[name] or seen[name] then
        return false, "contains an unknown or repeated component"
      end
      seen[name] = true
    end
  end
  return true
end

local function map_of(check, message)
  return function(value)
    if type(value) ~= "table" then
      return false, "must be a table"
    end
    for key, entry in pairs(value) do
      if not check(entry, key) then
        return false, message
      end
    end
    return true
  end
end

local function filetype_map(check, message)
  return map_of(function(value, key)
    return type(key) == "string" and check(value)
  end, message)
end

local function cmdline_types(value)
  if type(value) ~= "table" then
    return false, "must be a table"
  end
  for _, cmdtype in ipairs(value) do
    if not vim.tbl_contains(M.defaults.cmdline.types, cmdtype) then
      return false, "contains an unsupported command-line type"
    end
  end
  return true
end

local function cmdline_sources(value)
  if type(value) ~= "table" then
    return false, "must be a table"
  end
  for cmdtype, ids in pairs(value) do
    if not vim.tbl_contains(M.defaults.cmdline.types, cmdtype) then
      return false, "contains an unsupported command-line type"
    end
    local valid, message = source_list(ids)
    if not valid then
      return false, tostring(cmdtype) .. " " .. message
    end
  end
  return true
end

local function copilot_command(value)
  if type(value) ~= "table" or #value == 0 then
    return false, "must contain at least one command argument"
  end
  return strings(value)
end

local rules = {
  enabled = V.any_of(boolean, callback),
  auto_show = boolean,
  preselect = boolean,
  max_items = positive_integer,
  min_keyword_length = at_least(0),
  debounce_ms = at_least(0),
  timeout_ms = nonnegative_integer,
  keyword_pattern = string_value,
  sources = V.any_of(table_value, callback),
  trigger_characters = V.any_of(trigger_characters, callback),
  keymap = keymap("keymap"),
  providers = providers,
  accept = { mode = V.one_of({ "insert", "replace" }), auto_brackets = V.any_of(boolean, callback) },
  buffer = {
    max_bytes = at_least(1),
    max_words = at_least(1),
    max_buffers = at_least(1),
    batch_lines = at_least(1),
    min_length = at_least(1),
  },
  ranking = {
    history = { enabled = boolean, max_entries = positive_integer, path = V.optional(nonempty_string) },
    proximity = { enabled = boolean, lines = nonnegative_integer },
    max_typos = V.integer(0, 1),
  },
  menu = {
    max_width = positive_integer,
    max_height = positive_integer,
    min_width = at_least(1),
    shrink_delay_ms = nonnegative_integer,
    update_interval_ms = nonnegative_integer,
    inverse = V.one_of({ "auto", true, false }),
    columns = columns,
    column_gap = nonnegative_integer,
    padding = nonnegative_integer,
    max_label_bytes = V.integer(4),
    kind_icons = V.any_of(boolean, map_of(string_value, "must contain only string icons")),
    label_details = boolean,
    highlight = {
      enabled = boolean,
      treesitter = boolean,
      cache_size = nonnegative_integer,
      max_bytes = positive_integer,
      custom = optional_callback,
    },
  },
  documentation = {
    max_width = positive_integer,
    max_height = positive_integer,
    delay_ms = at_least(0),
    on_render = optional_callback,
  },
  copilot = {
    debounce_ms = nonnegative_integer,
    max_items = positive_integer,
    request_mode = V.one_of({ "cycling", "staged" }),
    show_status = boolean,
    command = copilot_command,
    filetypes = filetype_map(boolean, "must map filetypes to booleans"),
    settings = table_value,
    root_dir = V.optional(V.any_of(callback, nonempty_string)),
    workspace_folders = strings,
    language_ids = filetype_map(nonempty_string, "must map filetypes to nonempty strings"),
    should_attach = optional_callback,
  },
  cmdline = {
    enabled = boolean,
    auto_show = boolean,
    fuzzy = boolean,
    min_keyword_length = nonnegative_integer,
    types = cmdline_types,
    sources = cmdline_sources,
    keymap = keymap("cmdline.keymap"),
    get_anchor = optional_callback,
  },
  dictionary = {
    files = V.any_of(strings, callback),
    min_keyword_length = positive_integer,
    max_items = positive_integer,
    timeout_ms = positive_integer,
    max_bytes = positive_integer,
    max_words = positive_integer,
    max_word_bytes = positive_integer,
    matching = V.one_of({ "prefix", "fuzzy" }),
    capitalize = boolean,
    documentation = { enabled = boolean, command = nonempty_string, timeout_ms = positive_integer },
  },
  spell = {
    min_keyword_length = positive_integer,
    max_items = positive_integer,
    timeout_ms = positive_integer,
    debounce_ms = nonnegative_integer,
    sort = V.one_of({ "match", "suggestion" }),
    preselect_current_word = boolean,
    suggest_when_correct = boolean,
    enable_in_context = optional_callback,
  },
  path = {
    max_entries = at_least(1),
    cache_ms = at_least(0),
    preview = { enabled = boolean, max_bytes = positive_integer, max_lines = positive_integer },
  },
  snippets = table_value,
}

local function add_fields(fields, ruleset, prefix)
  local keys = vim.tbl_keys(ruleset)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local rule = ruleset[key]
    local path = vim.list_extend(vim.list_slice(prefix), { key })
    if type(rule) == "table" then
      fields[#fields + 1] = { path = path, validate = table_value }
      add_fields(fields, rule, path)
    else
      fields[#fields + 1] = { path = path, validate = rule }
    end
  end
end

local function menu_widths(menu)
  return menu.min_width <= menu.max_width, "min_width must not exceed max_width"
end

local instance

function M.instance()
  if not instance then
    local fields = {}
    add_fields(fields, rules, {})
    fields[#fields + 1] = { path = { "menu" }, validate = menu_widths }
    instance = require("base_tools.config").new(M.defaults, {
      fields = fields,
      replace = {
        { "sources" },
        { "trigger_characters" },
        { "keymap" },
        { "copilot", "command" },
        { "copilot", "workspace_folders" },
        { "menu", "columns" },
        { "dictionary", "files" },
        { "cmdline", "keymap" },
        { "cmdline", "types" },
        { "cmdline", "sources", ":" },
        { "cmdline", "sources", "/" },
        { "cmdline", "sources", "?" },
      },
    })
  end
  return instance
end

function M.compile(candidate)
  candidate._keymap_bindings = compile_keymap(candidate.keymap, "keymap")
  candidate.cmdline._keymap_bindings = compile_keymap(candidate.cmdline.keymap, "cmdline.keymap")
  return candidate
end

function M.validate(opts)
  assert(type(opts) == "table", "completion-tools: setup expects a table")
  local store = M.instance()
  local candidate = store:resolve(opts)
  store:check(candidate)
  return M.compile(candidate)
end

function M.reset()
  if instance then
    instance:reset()
  end
end

return M
