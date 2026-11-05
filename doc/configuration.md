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
  timeout_ms = 2000,
  max_items = 50,
  preselect = true,
  accept = { mode = "replace" },
  ranking = {
    history = { enabled = false, max_entries = 1000 },
    proximity = { enabled = false, lines = 50 },
    max_typos = 0,
  },
  keyword_pattern = [[\k*$]],
  sources = { "lsp", "path", "buffer", "snippets" },
  providers = {},
  menu = {
    max_height = 12, inverse = "auto", shrink_delay_ms = 50, update_interval_ms = 16,
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
  copilot = { debounce_ms = 150, max_items = 3 },
  cmdline = {
    enabled = false, auto_show = true, fuzzy = true,
    min_keyword_length = 1, types = { ":", "/", "?" },
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
Background refreshes at the same input snapshot preserve a manually opened
session and its explicit source list, including after LSP attach/detach. A new
edit uses the ordinary automatic trigger rules again.

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

## Ranking

Matching defaults to the original deterministic prefix/subsequence scoring.
Enable optional ranking features independently:

```lua
ranking = {
  history = { enabled = true, max_entries = 1000 },
  proximity = { enabled = true, lines = 50 },
  max_typos = 1, -- Default 0; accepts 0 or 1
}
```

History learns successful acceptance, scoped by source and filetype, and combines
frequency with recency. It persists at `stdpath("state")/completion-tools/history.json`;
set `ranking.history.path` to override. Records are bounded and saved after a quiet
500 ms or on disposal/exit. Missing/corrupt files are ignored. Proximity weights
words in a bounded window around the cursor. Bonuses are small enough to preserve
prefix-versus-subsequence matching tiers. Disabling either feature removes its bonus.
History ignores transient client IDs and edit positions, so it survives restarts.
One-typo matching handles substitution, insertion, deletion and transposition in
ASCII prefixes of 4–32 characters, only after literal matching fails. It does not
perform Unicode case folding. Command-line matching and ordering stay native.

## Provider configuration

Each `providers[id]` supports:

| Option | Purpose |
| --- | --- |
| `enabled` | Boolean or `function(ctx) -> boolean` |
| `score_offset` | Add an offset to the provider's match scores |
| `transform_items(ctx, items)` | Filter or modify the returned item list |
| `timeout_ms` | Total request deadline; defaults to global `timeout_ms = 2000`; `0` disables |
| `max_items` | Maximum matched/ranked items contributed by this source |
| `fallback_for` | Source IDs which must all finish without matches before this source runs |
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

To use buffer words only when LSP has no matches:

```lua
sources = { "lsp", "buffer" },
providers = {
  lsp = { timeout_ms = 1500, max_items = 30 },
  buffer = { fallback_for = { "lsp" }, max_items = 10 },
},
```

Fallback waits for final responses (including streaming sources). It tests the
current query after transforms/matching, so an unrelated nonempty list counts as
no matches. All listed dependencies must have no matches; disabled/unselected
sources count as empty. Chains are supported and cycles are rejected at setup.
A skipped fallback suppresses its downstream fallback chain. Dependencies should
also appear in `sources` when you want them queried. Sources run independently
otherwise. Limits apply after ranking, before global merging/deduplication.
Deadlines cancel pending requests and reject late responses; partial results
already received remain usable. A timeout can release waiting fallback sources.
Timeouts cannot interrupt synchronous Lua callbacks or native `getcompletion()`.

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

### Acceptance and indentation

`accept = { mode = "replace" }` is the default. Set `mode = "insert"` to use
the insert range of an LSP InsertReplaceEdit, preserving text after the cursor.
A regular TextEdit always uses its server-provided range. Override one acceptance
with `require("completion-tools").accept({ mode = "insert" })`, for example in
a function keymap action. Both modes retain UTF encodings, imports, snippets
and cached-range rebasing.

LSP `insertTextMode=1` preserves supplied whitespace; `2` adjusts continuation
lines to the receiving indentation while retaining relative indentation.
The LSP capability advertises default mode `2`; items without an explicit mode
from LSP use that default. Other sources retain their previous behavior unless
they specify `insertTextMode`. Native snippets and the LuaSnip preset avoid
double indentation and retain placeholder editing/jumping.

Custom `snippets.expand(text, options)` callbacks receive already-adjusted text
and `{ insert_text_mode?, indentation, bufnr }`. When a mode is present, disable
the engine's own automatic indentation. For example, LuaSnip uses
`lsp_expand(text, { indent = not options.insert_text_mode })`.
The indentation modes follow the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#insertTextMode).

### Protocol support

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
`cmdline.fuzzy=true` (default) temporarily enables native fuzzy matching for Ex
completion, restoring `wildoptions` after each call, including failed calls.
Set `cmdline.fuzzy=false` to follow your existing `wildoptions` instead.
Neovim does not support native fuzzy matching for file/directory names; those
continue to use wildcard expansion. Custom completers follow native semantics.
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

## Copilot

The opt-in source directly starts GitHub's
[Copilot Language Server](https://github.com/github/copilot-language-server-release)
using Neovim's LSP client. Install the server via `npm install -g
@github/copilot-language-server`, Mason or your system package manager. A
GitHub account with Copilot access is required. There is no `copilot.lua`
dependency and no chat or separate suggestion UI.

```lua
require("completion-tools").setup({
  sources = { "copilot", "lsp", "path", "buffer", "snippets" },
  copilot = {
    command = { "copilot-language-server", "--stdio" },
    debounce_ms = 150,
    max_items = 3,
    show_status = true, -- Status in the completion window footer
    filetypes = { markdown = false, text = false },
    -- ["*"] = false in filetypes disables unlisted types.
    -- should_attach = function(bufnr) return ... end,
    settings = {}, -- Copilot server settings, e.g. http.proxy
  },
  providers = { copilot = { score_offset = 50, timeout_ms = 5000 } },
})
```

The default `filetypes = {}` allows normal, listed buffers. Special/unlisted
buffers are excluded; `should_attach(bufnr)` can further restrict attachment.
For Mason installations outside PATH, set `command` to its executable path.
For the JavaScript distribution, use `{ "node", "/path/to/dist/language-server.js",
"--stdio" }` (Node.js 20.8+). Command lists replace defaults in full. Server
credentials and authentication storage are managed by the official server.

Commands:

- `:CompletionToolsCopilot auth`: show the device code and open GitHub login.
- `:CompletionToolsCopilot status`: show startup and server status/errors.
- `:CompletionToolsCopilot disable` / `enable`: control completion globally.
- `:CompletionToolsCopilot restart`: stop the client; the next request starts it.
- `:CompletionToolsCopilot signout`: sign out through the official server.

Remove the `copilot.lua` plugin spec and `require("copilot").setup()` when
migrating. Replace `:Copilot auth` with `:CompletionToolsCopilot auth`.
The server starts only on a Copilot request or explicit authentication; default
completion-tools setup starts no Copilot process. Missing executables produce a
warning with installation guidance; other completion sources keep working.

New requests debounce independently (150 ms by default; 0 disables it). Typing,
hiding the menu and disposal cancel pending timers and in-flight requests.
Refreshes at an identical document/cursor snapshot share one pending Copilot
request, including its original debounce deadline. Each subscriber can cancel
independently; hiding or changing the snapshot cancels unused work immediately.
Completed suggestions are reused immediately while forward typing on the same
line exactly follows their generated text. Each edit keeps only matching
candidates and adjusts their UTF-16 replacement ranges; the candidates remain
selectable without another request. Matching spaces and punctuation can continue
a cached suggestion even when they would not trigger a new request. A cache miss
uses the normal trigger rules and debounce. Deletion, newline, cursor movement,
other edits, hiding and leaving the buffer/window/insert mode invalidate this cache.
Single-line edits ending at the cursor consume an identical suffix already after
the cursor (such as a closing parenthesis), avoiding duplicate delimiters. Explicit
replacement ranges and multiline suggestions retain their server-defined meaning.
Renaming a file or saving an unnamed buffer closes the old document before
opening its new URI. Filetype changes reattach the document with its new language;
old suggestions are invalidated during these transitions.
The client registers each eligible buffer's project root as a workspace, reusing
one server across projects. `copilot.root_dir` accepts a directory or a function
`(bufnr) -> directory?`; by default the nearest `.git` root (or cwd) is used.
`copilot.workspace_folders` lists additional directories. Canonical paths are
deduplicated, and new roots are announced to servers supporting workspace folders.
Request `doc.relativePath` is relative to that buffer's project root.
Language IDs normalize common Neovim filetypes (for example `sh` to `shellscript`
and `text` to `plaintext`), including dotted filetypes. Override individual names
with `copilot.language_ids = { ["my.ft"] = "server-language" }`.
`accept_word()` and `accept_line()` accept part of the selected Copilot suggestion
and keep its remainder selected, without a new request. Word acceptance consumes
leading punctuation/whitespace and the next keyword plus trailing horizontal
space; line acceptance includes the next newline and indentation. UTF-16 ranges,
multiline replacements and cumulative accepted lengths are updated at each step.
These actions have no default key bindings. For example, extend the default map:

```lua
keymap = vim.tbl_extend("force", require("completion_tools.config").defaults.keymap, {
  ["<M-w>"] = { "accept_word", "fallback" },
  ["<M-l>"] = { "accept_line", "fallback" },
})
```

Partial acceptance requires a literal continuation of the text before the cursor;
corrections to already typed text still use full `accept()`. Other sources return
`false` from these actions, allowing the configured fallback.
The cycling API requests alternatives; duplicates are removed and at most
`copilot.max_items` (default 3) are retained. The service may return fewer.
Copilot fields use `CompletionToolsCopilot` (purple, `#cba6f7`), preserving the
selected background and match emphasis. UTF-16 ranges and multiline literal text
are preserved. Acceptance reports the selected suggestion to Copilot. Command-line completion never
requests Copilot. `copilot.show_status` (default `true`) displays the former Copilot
status icons in the completion window footer: `` ready, `` disabled, `` warning
or unavailable, and `` sign-in required. Waiting, startup and generation show
`` with an animated dots spinner; an idle state with no suggestions uses a muted
``. The animation advances every 80 ms while visible and stops on completion,
hide or disposal. With no candidates, a small status-only window appears. Icons
never become candidates; animation changes only the border, preserving selection,
menu contents and geometry. Status notifications never reopen a dismissed menu.
Set `show_status = false` to hide it. `:CompletionToolsStatus` and `:checkhealth completion_tools`
also include the native client's status.

Buffers attached to the native client are synchronized in full on open and then
incrementally on edits through Neovim's LSP client. Completion requests contain
the document URI/version and cursor position, so the local Copilot server has
context both before and after the cursor. The current keyword only controls menu
triggering/filtering. The official server prepares the final model prompt; this
plugin does not choose an exact cloud context window.

## Menu and highlighting

The default layout is **kind icon | label, signature and description | kind | source**.
Each `columns` group can contain multiple components, separated by `gap` (default 1);
`column_gap` separates groups. Supported components: `kind_icon`, `label`, `kind`,
`source`, `label_detail`, `label_description`. The column list replaces defaults;
components cannot repeat.

Sources display as LSP, Buffer, Path, Snippets, Cmdline, Dict, Spell and Copilot. Custom sources
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
source.reuse(ctx, response, previous_ctx) -> response? -- Optional; validated reuse
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
For generated edits, `reuse` may return an updated response only after validating
the new context, individual candidates and replacement ranges. Returning `nil`
discards that cache and calls `complete` under the normal trigger policy. This
cache permits only uninterrupted same-line insertions at the last cursor and is
cleared on hide; it is independent of ordinary `reusable=true` word-list caching.
Only final responses are passed to `reuse`. A valid response can continue through
otherwise blocked characters without starting other sources at those characters.
`resolve_on_accept=false` limits resolve to documentation, avoiding delayed acceptance edits.

Entries contain `item`, `context` (the originating context), `start_col` and `source_id`.
Resolve callbacks return a CompletionItem; execute runs after the synchronous
primary edit. A source expanding its own snippets may use `insertText=""` to clear
the typed prefix before expanding in execute. Leading-underscore item fields are
private provider metadata; standard `item.data` must be JSON serializable.

After setup, `register_source("name", source)` adds or replaces a provider.

## API and selection lifecycle

### Runtime diagnostics

Run `:CompletionToolsStatus` after setup, or call:

```lua
local status = require("completion-tools").get_status()
require("completion-tools").show_status() -- Print the same snapshot
```

The snapshot reports `configured`, `enabled`, `reason`, `last_request_reason`,
`menu_visible`, `ready`, `stale`, `mode`, `filetype`, and a `sources` map.
Each source reports registration/selection, configured enablement and limits,
its latest status/elapsed milliseconds, raw and shown candidate counts, provider
request/cache-hit/response counters, timeout/error counts and the latest callback
error. Statuses include `not_requested`, `waiting`, `pending`, `done`, `disabled`,
`skipped`, `timeout`, `cancelled` and `error`. Errors remain inspectable after a
later successful request. `last_request_reason` preserves trigger filtering or
no-match decisions after leaving Insert mode to run the status command.

Counters cover the current setup lifetime and reset on setup; cache hits do not
increment provider request counts. Timings measure source completion, including
async wait and response processing, rather than terminal drawing. Raw counts are
after transforms and before quotas/deduplication; shown counts are contributions
to the current menu. Retained stale menus have `stale=true` and cannot be accepted.
Getters return detached snapshots. Diagnostics store counters and errors, with no
candidate-body log or network telemetry. `:checkhealth completion-tools` includes
source status, missing registrations, recent errors and deadlines.
The status command is removed on disposal only while still owned by the plugin.

### Candidate lifecycle

Plain words deduplicate across sources. Candidates with different signatures,
JSON data, clients, edit ranges, additional edits, commands or snippet behavior
retain separate identities, so overloads and alternative imports remain selectable.
Object key ordering does not affect identity; streaming refreshes preserve the
selected semantic candidate even when providers rebuild and reorder their tables.

`require("completion-tools")` and `require("completion_tools")` expose the same module.
See [the help reference](completion-tools.txt) for the full method list.
Actions return `true` when handled, allowing keymap chains.

`select_next` / `select_prev` accept `{ count=1, wrap=true }`. For paging, use
`{ count=5, wrap=false }`: selection stops at the first/last item and still consumes
the key at a boundary. `select_next` moves down and `select_prev` moves up on
screen, including reversed menus. State getters return read-only values in ranked order.

While typing/backspacing within one keyword, the previous menu remains visible
until new matches arrive or every provider completes without matches. Stale items
cannot be accepted. A fast empty source does not close the menu while another is
pending. Empty input or a context change closes it. Retained menus follow the cursor;
documentation remains for the same selection.

The first useful result for each input is displayed immediately. Subsequent
asynchronous results are combined within `menu.update_interval_ms` (default `16`)
of the previous publication. The deadline is fixed, so continuous streaming cannot
postpone updates indefinitely. Set `0` to publish every event-loop batch.
Navigation and acceptance act on the displayed candidates without this delay.

Width and column allocations are retained while the menu is open: columns grow
into available space, and shorter results do not pull the border or following
columns back. This can leave spare space or truncate new metadata until the next
session. Resizing to a smaller editor may reclaim column space. Hiding the menu
resets these allocations. Unchanged rows and highlights are preserved on redraw.

When results are published, the menu grows immediately and waits for
`menu.shrink_delay_ms` (default `50`) of quiet input/results before shrinking.
Extra rows are cleared and cannot be selected. Set this option to `0` to shrink
immediately. Placement reserves `menu.max_height` regardless of the current result
count: prefer below when it fits, otherwise choose the side with more space
(below wins ties). Small initial results and later growth/shrinkage therefore use
the same side. Moving/resizing the input can change the direction. Hiding resets
the retained height. Final empty results close the menu when published.

`menu.inverse` controls the visible row order in Insert and command-line modes:

- `"auto"` (default): reverse above the input, keeping the first-ranked candidate
  closest to the input; use normal order below.
- `true`: always reverse the visible rows.
- `false`: always show normal top-to-bottom order.

Ranking, preselection, acceptance and selection identity remain the same. In a
reversed menu, downward keys still move down and upward keys still move up;
paging and boundary clamping follow the same screen directions. Retained blank
rows stay opposite the first item.

Automatic preselection follows the latest first-ranked item, including higher
ranked results from slower providers. Navigation marks a manual selection, preserved
by item identity during refresh. If it disappears, selection/docs clear and accept
returns false; subsequent updates do not automatically reselect it. Navigate again
to choose an item. Typing/backspace restores the configured preselect behavior;
`preselect=false` continues to leave items unselected.

After primary acceptance, `User CompletionToolsAccept` fires with `args.data`
containing `item`, `source`, `bufnr` and optional `client_id`. Private item metadata
is omitted. Partial acceptance also provides `partial = "word" | "line"` and the
inserted `text`. `dispose()` closes UI, cancels work, releases caches and restores mappings.

## Migrating from blink.cmp

Built-in sources do not require Blink. Update your own LSP dependencies and
capability function references; this repository does not modify global configuration.

There is no Blink source compatibility layer, built-in lazydev provider,
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
