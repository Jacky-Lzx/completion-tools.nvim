# completion-tools.nvim

Pure Lua completion with readable menus and documentation.

![Lua completion with highlighted signatures and documentation](doc/screenshots/completion.png)

## Features

- Complete from LSP, paths, buffers and snippets.
- Use optional dictionaries, spelling, command-line completion and Copilot.
- Extend sources, ranking, key actions and documentation previews.

## Requirements

Neovim **0.11+**. No required plugin dependencies. Install language servers separately. A Nerd Font is optional.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/completion-tools.nvim",
  main = "completion-tools",
  opts = { cmdline = { enabled = true } },
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("completion-tools").setup({ cmdline = { enabled = true } })
```

Before starting language servers, merge completion capabilities:

```lua
vim.lsp.config("*", {
  capabilities = require("completion_tools.capabilities").get_lsp_capabilities(),
})
```

## Usage

```vim
:CompletionToolsInfo
```

In Insert mode, type to request candidates. Use Ctrl-N/Ctrl-P to select, Ctrl-Y
to accept and Ctrl-E to close. Enter keeps its existing behavior.

## Documentation

- [Complete reference](doc/completion-tools.txt) — `:help completion-tools`.
- [Workflow and integration guide](doc/guide.md).
- [More screenshots](doc/gallery.md).
- Diagnose availability with `:checkhealth completion_tools`.
- [Performance measurements](doc/performance.md).

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.

[License](LICENSE).
