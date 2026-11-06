local M = {}
local installed = {}
local function termcode(key)
  -- Expr helpers such as pairs.expr() already return encoded keycodes.
  -- Passing K_SPECIAL through replace_termcodes again inserts escaped bytes.
  if key:find("\128", 1, true) then
    return key
  end
  return vim.api.nvim_replace_termcodes(key, true, false, true)
end
local function global_mapping(key, mode)
  for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
    if termcode(mapping.lhs) == termcode(key) then
      return mapping
    end
  end
  return {}
end
local function feed(keys, remap)
  if keys and keys ~= "" then
    -- Put fallback before the remaining typed input. Inserting at the back can
    -- reorder a fast "Tab then text" sequence.
    vim.api.nvim_feedkeys(keys, remap and "im" or "in", false)
  end
end
local function fallback(mapping)
  local previous = mapping.previous
  if previous.callback then
    local result = previous.callback()
    if previous.expr == 1 then
      if previous.replace_keycodes == 1 then
        result = termcode(result or "")
      end
      feed(result, previous.noremap == 0)
    end
  elseif previous.rhs then
    local result = previous.expr == 1 and vim.api.nvim_eval(previous.rhs) or previous.rhs
    feed(termcode(result), previous.noremap == 0)
  else
    feed(termcode(mapping.key), false)
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
        feed(termcode(result), false)
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
local function description(actions)
  if type(actions.desc) == "string" and actions.desc ~= "" then
    return actions.desc
  end
  local labels, seen = {}, {}
  for _, action in ipairs(actions) do
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
  local function install(mode, keymap)
    for key, actions in pairs(keymap) do
      if actions ~= false then
        if type(actions) == "string" then
          actions = { actions }
        end
        local mapping = { mode = mode, key = key, actions = actions, previous = global_mapping(key, mode) }
        mapping.callback = function()
          run(mapping)
        end
        -- Non-expr callbacks permit text edits and custom actions. Buffer-local
        -- mappings keep Neovim's normal precedence over these global defaults.
        -- A silent command-line mapping suppresses setcmdline's native redraw,
        -- leaving both native and external command lines stale until the next key.
        vim.keymap.set(mode, key, mapping.callback, { silent = mode ~= "c", desc = description(actions) })
        installed[#installed + 1] = mapping
      end
    end
  end
  install("i", config.keymap)
  install("s", config.keymap)
  if config.cmdline.enabled then
    install("c", config.cmdline.keymap)
  end
end

function M.dispose()
  for _, mapping in ipairs(installed) do
    local current = global_mapping(mapping.key, mapping.mode)
    if current.callback == mapping.callback then
      vim.keymap.del(mapping.mode, mapping.key)
      if next(mapping.previous) then
        vim.fn.mapset(
          mapping.mode,
          false,
          vim.tbl_extend(
            "keep",
            mapping.previous,
            { abbr = 0, buffer = 0, mode = mapping.mode, scriptversion = 1 }
          )
        )
      end
    end
  end
  installed = {}
end
return M
