local keys = require("base_tools.keys")
local keymaps = require("base_tools.keymap")
local M = {}
local installed = {}

local function callback_keys(result)
  -- Callbacks can return either notation or an already encoded sequence.
  -- Preserve K_SPECIAL bytes in results such as pairs.expr().
  if result:find("\128", 1, true) then
    return result
  end

  return keys.encode(result)
end

local function feed(sequence, remap)
  if sequence and sequence ~= "" then
    -- Put fallback before the remaining typed input. Inserting at the back can
    -- reorder a fast "Tab then text" sequence.
    vim.api.nvim_feedkeys(sequence, remap and "im" or "in", false)
  end
end

local function fallback(mapping)
  local previous = mapping.previous
  if previous.callback then
    local result = previous.callback()

    if previous.expr == 1 then
      if previous.replace_keycodes == 1 then
        result = callback_keys(result or "")
      end

      feed(result, previous.noremap == 0)
    end
  elseif previous.rhs then
    local result = previous.expr == 1 and callback_keys(vim.api.nvim_eval(previous.rhs)) or keys.encode(previous.rhs)
    feed(result, previous.noremap == 0)
  else
    feed(keys.encode(mapping.key), false)
  end
end

local function run(mapping)
  local cmp = require("completion_tools")
  if mapping.mode == "c" and not cmp._cmdline_active() then
    fallback(mapping)
    return
  end

  for _, action in ipairs(mapping.actions) do
    if action == "fallback" then
      fallback(mapping)
      return
    end

    if type(action) == "function" then
      local result = action(cmp)
      if type(result) == "string" then
        feed(callback_keys(result), false)
        return
      end

      if result then
        return
      end
    elseif cmp._can(action) and cmp[action]() then
      return
    end
  end
end

local action_labels = {
  show = "Show completions",
  hide = "Hide completions",
  accept = "Accept completion",
  accept_word = "Accept next completion word",
  accept_line = "Accept next completion line",
  select_next = "Next completion",
  select_prev = "Previous completion",
  show_documentation = "Show completion documentation",
  scroll_documentation_up = "Scroll documentation up",
  scroll_documentation_down = "Scroll documentation down",
  snippet_forward = "Next snippet field",
  snippet_backward = "Previous snippet field",
}

local function description(binding)
  if binding.desc and binding.desc ~= "" then
    return binding.desc
  end

  local labels, seen = {}, {}
  for _, action in ipairs(binding.actions) do
    if action ~= "fallback" then
      local label = type(action) == "function" and "Custom completion action"
        or action_labels[action]
        or action:gsub("_", " ")
      if not seen[label] then
        labels[#labels + 1], seen[label] = label, true
      end
    end
  end

  return "Completion: " .. (#labels > 0 and table.concat(labels, " / ") or "Use original key")
end

function M.setup(config)
  M.dispose()

  local function install(mode, bindings)
    for _, binding in ipairs(bindings) do
      local mapping = { mode = mode, key = binding.lhs, actions = binding.actions }
      -- Non-expr callbacks permit text edits. Command-line mappings must keep
      -- native redraw enabled during setcmdline().
      local cleanup, previous = keymaps.install(mode, binding.lhs, function()
        run(mapping)
      end, { silent = mode ~= "c", desc = description(binding) })
      mapping.previous = previous or {}
      installed[#installed + 1] = cleanup
    end
  end

  install("i", config._keymap_bindings)
  install("s", config._keymap_bindings)

  if config.cmdline.enabled then
    install("c", config.cmdline._keymap_bindings)
  end
end

function M.dispose()
  for index = #installed, 1, -1 do
    installed[index]()
  end

  installed = {}
end

return M
