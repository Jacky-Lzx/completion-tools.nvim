# Configuration guide

[Quick start](../README.md) · [Complete reference](completion-tools.txt)

The complete option and provider contracts live in `:help completion-tools`.
Use these help entries inside Neovim:

- `completion-tools-reference-defaults`: default option values.
- `completion-tools-reference-keymaps`: action chains and fallback behavior.
- `completion-tools-reference-copilot`: server setup, authentication and controls.
- `completion-tools-reference-dictionaries-and-spelling`: prose sources.
- `completion-tools-reference-custom-sources`: provider examples.
- `completion-tools-reference-api-and-selection-lifecycle`: request ownership.

For a first setup, install the plugin, merge capabilities before enabling language
servers, then add optional providers explicitly. Configure a single completion
engine and keep snippet expansion with its chosen owner.

[Migration and integration examples](guide.md) · [Performance](performance.md)
