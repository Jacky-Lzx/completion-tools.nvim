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

## Candidate order

Candidates sort by descending match score (including provider offsets, preselect
and optional ranking bonuses). Equal scores sort by the active `sources` order,
then by LSP client order, then by each provider/client's `sortText` or `label`.
Client names and IDs break unconfigured client ties consistently; response arrival
order does not choose the winning client. Labels and original item order break
remaining ties. Better matches can still outrank a preferred source or client.

Configure client preference separately from server-local `sortText`:

```lua
require("completion-tools").setup({
  sources = { "lsp", "snippets", "buffer" },
  providers = {
    lsp = { client_order = { "preferred_server", "other_server" } },
  },
})
```

`providers.lsp.client_order` is an optional list of unique, nonempty client names.
Listed clients precede unlisted clients at equal scores. The default is an empty
preference list; no language server names are built into the plugin. Numeric
`sortText` values from one server or snippet provider cannot displace another
source/client's equally scored candidates. Menu inversion changes only the painted
row order, not candidate priority or the top-K cutoff.
