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
  menu = { max_height = 12, min_width = 18, max_width = 72, border = "single" },
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
