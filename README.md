# completion-tools.nvim

**Completion that stays out of your way.** Pure Lua, built for Neovim 0.11+.
No build step or required third-party dependencies.

![Lua completion with highlighted signatures and documentation](doc/screenshots/completion.png)

*Live Lua language-server completions in Neovim, with syntax-colored signatures and documentation. [Reproduce the screenshots](doc/screenshots/README.md).*

- **Ready to code:** LSP, async paths, buffer words and native snippets out of the box; optional LuaSnip and Copilot support.
- **Easy to read:** aligned columns, kind icons, highlighted matches and automatic documentation.
- **Smooth while typing:** incremental word indexes, cancellation and reusable completion lists; the previous menu stays visible while results arrive.
- **Beyond code:** opt-in command/search completion, custom dictionaries, native spelling suggestions and local WordNet definitions.
- **Yours to extend:** custom providers, context-aware sources, keymap action chains and theme highlights.
- **Control the results:** optional history/proximity ranking and typo matching, source deadlines, quotas and fallbacks.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Jacky-Lzx/completion-tools.nvim",
  main = "completion-tools",
  event = { "InsertEnter", "CmdlineEnter" },
  opts = {
    cmdline = { enabled = true }, -- Optional command and search completion
  },
}
```

Or add the plugin to your runtime path and call `require("completion-tools").setup()`.
Disable other completion engines to avoid competing menus and mappings.
Default kind icons need a Nerd Font; use `menu = { kind_icons = false }` to hide them.

### Connect your language servers

Merge capabilities **before starting servers**. With Neovim's native LSP configuration:

```lua
vim.lsp.config("*", {
  capabilities = require("completion-tools").get_lsp_capabilities(),
})
-- Configure and enable your language servers as usual.
```

When lazy-loading, make your LSP configuration depend on this plugin so the module
is available during server setup. `get_lsp_capabilities(base)` preserves other capabilities.

### Copilot completions

The built-in source connects directly to GitHub's
[Copilot Language Server](https://github.com/github/copilot-language-server-release).
Install the server once (or use your package manager/Mason):

```sh
npm install -g @github/copilot-language-server
```

```lua
require("completion-tools").setup({
  sources = { "copilot", "lsp", "path", "buffer", "snippets" },
})
```

Run `:CompletionToolsCopilot auth` to sign in; follow the displayed device code
and browser flow. `:CompletionToolsCopilot status` shows the client state.
No `copilot.lua`, Blink or nvim-cmp adapter is needed. When migrating, remove
`copilot.lua` from your plugin configuration and its `require("copilot").setup()`.
This integration provides completion only, using the normal menu with up to
three purple suggestions. With theme-tools, their purple follows the active
theme, including light palettes; standalone completion inherits `Statement`.
An explicit `CompletionToolsCopilot` highlight takes precedence. Its status uses
Copilot icons in the completion window footer, with an animated spinner while waiting for suggestions. Exact forward
typing reuses matching suggestions immediately without another request; input
that diverges uses the normal 150 ms debounce. See [Copilot configuration](doc/configuration.md#copilot)
for server paths, filetype policies and controls.
Optional `copilot.request_mode = "staged"` shows first-stage results before
fetching alternatives. `accept_word` and `accept_line` actions accept part of a
suggestion while keeping the remainder; configure their keys as desired.

## Everyday keys

| Key | Action |
| --- | --- |
| `Ctrl-Space` | Open completion; show documentation if already open |
| `Ctrl-N` / `Ctrl-P` | Select next / previous |
| `Ctrl-Y` | Accept selection |
| `Tab` | Accept, jump to the next snippet placeholder, or fall back |
| `Shift-Tab` | Jump to the previous placeholder, or fall back |
| `Ctrl-E` | Close the menu, or fall back |
| `Enter` | Keep your existing behavior |

The first item is preselected. Navigating never inserts text. Automatic completion
starts when you edit text; entering Insert mode alone does not open a menu.

With command-line completion enabled, `Tab` accepts without executing,
`Up` / `Down` select, and `Enter` keeps its native command/search behavior.

![Native Ex option completion in Neovim](doc/screenshots/cmdline.png)

*Command-line completion uses Neovim's native candidates and preserves their order.*

## Make it yours

```lua
require("completion-tools").setup({
  sources = { "lsp", "path", "buffer", "snippets" },
  snippets = { preset = "luasnip" }, -- Optional; requires your LuaSnip setup
  menu = { border = "rounded", max_height = 10 },
  documentation = { delay_ms = 150 },
  cmdline = { enabled = true },
})
```

Keep the default snippet preset to use `vim.snippet` and your own snippet collection.
See the [configuration guide](doc/configuration.md) for dictionaries, spelling,
keymaps, menu styling, custom sources and external command-line UI integration.

## Learn more

- [Configuration and examples](doc/configuration.md)
- [API and in-editor help](doc/completion-tools.txt) — `:help completion-tools`
- [Performance measurements and reproduction](doc/performance.md)
- [Tests and development](doc/configuration.md#development)

Run `:checkhealth completion-tools` to check your setup.
Use `:CompletionToolsStatus` to inspect source timings, candidate counts and cache hits.

[MIT License](LICENSE)

## Shared icon display

When theme-tools.nvim is configured, icons follow its shared icon API and
`:ThemeToolsIcons` selection (mini.icons, nvim-web-devicons, ASCII, or hidden).
Open views refresh when the display changes. Provider installation and updates
belong to theme-tools; no extra icon dependency is needed for this integration.
Without theme-tools, existing standalone defaults remain available.
Local icon-disable options still apply. Configure shared overrides through
`require("theme_tools").setup({ icons = { overrides = { ... } } })`.

## Theme surfaces

Menu and documentation borders use their own surface backgrounds. Override
`CompletionToolsBorder` and `CompletionToolsDocBorder` independently; explicit
highlight definitions take precedence over shared theme defaults.

### Plugin-owned first-input startup

With an install-and-mount package manager, call
`require("completion_tools.bootstrap").setup(opts)` during configuration. The
plugin initializes its engine on the first InsertEnter, CmdlineEnter or native
CompletionTools command. Capability lookups remain safe before initialization.
`bootstrap.ensure()` explicitly initializes it once and returns the engine.
The existing `completion_tools.setup(opts)` API still initializes immediately.
