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

## Fixed provider positions

Set `providers.<id>.insert_at` to a positive, one-based candidate position in Insert
mode. Combine it with `max_items` to bound the block:

```lua
require("completion-tools").setup({
  sources = { "lsp", "snippets", "copilot" },
  providers = { copilot = { insert_at = 3, max_items = 3 } },
})
```

This places up to three matching Copilot candidates at logical positions 3–5,
regardless of their score relative to other providers. Ordinary candidates retain
their ranked order around the block. Each provider block keeps its own ranked
order. Placement happens before the global `max_items` cutoff, so a full menu
cannot exclude a low-scoring positioned source. The default is no fixed position.

With fewer than two ordinary candidates, the block follows those available;
empty or pending sources reserve no blank rows. Short blocks use only their
actual length. Menu inversion reverses painted rows only: positions refer to the logical
candidate list, independently of screen direction. Manual selections retain their
identity as asynchronous candidates arrive. Command-line sorting is unchanged.

Multiple positioned blocks sort by requested position, then active source order.
Overlapping blocks follow the earlier block without interleaving. Identical
semantic candidates appear once, keeping their first occurrence in the composed
list. Positions beyond the final menu cutoff are not visible.
