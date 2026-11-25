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

local config = require("base_tools.config")
local V = require("base_tools.config.validators")
local boolean, string_value = V.type("boolean"), V.type("string")
local table_value, callback = V.type("table"), V.type("function")
local optional_callback = V.optional(callback)
local nonnegative_integer, positive_integer = V.integer(0), V.integer(1)
local nonempty_string = V.nonempty_string()
local source_list = V.list_of(nonempty_string)
local supported_cmdline_types = { ":", "/", "?" }

local function at_least(minimum)
  return function(value)
    return type(value) == "number" and value >= minimum, "must be a number greater than or equal to " .. minimum
  end
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

local function cmdline_types(value)
  if type(value) ~= "table" then
    return false, "must be a table"
  end
  for _, cmdtype in ipairs(value) do
    if not vim.tbl_contains(supported_cmdline_types, cmdtype) then
      return false, "contains an unsupported command-line type"
    end
  end
  return true
end

local cmdline_sources = V.map_of(source_list, function(cmdtype)
  return vim.tbl_contains(supported_cmdline_types, cmdtype), "is not a supported command-line type"
end)

local function copilot_command(value)
  if type(value) ~= "table" or #value == 0 then
    return false, "must contain at least one command argument"
  end
  return strings(value)
end

local function menu_widths(menu)
  return menu.min_width <= menu.max_width, "min_width must not exceed max_width"
end

local definition = {
  enabled = { default = true, validate = V.any_of(boolean, callback) },
  auto_show = { default = true, validate = boolean },
  trigger_characters = { default = { "." }, validate = V.any_of(trigger_characters, callback), replace = true },
  min_keyword_length = { default = 1, validate = at_least(0) },
  debounce_ms = { default = 0, validate = at_least(0) },
  timeout_ms = { default = 2000, validate = nonnegative_integer },
  max_items = { default = 50, validate = positive_integer },
  preselect = { default = true, validate = boolean },
  accept = {
    fields = {
      mode = { default = "replace", validate = V.one_of({ "insert", "replace" }) },
      auto_brackets = { default = true, validate = V.any_of(boolean, callback) },
    },
  },
  ranking = {
    fields = {
      history = {
        fields = {
          enabled = { default = false, validate = boolean },
          max_entries = { default = 1000, validate = positive_integer },
          path = { validate = V.optional(nonempty_string) },
        },
      },
      proximity = {
        fields = {
          enabled = { default = false, validate = boolean },
          lines = { default = 50, validate = nonnegative_integer },
        },
      },
      max_typos = { default = 0, validate = V.integer(0, 1) },
    },
  },
  keyword_pattern = { default = [[\k*$]], validate = string_value },
  sources = {
    default = { "lsp", "path", "buffer", "snippets" },
    validate = V.any_of(table_value, callback),
    replace = true,
  },
  providers = { default = {}, validate = providers },
  keymap = {
    default = {
      ["<C-Space>"] = { "show", "show_documentation" },
      ["<C-n>"] = { "select_next", "fallback" },
      ["<C-p>"] = { "select_prev", "fallback" },
      ["<C-y>"] = { "accept", "fallback" },
      ["<C-e>"] = { "hide", "fallback" },
      ["<Tab>"] = { "accept", "snippet_forward", "fallback" },
      ["<S-Tab>"] = { "snippet_backward", "fallback" },
    },
    validate = keymap("keymap"),
    replace = true,
  },
  menu = {
    validate = menu_widths,
    fields = {
      max_height = { default = 12, validate = positive_integer },
      inverse = { default = "auto", validate = V.one_of({ "auto", true, false }) },
      shrink_delay_ms = { default = 50, validate = nonnegative_integer },
      update_interval_ms = { default = 16, validate = nonnegative_integer },
      min_width = { default = 18, validate = at_least(1) },
      max_width = { default = 72, validate = positive_integer },
      border = { default = "single" },
      columns = {
        default = { { "kind_icon" }, { "label", gap = 1 }, { "kind" }, { "source" } },
        validate = columns,
        replace = true,
      },
      column_gap = { default = 1, validate = nonnegative_integer },
      padding = { default = 1, validate = nonnegative_integer },
      kind_icons = {
        default = true,
        validate = V.any_of(boolean, V.map_of(string_value)),
      },
      label_details = { default = true, validate = boolean },
      max_label_bytes = { default = 1024, validate = V.integer(4) },
      highlight = {
        fields = {
          enabled = { default = true, validate = boolean },
          treesitter = { default = true, validate = boolean },
          max_bytes = { default = 1024, validate = positive_integer },
          cache_size = { default = 512, validate = nonnegative_integer },
          custom = { validate = optional_callback },
        },
      },
    },
  },
  documentation = {
    fields = {
      auto_show = { default = true },
      delay_ms = { default = 150, validate = at_least(0) },
      max_width = { default = 72, validate = positive_integer },
      max_height = { default = 18, validate = positive_integer },
      border = { default = "single" },
      on_render = { validate = optional_callback },
    },
  },
  buffer = {
    fields = {
      max_bytes = { default = 1024 * 1024, validate = at_least(1) },
      max_words = { default = 20000, validate = at_least(1) },
      max_buffers = { default = 8, validate = at_least(1) },
      batch_lines = { default = 128, validate = at_least(1) },
      min_length = { default = 3, validate = at_least(1) },
    },
  },
  path = {
    fields = {
      max_entries = { default = 10000, validate = at_least(1) },
      cache_ms = { default = 1000, validate = at_least(0) },
      show_hidden = { default = false },
      preview = {
        fields = {
          enabled = { default = true, validate = boolean },
          max_bytes = { default = 64 * 1024, validate = positive_integer },
          max_lines = { default = 100, validate = positive_integer },
        },
      },
    },
  },
  dictionary = {
    fields = {
      files = { default = {}, validate = V.any_of(strings, callback), replace = true },
      min_keyword_length = { default = 3, validate = positive_integer },
      max_items = { default = 10, validate = positive_integer },
      matching = { default = "fuzzy", validate = V.one_of({ "prefix", "fuzzy" }) },
      capitalize = { default = true, validate = boolean },
      max_bytes = { default = 16 * 1024 * 1024, validate = positive_integer },
      max_words = { default = 500000, validate = positive_integer },
      max_word_bytes = { default = 256, validate = positive_integer },
      timeout_ms = { default = 5000, validate = positive_integer },
      documentation = {
        fields = {
          enabled = { default = true, validate = boolean },
          command = { default = "wn", validate = nonempty_string },
          timeout_ms = { default = 1500, validate = positive_integer },
        },
      },
    },
  },
  spell = {
    fields = {
      min_keyword_length = { default = 2, validate = positive_integer },
      max_items = { default = 3, validate = positive_integer },
      debounce_ms = { default = 60, validate = nonnegative_integer },
      timeout_ms = { default = 5000, validate = positive_integer },
      sort = { default = "match", validate = V.one_of({ "match", "suggestion" }) },
      preselect_current_word = { default = true, validate = boolean },
      suggest_when_correct = { default = false, validate = boolean },
      enable_in_context = { validate = optional_callback },
    },
  },
  snippets = { default = { collection = {} }, validate = table_value },
  copilot = {
    fields = {
      debounce_ms = { default = 150, validate = nonnegative_integer },
      request_mode = { default = "cycling", validate = V.one_of({ "cycling", "staged" }) },
      max_items = { default = 3, validate = positive_integer },
      show_status = { default = true, validate = boolean },
      command = { default = { "copilot-language-server", "--stdio" }, validate = copilot_command, replace = true },
      filetypes = { default = {}, validate = V.map_of(boolean, string_value) },
      settings = { default = {}, validate = table_value },
      root_dir = { validate = V.optional(V.any_of(callback, nonempty_string)) },
      workspace_folders = { default = {}, validate = strings, replace = true },
      language_ids = {
        default = {},
        validate = V.map_of(nonempty_string, string_value),
      },
      should_attach = { validate = optional_callback },
    },
  },
  cmdline = {
    fields = {
      enabled = { default = false, validate = boolean },
      auto_show = { default = true, validate = boolean },
      fuzzy = { default = true, validate = boolean },
      min_keyword_length = { default = 1, validate = nonnegative_integer },
      types = { default = supported_cmdline_types, validate = cmdline_types, replace = true },
      sources = {
        validate = cmdline_sources,
        fields = {
          [":"] = { default = { "cmdline" }, replace = true },
          ["/"] = { default = { "buffer" }, replace = true },
          ["?"] = { default = { "buffer" }, replace = true },
        },
      },
      keymap = {
        default = {
          ["<C-Space>"] = { "show", "fallback" },
          ["<Tab>"] = { "accept", "show", "fallback" },
          ["<S-Tab>"] = { "select_prev", "show", "fallback" },
          ["<C-n>"] = { "select_next", "fallback" },
          ["<C-p>"] = { "select_prev", "fallback" },
          ["<Up>"] = { "select_prev", "fallback" },
          ["<Down>"] = { "select_next", "fallback" },
        },
        validate = keymap("cmdline.keymap"),
        replace = true,
      },
      get_anchor = { validate = optional_callback },
    },
  },
}

local instance = config.new(definition)
M.defaults = instance:resolve()

function M.instance()
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
  instance:reset()
end

return M
