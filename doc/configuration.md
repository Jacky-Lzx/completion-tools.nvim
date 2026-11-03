# Configuration guide

[Quick start](../README.md) · [Help and API](completion-tools.txt) · [Performance](performance.md)

## Defaults

Common options and their defaults are shown below. The complete defaults live in
[`config.lua`](../lua/completion_tools/config.lua).

```lua
require("completion-tools").setup({
  enabled = true, -- Also accepts function() -> boolean
  auto_show = true,
  trigger_characters = { "." },
  min_keyword_length = 1,
  debounce_ms = 0,
  max_items = 50,
  preselect = true,
  keyword_pattern = [[\k*$]],
  sources = { "lsp", "path", "buffer", "snippets" },
  providers = {},
  menu = {
    max_height = 12, shrink_delay_ms = 120,
    min_width = 18, max_width = 72, border = "single",
    columns = { { "kind_icon" }, { "label", gap = 1 }, { "kind" }, { "source" } },
    column_gap = 1, padding = 1,
    kind_icons = true, label_details = true, max_label_bytes = 1024,
    highlight = { enabled = true, treesitter = true, max_bytes = 1024, cache_size = 512 },
  },
  documentation = {
    auto_show = true, delay_ms = 150, max_width = 72, max_height = 18, border = "single",
  },
  buffer = {
    max_bytes = 1024 * 1024, max_words = 20000, max_buffers = 8,
    batch_lines = 128, min_length = 3, -- Word length in bytes
  },
  path = { max_entries = 10000, cache_ms = 1000, show_hidden = false },
  dictionary = {
    files = {}, min_keyword_length = 3, max_items = 10,
    matching = "fuzzy", capitalize = true,
    max_bytes = 16 * 1024 * 1024, max_words = 500000, max_word_bytes = 256,
    timeout_ms = 5000,
    documentation = { enabled = true, command = "wn", timeout_ms = 1500 },
  },
  spell = {
    min_keyword_length = 2, max_items = 3, debounce_ms = 60, timeout_ms = 5000,
    sort = "match", preselect_current_word = true, suggest_when_correct = false,
  },
  snippets = { preset = "default", collection = {} },
  cmdline = {
    enabled = false, auto_show = true, min_keyword_length = 1, types = { ":", "/", "?" },
  },
})
```

`sources` may be `function(ctx) -> string[]` to choose providers by filetype,
syntax context or buffer state. Lists replace existing lists rather than merge.

## Automatic triggers

Insert-mode completion opens while typing words. Other characters close the
menu and cancel pending requests, except those in `trigger_characters` (default
`{ "." }`). This filter takes precedence over LSP trigger characters, path
detection and `min_keyword_length = 0`. Allowed characters can open completion
without a keyword prefix; providers still decide which candidates to return.
Manual completion (`<C-Space>` / `show()`) bypasses this filter. Command-line
completion keeps its independent behavior.

Use `function(ctx) -> string[]` to choose symbols by Neovim filetype:

```lua
require("completion-tools").setup({
  trigger_characters = function(ctx)
    local by_filetype = {
      lua = { ".", ":" },
      tex = { ".", "\\", "{" },
      markdown = {},
    }
    return by_filetype[ctx.filetype] or { "." }
  end,
})
```

An empty list disables all symbol triggers while keeping word completion.
Add `"/"` when you want automatic path completion immediately after a slash;
otherwise type the next word character or request completion manually.

## Providers

Each `providers[id]` supports:

| Option | Purpose |
| --- | --- |
| `enabled` | Boolean or `function(ctx) -> boolean` |
| `score_offset` | Add an offset to the provider's match scores |
| `transform_items(ctx, items)` | Filter or modify the returned item list |
| `module`, `opts` | Load a custom module exposing `new(opts)` |
| `complete`, `resolve`, etc. | Define a provider inline; see [custom sources](#custom-sources) |

For example, exclude LSP Text and Snippet items:

```lua
providers = {
  lsp = {
    transform_items = function(_, items)
      return vim.tbl_filter(function(item)
        return item.kind ~= 1 and item.kind ~= 15
      end, items)
    end,
  },
}
```

## Keymaps

`keymap` replaces the entire insert/select-mode mapping table; `keymap = {}`
installs none. Command-line mappings use the independent `cmdline.keymap` table.
To change only a few defaults, copy them first:

```lua
local keys = vim.deepcopy(require("completion_tools.config").defaults.keymap)
keys["<CR>"] = { "accept", "fallback" }
keys["<A-j>"] = { "select_next", "fallback" }
keys["<A-k>"] = { "select_prev", "fallback" }
keys["<C-d>"] = { "scroll_documentation_down", "fallback" }
keys["<C-u>"] = { "scroll_documentation_up", "fallback" }
require("completion-tools").setup({ keymap = keys })
```

Actions may also be `function(cmp)`: return `true` when handled, `false`/`nil`
to try the next action, or a string to feed as a Neovim key sequence. Actions run
in normal callbacks where buffer edits are allowed. For example, with pairs.nvim:

```lua
keys["<CR>"] = {
  "accept",
  function() return require("pairs").expr("<CR>") end,
  "fallback",
}
```

Existing global mappings become fallbacks. Buffer-local mappings retain Neovim's
normal precedence. Repeated setup/dispose restores mappings still owned by the
plugin and preserves mappings installed later. Call `refresh_keymaps()` after a
lazy dependency installs mappings to update fallbacks without resetting completion.

## LSP behavior

Register `get_lsp_capabilities(base?)` before starting servers; setup is not required
first. The LSP source supports multiple clients, trigger characters, incomplete-list
requests, UTF-8/16/32 ranges, TextEdit/InsertReplaceEdit, CompletionList.itemDefaults,
additional text edits, snippets, item resolve and commands after acceptance.

Selection starts resolve early. Accepting before it finishes inserts the primary
text immediately. Late additional edits apply only if the accepted buffer has not
changed since insertion. A slow resolve can therefore omit an import rather than
overwrite new input.

## Buffer words and paths

By default, only words in the current normal buffer are indexed. Initial indexing
runs in batches of 128 lines. Ordinary edits retokenize changed lines; inserting or
deleting lines shifts the line index. Frequency counts remove obsolete words, so
completion does not rescan the whole file on every keystroke.

Buffers over `max_bytes` are skipped. Each index retains up to `max_words` distinct
words; at most `max_buffers` active indexes are kept, evicting the least recently
used. Reaching the word budget may omit words from the file.

`buffer.get_bufnrs(ctx)` can select multiple buffers, such as loaded buffers with
the same filetype. `path.get_cwd(ctx)` overrides the relative path base: normally
the current file's directory, or cwd for unnamed buffers. A path must contain a
slash, such as `./`, `../`, `~/` or `/tmp/`.

Directory reads use asynchronous libuv batches and cache up to 32 directories.
Typing a dot can reveal hidden files. When a directory exceeds `max_entries`, only
the first entries returned by the filesystem are read.

## Snippets

The default preset uses `vim.snippet` and accepts per-filetype definitions:

```lua
snippets = {
  collection = {
    all = {
      { prefix = "todo", body = "TODO: $0", description = "To-do comment" },
    },
    lua = {
      {
        prefix = "fn",
        body = { "function ${1:name}(${2:args})", "\t$0", "end" },
        description = "Function definition",
      },
    },
  },
}
```

`collection` may also be `function(ctx) -> table`. Custom engines can implement
`snippets.expand(text)`, `active(direction)` and `jump(direction)`.

To use existing LuaSnip definitions:

```lua
snippets = { preset = "luasnip" }
```

Install and configure LuaSnip separately. This preset reads visible, non-regex
snippets for the current filetype and its extensions, respects `show_condition`,
and uses LuaSnip for expansion, jumping and LSP snippets. It does not read
`collection`; regex snippets still use LuaSnip's own expansion mechanism.
Native snippet selection follows Neovim's input queue: wait for placeholder
selection to finish before typing replacement text.

## Command line

`cmdline = { enabled = true }` enables `:`, `/` and `?` completion.
Ex uses native `getcompletion()` for commands, options/values, files/directories,
help, Lua members and declared user-command completions. Search uses buffer words.
Native ordering and matches are preserved; wildcards and escaped characters are
not filtered again. Path insertion escapes spaces and other special characters.
Replacement preserves modifiers, `no`/`inv` prefixes, Lua namespaces and trailing text.

Empty command lines and whitespace do not open the menu. Empty arguments after a
meaningful command, such as `:set `, may show contextual candidates.

| Key | Command-line action |
| --- | --- |
| `Ctrl-Space` | Open manually |
| `Up` / `Down`, `Ctrl-P` / `Ctrl-N` | Select; preserve native history when the menu is closed |
| `Tab` | Accept or request completion; never execute |
| `Shift-Tab` | Select previous or request completion |
| `Enter` | Execute command / confirm search without automatically accepting |

`cmdline.keymap` replaces the defaults; `{}` installs none. Use `auto_show=false`
for manual triggers or `types={":"}` for Ex only. Native wildmenu/popupmenu takes
precedence. The menu closes on command-line exit. Unsupported prompts, including
`input()` and expression registers, retain native behavior. Shell commands
(including modified `!`, `read/write !` and `terminal`) and filename backtick
expansion are excluded.

The native API is synchronous: slow custom callbacks or filesystems can still
block. With lazy.nvim, declare both `InsertEnter` and `CmdlineEnter` events.

### External command-line UI

`cmdline.get_anchor(ctx)` may return `{row=0, col=0, height=3}` describing the entire
input frame in zero-based screen cells, including borders. The menu avoids the
frame and flips above it when needed; without an anchor it uses native placement.
For input-tools.nvim, use its public layout API:

```lua
local cmdline = {
  enabled = true,
  get_anchor = function()
    local input = package.loaded["input-tools"]
    local box = input and input.get_layout()
    if box and not box.vim_mode then
      return { row = box.row, col = box.col, height = box.outer_height }
    end
  end,
}
require("completion-tools").setup({ cmdline = cmdline })
vim.api.nvim_create_autocmd("User", {
  pattern = { "InputToolsOpen", "InputToolsLayoutChanged", "InputToolsClose" },
  callback = function()
    local cmp = package.loaded["completion-tools"]
    if cmp then cmp.refresh_cmdline() end
  end,
})
```

`refresh_cmdline()` never opens an idle menu. Relocation preserves selection and
makes stale candidates unacceptable. No Blink adapter is loaded.

Commands, help tags, options and paths use uniform kind coloring with emphasized
matches; names containing `local`, hyphens or angle brackets are not treated as
code. Lua/Vim expression and function completion use the corresponding language,
independent of the buffer filetype. Kind/source columns follow the theme.
Override groups such as `CompletionToolsKindReference` for help tags, or return
scoped spans from `menu.highlight.custom` using `ctx.mode == "cmdline"` and
`ctx.completion_type`.

## Dictionaries and spelling

Add `"dictionary"` and/or `"spell"` explicitly:

```lua
require("completion-tools").setup({
  sources = { "lsp", "path", "buffer", "snippets", "dictionary", "spell" },
  dictionary = {
    files = { vim.fn.stdpath("config") .. "/configs/dictionary.txt" },
    min_keyword_length = 3,
    max_items = 10,
  },
  spell = { sort = "match" },
  providers = { dictionary = { score_offset = 5 }, spell = { score_offset = 10 } },
})
```

### Dictionary

Use UTF-8 files with one word or phrase per line. CRLF, BOM, duplicates and paths
containing spaces are supported. `dictionary.files` also accepts
`function(ctx) -> string[]`; lists replace rather than merge.

`matching="fuzzy"` ranks prefix/subsequence matches and returns up to `max_items`.
`"prefix"` uses only prefix matches, narrowing the search with three-byte buckets.
Lowercase words follow the input's title/uppercase style by default;
`capitalize=false` preserves their spelling.

Selected entries asynchronously query local WordNet via `wn <original_word> -over`
for English definitions. Original dictionary casing is used for lookup. No network
or Blink is involved; missing tools or definitions do not interrupt completion.
The word list itself has no definitions, and WordNet does not provide translations.

```lua
dictionary = {
  documentation = { enabled = true, command = "wn", timeout_ms = 1500 },
}
```

`command` may be an executable path; `enabled=false` disables definitions. Only the
selected item resolves. Selection/input changes, acceptance or hiding cancel old
queries. Acceptance inserts only the word. Each source caches up to 128 lookups,
each capped at 64 KiB; setup/dispose releases them.

Files and queries are cached in the background; each request checks file metadata
and reindexes changes. Up to four file indexes and 64 queries per index are kept.
Default budgets: 16 MiB total, 500,000 words, 256 bytes per word. Files exceeding
the remaining byte budget are skipped; the word limit truncates the index.
Missing-file and truncation warnings are deduplicated and do not affect other sources.

### Spell

Active only when window-local `spell` is enabled. Inherits `spelllang`, `spellfile`,
`spellcapcheck`, `spelloptions`, `spellsuggest` and runtimepath.
`enable_in_context=function(ctx) -> boolean` may restrict syntax/filetypes further.
Changes to compiled personal word lists reload the worker.

- `sort="match"`: prioritize stronger fuzzy matches, then alphabetical order for
  ties. Non-subsequence corrections, including transpositions, remain at the end.
- `sort="suggestion"`: preserve native `spellsuggest()` order.
- Correct words normally retain only the current word, marked for preselection.
  `preselect_current_word=false` hides it; `suggest_when_correct=true` includes alternatives.

This sorting applies within the spell source; cross-source offsets and deduplication
still apply. Both word sources return Text items with the default gray styling.
Acceptance inserts the suggested word, never the misspelling used for filtering.

Each source starts a persistent, on-demand headless process using the current
Neovim executable, without loading user init. Workers retain indexes while idle;
dispose/setup/exit stops them. Only one active and one latest pending request are
kept. Cancelled or stale results cannot open a menu. Spell debounces for 60 ms by
default, letting other providers appear first. Cold dictionaries and slow language
suggestions may arrive later without occupying the editor's main thread.
User-init functions referenced by `spellsuggest=expr:...` are not copied to workers.

## Menu and highlighting

The default layout is **kind icon | label, signature and description | kind | source**.
Each `columns` group can contain multiple components, separated by `gap` (default 1);
`column_gap` separates groups. Supported components: `kind_icon`, `label`, `kind`,
`source`, `label_detail`, `label_description`. The column list replaces defaults;
components cannot repeat.

Sources display as LSP, Buffer, Path, Snippets, Cmdline, Dict and Spell. Custom sources
retain their IDs. Column widths are calculated across retained candidates and stay
aligned while scrolling. Narrow windows compress labels first while retaining a
readable namespace. Truncation uses display width; extmarks use UTF-8 byte ranges.

`label` combines `labelDetails.detail` and `labelDetails.description`, falling back
to a single-line `item.detail`. Display never changes accepted CompletionItems.
With separate detail/description columns, set `label_details=false` to avoid repeats.
`kind_icons=false` hides icons; a table such as `{ Function="ƒ", Variable="v" }`
overrides selected icons. Defaults require a Nerd Font.

Text icons, labels and kind names use `CompletionToolsKindText` (linked to `Comment`),
without lexical recoloring. Snippets use `CompletionToolsKindSnippet` (`Special`).
Documentation hides Markdown code fences and inline backticks while preserving
code text, indentation and highlighting. Detail/plaintext remain literal.
Prose emphasis (`*italic*`, `**bold**`, `***both***` and underscore forms) conceals
its delimiters and applies italic/bold styles. Thematic rules (`---`, `***`, `___`)
become full-width separators. Code spans and blocks preserve their symbols.
Conceal settings are local to the preview. Sizing accounts for Neovim's raw-column
wrapping so hidden delimiters do not cause clipped text in narrow windows.
Style groups are `CompletionToolsDocItalic`, `CompletionToolsDocBold`,
`CompletionToolsDocBoldItalic` and `CompletionToolsDocSeparator`.
Code blocks reuse menu lexical/Tree-sitter settings; inline code uses
`CompletionToolsDocCode` (`String`). Menu custom callbacks apply only to candidates.

Highlighting has no Blink/colorful-menu dependency. Kind colors provide the base;
lexical rules distinguish types, parameters, keywords, strings, numbers and
punctuation. Where available, public Tree-sitter APIs use the current language's
highlights query. Missing parsers/queries or incomplete signatures retain lexical
fallback. The plugin installs no parsers and enables no injected languages.
These are syntax highlights, not LSP semantic tokens or server-specific signature rewrites.

Only visible rows are highlighted; plain identifiers do not create parsers.
`max_label_bytes` bounds each field. `highlight.max_bytes` bounds Tree-sitter input;
`cache_size` bounds cached text spans. No parser/tree is retained. Setup/dispose
clears caches. `highlight.enabled=false` disables label syntax highlighting;
`treesitter=false` uses lexical rules only. Matches are bold/underlined;
deprecated items use strikethrough, preserving syntax colors and selection backgrounds.

All 25 LSP kind groups are available as `CompletionToolsKindFunction`,
`CompletionToolsKindVariable`, etc., normally linked to standard `@function`, `@type`
and related groups. Unknown kinds use `CompletionToolsKindUnknown`. Other groups:
`CompletionToolsMatch`, `CompletionToolsDeprecated`, `CompletionToolsSource`,
`CompletionToolsMenu`, `CompletionToolsSelected`, `CompletionToolsBorder`,
`CompletionToolsDoc` and `CompletionToolsDocCode`. Defaults are recreated after
ColorScheme events while preserving explicit overrides.

`menu.highlight.custom(entry, ctx, text)` can return additional spans:

```lua
{ { start_byte, end_byte, "HighlightGroup", priority }, ... }
```

Ranges are zero-based, end-exclusive bytes; default priority is 190. Spans are
clipped and UTF-8 boundaries checked. Do not mutate entries. Match emphasis has
priority 200; deprecation has priority 210.

## Custom sources

Candidates use LSP CompletionItem fields. For example:

```lua
require("completion-tools").setup({
  sources = { "lsp", "path", "project" },
  providers = {
    project = {
      score_offset = 20,
      complete = function(ctx, callback)
        local cancelled = false
        vim.defer_fn(function()
          if not cancelled then
            callback({ items = { { label = "projectRoot", kind = 6 } }, reusable = true })
          end
        end, 10)
        return function() cancelled = true end
      end,
    },
  },
})
```

Source functions use dot calls, without an implicit `self`:

```lua
source.complete(ctx, callback) -> cancel_function?
source.resolve(entry, callback) -> cancel_function? -- Optional
source.execute(entry, ctx)                         -- Optional; after the primary edit
source.trigger(ctx) -> boolean                    -- Optional
source.dispose()                                  -- Optional
```

`complete` publishes `{ items = CompletionItem[], start_col?, reusable?,
is_incomplete?, pending? }`. `start_col` is a zero-based byte column in the current
line, defaulting to the keyword start. TextEdit ranges take precedence. Custom
edits default to UTF-8; items may override `_encoding`.

Callbacks may publish incremental results multiple times, including from libuv
callbacks. Set `pending=true` while more results are expected; omit/clear it in
the final response. The engine schedules callbacks and rejects stale results.
Only complete, stable, non-pending lists can be reusable for forward typing in
the same context. Backspace, newline, edits on other lines or InsertLeave invalidate
reuse. Providers should cancel promptly and own their external resources.
`resolve_on_accept=false` limits resolve to documentation, avoiding delayed acceptance edits.

Entries contain `item`, `context` (the originating context), `start_col` and `source_id`.
Resolve callbacks return a CompletionItem; execute runs after the synchronous
primary edit. A source expanding its own snippets may use `insertText=""` to clear
the typed prefix before expanding in execute. Leading-underscore item fields are
private provider metadata; standard `item.data` must be JSON serializable.

After setup, `register_source("name", source)` adds or replaces a provider.

## API and selection lifecycle

`require("completion-tools")` and `require("completion_tools")` expose the same module.
See [the help reference](completion-tools.txt) for the full method list.
Actions return `true` when handled, allowing keymap chains.

`select_next` / `select_prev` accept `{ count=1, wrap=true }`. For paging, use
`{ count=5, wrap=false }`: selection stops at the first/last item and still consumes
the key at a boundary. State getters return read-only values.

While typing/backspacing within one keyword, the previous menu remains visible
until new matches arrive or every provider completes without matches. Stale items
cannot be accepted. A fast empty source does not close the menu while another is
pending. Empty input or a context change closes it. Retained menus follow the cursor;
documentation remains for the same selection.

Candidate contents update immediately. The menu grows immediately and waits for
`menu.shrink_delay_ms` (default `120`) of quiet input/results before shrinking.
Extra rows are cleared and cannot be selected. Set this option to `0` to shrink
immediately. The menu keeps its opening direction while space permits; hiding
the menu resets its height and direction. Final empty results close it immediately.

Automatic preselection follows the latest first-ranked item, including higher
ranked results from slower providers. Navigation marks a manual selection, preserved
by item identity during refresh. If it disappears, selection/docs clear and accept
returns false; subsequent updates do not automatically reselect it. Navigate again
to choose an item. Typing/backspace restores the configured preselect behavior;
`preselect=false` continues to leave items unselected.

After primary acceptance, `User CompletionToolsAccept` fires with `args.data`
containing `item`, `source`, `bufnr` and optional `client_id`. Private item metadata
is omitted. `dispose()` closes UI, cancels work, releases caches and restores mappings.

## Migrating from blink.cmp

Built-in sources do not require Blink. Update your own LSP dependencies and
capability function references; this repository does not modify global configuration.

There is no Blink source compatibility layer, built-in Copilot/lazydev provider,
automatic brackets, ghost text, signature help or persistent frecency. Custom
sources can extend the plugin, but it is not a drop-in replacement for every Blink setup.
The matcher supports ASCII-insensitive prefixes, subsequences and camel-case
boundary bonuses. It does not perform typo correction or Unicode case folding;
the separate spell source offers native spelling corrections.

## Development

Tests require Neovim and Python 3. They exercise actual input in embedded Neovim
with an attached UI, a standard-library stdio LSP fixture and real PTY input.

```sh
./tests/run.sh
REAL_LSP=1 ./tests/run.sh                 # Also test local lua-language-server
LUASNIP_PATH=/path/to/LuaSnip ./tests/run.sh
NVIM=/path/to/nvim-0.11/bin/nvim ./tests/run.sh
INPUT_TOOLS_PATH=/path/to/input-tools.nvim ./tests/run.sh # External command-line layout/resizing
stylua --check lua tests
```

Benchmarks use a locally installed Blink with its Rust backend already built;
nothing is downloaded or built automatically.

```sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
BENCH_SOURCE=buffer BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
./tests/bench.sh bench_menu              # Multi-column highlighting and native Lua queries
DICTIONARY_FILE=/path/to/words.txt ./tests/bench.sh bench_words # Worker lookup/event-loop gaps
```
