# Screenshots

These PNGs capture a live Neovim 120×30 UI grid with completion-tools.nvim loaded:

- `completion.png`: actual lua-language-server member completions and resolved
  documentation for a small local Lua module.
- `cmdline.png`: the built-in command-line source completing native `:set` options.

The capture script sends real input, waits for completion/documentation and records
Neovim's composed `ext_linegrid` output. It renders the cells and their RGB attributes
to PNG via SVG; these are UI-grid captures, not desktop window screenshots or mockups.
The local theme and text icons make them reproducible without a Nerd Font.
No user configuration is loaded or modified. Temporary files and processes are cleaned up.

## Reproduce

Requires Python 3, Neovim 0.11+, lua-language-server and `rsvg-convert` on PATH.
The checked-in images were captured with Neovim 0.12.6 on macOS, using Menlo.
For the same typography, install Menlo or adjust the font in `capture.py`.

From the repository root:

```sh
python3 doc/screenshots/capture.py
```

The script uses a temporary workspace, its own Neovim process, isolated XDG
configuration/cache/state directories and the repository's current plugin code.
`theme.lua` controls only that session's appearance. No network requests are made;
the HTTP client example supplies Lua types and documentation for display only.
