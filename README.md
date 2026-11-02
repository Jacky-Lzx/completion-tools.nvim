# completion-tools.nvim

面向 Neovim 0.11+ 的补全插件。纯 Lua，无编译步骤，无必需的第三方依赖。

已实现 LSP、异步路径、缓冲区单词、snippet、带 kind 图标与语法高亮的多列浮动菜单、文档预览，以及可选的 Ex 命令行补全。使用增量单词索引、请求取消、完整 LSP 列表的前向复用和 top-k 排序，减少每次输入的工作量。

另提供独立的 `dictionary` 和 `spell` 来源：自定义词典与原生拼写建议在后台 Neovim
进程中计算，不依赖 Blink、plenary 或额外可执行程序。

已用本机 blink.cmp v1.10.2 的 Rust 后端完成受控对照，覆盖 1,000、10,000、20,000 个候选，输入到菜单更新延迟达到同一毫秒量级。两者均使用简化菜单和相同候选集；这不是完整个人配置或所有语言服务器的性能保证。测量条件、原始数据和匹配能力差异见 [性能记录](doc/performance.md)。

## 安装

本地开发目录的 lazy.nvim 配置：

~~~lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/completion-tools.nvim"),
  name = "completion-tools.nvim",
  main = "completion-tools",
  event = { "InsertEnter", "CmdlineEnter" },
  opts = {},
}
~~~

也可以把项目加入 runtimepath 后直接调用：

~~~lua
require("completion-tools").setup()
~~~

使用此插件时禁用其他自动补全引擎，避免多个引擎争抢菜单和按键。
项目不会自行修改你的 Neovim 配置。

## LSP

在启动语言服务器前合并补全能力。这个函数不需要先调用 setup：

~~~lua
local cmp = require("completion-tools")
vim.lsp.config("*", {
  capabilities = cmp.get_lsp_capabilities(),
})
-- 然后配置并启用你的服务器。
~~~

如果使用 lazy.nvim 和 nvim-lspconfig，让 LSP 配置依赖该插件，以保证初始化顺序。
`get_lsp_capabilities(existing_capabilities)` 保留调用方的其他能力字段。

LSP 来源支持多个客户端、触发字符、未完成列表重请求、UTF-8/16/32 范围、
TextEdit/InsertReplaceEdit、CompletionList.itemDefaults、额外文本编辑、snippet、
补全项 resolve 和接受后的命令。

选择候选时会提前 resolve。若在 resolve 完成前接受，先立即插入主要文本；
延迟返回的额外编辑仅在缓冲区自接受后未再改变时应用，避免覆盖新输入。
因此特别慢的 resolve 可能无法补上导入；这是明确的正确性取舍。

## 默认按键

| 按键 | 行为 |
| --- | --- |
| Ctrl-Space | 打开菜单；已打开时显示文档 |
| Ctrl-N / Ctrl-P | 选择下一个 / 上一个 |
| Ctrl-Y | 接受已选候选 |
| Tab | 接受候选；否则跳到下一个 snippet 占位符；否则回退 |
| Shift-Tab | 跳到上一个 snippet 占位符；否则回退 |
| Ctrl-E | 关闭菜单；否则回退 |
| Enter | 保留已有行为 |

默认预选第一项，不自动插入选择项。上下选择不会修改缓冲区。
仅编辑文字后自动请求补全；进入插入模式、单独移动光标或空白输入不会自动打开候选框。Ctrl-Space 仍可手动打开。
全局映射的原有行为会作为 fallback；buffer-local 映射保留 Neovim 原本的优先级。
再次 setup 或 dispose 会还原插件仍持有的映射，保留之后安装的映射。

`keymap` 是整个插入/选择模式映射表的替换；`keymap = {}` 表示不安装这些映射。
命令行使用独立的 `cmdline.keymap`，不会继承插入模式的 Enter、pairs 或 snippet 动作。
需要部分覆盖默认值时：

~~~lua
local keys = vim.deepcopy(require("completion_tools.config").defaults.keymap)
keys["<CR>"] = { "accept", "fallback" }
keys["<A-j>"] = { "select_next", "fallback" }
keys["<A-k>"] = { "select_prev", "fallback" }
keys["<C-d>"] = { "scroll_documentation_down", "fallback" }
keys["<C-u>"] = { "scroll_documentation_up", "fallback" }
require("completion-tools").setup({ keymap = keys })
~~~

动作也可以是 `function(cmp)`。返回 true 表示已处理，false/nil 继续下一个动作；
返回字符串时按 Neovim 按键序列输入。动作在允许修改缓冲区的普通回调中执行。

~~~lua
keys["<CR>"] = {
  "accept",
  function()
    return require("pairs").expr("<CR>")
  end,
  "fallback",
}
~~~

## 配置

常用选项及其默认值：

~~~lua
require("completion-tools").setup({
  enabled = true, -- 也可以是 function() -> boolean
  auto_show = true,
  min_keyword_length = 1,
  debounce_ms = 0,
  max_items = 50,
  preselect = true,
  keyword_pattern = [[\k*$]],
  sources = { "lsp", "path", "buffer", "snippets" },
  providers = {
    -- lsp = { score_offset = 40, enabled = true },
    -- path = { score_offset = 30 },
    -- buffer = { score_offset = 0 },
    -- snippets = { score_offset = 30 },
  },
  menu = {
    max_height = 12, min_width = 18, max_width = 72, border = "single",
    columns = { { "kind_icon" }, { "label", gap = 1 }, { "kind" }, { "source" } },
    column_gap = 1, padding = 1,
    kind_icons = true, label_details = true, max_label_bytes = 1024,
    highlight = { enabled = true, treesitter = true, max_bytes = 1024, cache_size = 512 },
  },
  documentation = {
    auto_show = true,
    delay_ms = 150,
    max_width = 72,
    max_height = 18,
    border = "single",
  },
  buffer = {
    max_bytes = 1024 * 1024,
    max_words = 20000,
    max_buffers = 8,
    batch_lines = 128,
    min_length = 3, -- 单词的字节长度
  },
  path = { max_entries = 10000, cache_ms = 1000, show_hidden = false },
  dictionary = {
    files = {}, min_keyword_length = 3, max_items = 10,
    matching = "fuzzy", capitalize = true,
    max_bytes = 16 * 1024 * 1024, max_words = 500000, max_word_bytes = 256,
    timeout_ms = 5000,
  },
  spell = {
    min_keyword_length = 2, max_items = 3, debounce_ms = 60, timeout_ms = 5000,
    sort = "match", preselect_current_word = true, suggest_when_correct = false,
  },
  snippets = { preset = "default", collection = {} },
  cmdline = { enabled = false, auto_show = true, min_keyword_length = 1, types = { ":", "/", "?" } },
})
~~~

`sources` 可以是 `function(ctx) -> string[]`，用于按 filetype、语法上下文或 buffer
局部状态选择来源。配置中的列表整体替换，不隐式合并。

`providers[id]` 支持：

- `enabled`：boolean 或 `function(ctx) -> boolean`。
- `score_offset`：给来源的匹配分加偏移。
- `transform_items(ctx, items) -> items`：过滤或修改来源返回的候选列表。
- `module` 和 `opts`：加载一个提供 `new(opts)` 的自定义来源模块。
- `complete` 等来源方法：直接声明来源，见下文。

例如去掉 LSP 的 Text 和 Snippet 项：

~~~lua
providers = {
  lsp = {
    transform_items = function(_, items)
      return vim.tbl_filter(function(item)
        return item.kind ~= 1 and item.kind ~= 15
      end, items)
    end,
  },
}
~~~

### 缓冲区与路径

默认只补全当前普通缓冲区的单词。首次按 128 行分批索引，普通编辑只重新分词变化行；
插入或删除行时移动行索引。索引通过词频计数移除失效单词，不在每次输入时扫描整个文件。
超过 max_bytes 的缓冲区跳过；每个缓冲区最多 max_words 个不同单词，最多保留
max_buffers 个活跃索引，按使用时间淘汰。达到词数上限时不会保证包含文件内所有单词。

`buffer.get_bufnrs(ctx)` 可以指定多个缓冲区，例如相同 filetype 的已加载缓冲区。
`path.get_cwd(ctx)` 可以覆盖相对路径基准目录；默认是当前文件的目录，无文件名时用 cwd。
路径需包含斜杠，例如 `./`、`../`、`~/`、`/tmp/`。
通过 libuv 异步分批读取目录，缓存最多 32 个目录；输入点号时可显示隐藏文件。
目录项超过 max_entries 时只读取前面的条目，顺序由文件系统决定。

### Snippet

默认使用 Neovim 的 `vim.snippet`，并支持按 filetype 定义补全项：

~~~lua
snippets = {
  collection = {
    all = {
      { prefix = "todo", body = "TODO: $0", description = "待办事项" },
    },
    lua = {
      {
        prefix = "fn",
        body = { "function ${1:name}(${2:args})", "\t$0", "end" },
        description = "函数",
      },
    },
  },
}
~~~

`collection` 也可以是 `function(ctx) -> table`。
可以通过 `snippets.expand(text)`、`active(direction)`、`jump(direction)` 接入其他引擎。

使用已有的 LuaSnip 定义：

~~~lua
snippets = { preset = "luasnip" }
~~~

此时从 LuaSnip 读取当前 filetype 及其扩展中的可见、非正则触发 snippet，遵守 show_condition，
使用 LuaSnip 扩展、跳转和处理 LSP snippet。需由用户安装并配置 LuaSnip；
此模式不读取 collection。正则触发 snippet 继续使用 LuaSnip 自己的扩展机制。
原生 snippet 的占位符选择沿用 Neovim 的输入队列行为；跳转后等待选择完成再输入替换文本。

### 命令行

`cmdline = { enabled = true }` 启用 `:`、`/` 和 `?` 的自动补全：
`:` 使用原生 `getcompletion()`，支持命令名、选项/值、文件/目录、帮助、
Lua 成员和用户命令声明的补全；搜索使用缓冲区单词来源。
原生返回的顺序和匹配结果会保留，通配符与转义字符不会再次被通用匹配器过滤。
文件路径会转义空格等特殊字符；替换保留命令修饰符、no/inv 前缀、Lua 名称空间与光标后的文本。

命令行首次打开或只输入空白不会显示候选；键入有意义的命令后，空参数位置
（如 `:set `）可显示该上下文的候选。选择候选不自动插入：

| 命令行按键 | 行为 |
| --- | --- |
| Ctrl-Space | 手动打开 |
| Up / Down、Ctrl-P / Ctrl-N | 上下选择；无菜单时保留原有历史行为 |
| Tab | 接受；无菜单时请求补全；不执行命令 |
| Shift-Tab | 上一项；无菜单时请求补全 |
| Enter | 保持原有执行命令/确认搜索行为，不自动接受候选 |

`cmdline.keymap` 整体替换默认命令行映射，`{}` 禁用这些映射；
`cmdline.auto_show=false` 仅手动触发；`types={":"}` 可只启用 Ex 补全。
原生 wildmenu/popupmenu 活跃时让回原生按键，退出命令行后关闭候选。
`input()`、表达式寄存器等提示不在支持类型内，保留原有输入和补全。
Shell 命令（包括修饰符后的 !、read/write ! 与 terminal）及文件名反引号展开不进入自动补全。

此来源使用同步的原生 API；很慢的自定义命令补全函数或文件系统仍可能阻塞。
使用 lazy.nvim 时同时声明 `event={"InsertEnter","CmdlineEnter"}`，才能在首次打开命令行时加载。

外置命令行 UI 可通过 `cmdline.get_anchor(ctx)` 返回输入窗口的完整外框，
`{row=0, col=0, height=3}`，坐标为从 0 开始的屏幕单元，height 包含边框。
候选框避开整个外框，空间不足时翻到上方；未提供时按原生命令行布局摆放。
以下 input-tools 集成只使用它的公开布局 API，不加载 Blink 适配器：

~~~lua
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
~~~

`refresh_cmdline()` 不会因布局事件打开空闲菜单；重定位时保留选择，并使过期候选不可接受。

普通命令行候选（命令、帮助标签、选项、路径等）按 kind 整项着色，仅强调匹配字符，
不会把标签中的 `local`、连字符或尖括号当作代码。Lua 和 Vim 表达式/函数补全仍使用
对应语言的语法高亮，不继承当前编辑文件的语言。类型、来源列沿用主题高亮。
若需进一步调整，可覆盖 `CompletionToolsKindReference`（帮助标签）等 kind 高亮组，
或在 `menu.highlight.custom(entry, ctx, text)` 中按 `ctx.mode == "cmdline"` 与
`ctx.completion_type` 添加仅作用于指定命令行候选的高亮范围。

## 自定义来源

候选使用 LSP CompletionItem 的字段。下面的来源可和内置来源一起使用：

~~~lua
local cmp = require("completion-tools")
cmp.setup({
  sources = { "lsp", "path", "project" },
  providers = {
    project = {
      score_offset = 20,
      complete = function(ctx, callback)
        local cancelled = false
        vim.defer_fn(function()
          if not cancelled then
            callback({
              items = { { label = "projectRoot", kind = 6 } },
              reusable = true,
            })
          end
        end, 10)
        return function() cancelled = true end
      end,
    },
  },
})
~~~

来源接口：

~~~lua
source.complete(ctx, callback) -> cancel_function?
source.resolve(entry, callback) -> cancel_function? -- 可选
source.execute(entry, ctx)                         -- 可选，主要编辑已应用后调用
source.trigger(ctx) -> boolean                    -- 可选
source.dispose()                                  -- 可选
~~~

`complete` 是普通函数，使用点调用，不隐式传 self。结果为
`{ items = CompletionItem[], start_col?, reusable?, is_incomplete?, pending? }`。
start_col 为当前行从 0 开始的字节列，默认使用关键字起始列。
TextEdit 范围优先于 start_col；自定义来源的范围默认 UTF-8，可设置项的 `_encoding`。

callback 可调用多次以发布增量结果，也可从 libuv 回调调用；
尚有结果待返回时设置 `pending = true`，最后一次响应省略或设为 false。
引擎会处理调度和过期响应。reusable 只用于完整、稳定且不再 pending 的列表：
允许同一上下文内继续输入时复用；回删、换行、其他行编辑、离开插入模式会使其失效。
来源应及时响应取消并自行管理外部资源。
`source.resolve_on_accept = false` 可将 resolve 限于文档查询，避免接受后再请求延迟编辑。

`entry` 含有 `item`、`context`（产生该项时的上下文）、`start_col`、`source_id`。
resolve 的 callback 返回一个补全项；execute 在同步完成主要文本编辑后调用。
自定义来源若自己扩展 snippet，可用 `insertText = ""` 先清除已键入的前缀，再在 execute 中扩展。
以 `_` 开头的项字段属于来源私有元数据；标准 item.data 应可 JSON 序列化。

setup 后也可 `cmp.register_source("name", source)` 替换或新增来源。

## API 与事件

`require("completion-tools")` 和 `require("completion_tools")` 指向相同模块。

- `show({ sources = { ... } })`：手动补全，可临时选择来源。
- `hide()`、`is_menu_visible()`。
- `select_next({ count = 1, wrap = true })`、`select_prev({ count = 1, wrap = true })`。
  翻页可用 `{ count = 5, wrap = false }`，越界时停在首尾，且仍返回 true 消费按键。
- `accept()`：接受选中项；不满足当前上下文时返回 false。
- `get_items()`、`get_selected_item()`、`get_context()`：读取状态，不要修改返回值。
- `show_documentation()`、`scroll_documentation_up()`、`scroll_documentation_down()`。
- `snippet_forward()`、`snippet_backward()`。
- `get_lsp_capabilities(base?)`。
- `refresh_keymaps()`：依赖插件延迟安装映射后，重新安装补全映射并更新 fallback，不重置补全状态。
- `refresh_cmdline()`：外置命令行 UI 布局更新后，刷新已经打开的候选框。
- `dispose()`：关闭界面、取消工作、释放缓存并还原映射。

动作成功返回 true，可组成按键链。同一关键字内继续输入或退格时，保留前一帧菜单，
但不允许接受过期结果；快速来源的空结果不会在其他来源仍待返回时关闭菜单。
有新匹配时立即更新，全部来源完成且没有匹配时关闭；清空输入或离开当前上下文时关闭旧菜单。
等待期间菜单会跟随光标位置，同一选中候选的文档保持显示。

默认预选始终跟随最新排序的第一项，因此较慢来源返回更高排名候选时会自动选中它。
使用 `select_next` / `select_prev`（包括方向键、Ctrl-n/p 等映射）后，异步刷新按候选身份
保留手动选择；若该候选消失则清空选择和文档，`accept()` 返回 false，后续刷新不会自动重选。
再次导航可重新选择；继续输入或退格会恢复 `preselect` 配置，`preselect=false` 时仍不自动选择。

接受后发送 `User CompletionToolsAccept`，`args.data` 包含 item、source、bufnr 和可选的
client_id；事件中的 item 不含私有元数据。
主题高亮组为 `CompletionToolsMenu`、`CompletionToolsBorder`、`CompletionToolsSelected`、
`CompletionToolsMatch`、`CompletionToolsSource`、`CompletionToolsDoc`、`CompletionToolsDocCode`。

运行 `:checkhealth completion-tools` 检查版本和多补全引擎冲突。

## 自定义词典和拼写来源

在 `sources` 中显式加入 `"dictionary"`、`"spell"`：

~~~lua
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
~~~

词典采用 UTF-8、每行一个词或短语，支持 CRLF、BOM、去重及带空格的路径。
`dictionary.files` 也可以是 `function(ctx) -> string[]`，列表整体替换。
`matching="fuzzy"` 使用本插件的前缀/子序列评分取前 `max_items` 项；
`"prefix"` 仅取前缀匹配，并用前三个字节的索引缩小搜索范围。
默认随输入将全小写词转换为首字母大写或全大写；`capitalize=false` 保留原样。

选中 Dict 候选后会异步调用本机 WordNet（`wn <原始单词> -over`），在文档窗口显示
英文词义，保持词表中的原始大小写进行查询。无需 Blink，也不会查询网络。
未安装 `wn` 或查不到词义时，词典补全照常工作。词表本身不包含释义，WordNet 不提供中文翻译。

~~~lua
dictionary = {
  documentation = { enabled = true, command = "wn", timeout_ms = 1500 },
}
~~~

`command` 可指定 WordNet 可执行文件路径；`enabled=false` 关闭词义查询。
只解析选中的候选，切换候选、输入、接受或关闭菜单会取消旧查询；接受时只插入单词。
每个词典来源缓存最多 128 个查询结果，每项最多保留 64 KiB 文本，setup/dispose 后释放。

文件内容与查询缓存在后台；每次请求检查文件状态，修改后重新索引。
同时保留最多四组文件索引、每组 64 个查询。文件总字节预算默认 16 MiB，
词数预算 500,000，单词最长 256 字节；超过剩余字节预算的文件跳过，
达到词数预算后截断；缺失文件或预算截断只警告一次，不影响其他来源。

拼写只在当前窗口 `spell` 开启时工作，继承 `spelllang`、`spellfile`、
`spellcapcheck`、`spelloptions`、`spellsuggest` 与 runtimepath。
可用 `enable_in_context=function(ctx) -> boolean` 进一步按语法/文件类型限制。
编译后的个人词表更新时后台进程会重载。

- `sort="match"`：优先匹配程度更高的词，相同分数按词排序，适合部分输入；
  字母换位等无法通过子序列匹配的纠错建议仍保留，排在匹配项之后。
- `sort="suggestion"`：保留原生 `spellsuggest()` 的建议顺序。
- 拼写正确时默认只保留当前词并标记预选；`preselect_current_word=false` 隐藏当前词；
  `suggest_when_correct=true` 允许同时显示其他建议。

排序仅作用于拼写来源内部，跨来源仍使用分数偏移和统一去重。
两种来源均为 Text 类型，沿用灰色配色；接受时插入建议词，不会插入用于筛选的错词。

两个来源各自按需启动一个持久的无界面 Neovim，使用当前 Neovim 可执行文件，
不加载用户 init；闲置时保留以复用索引，`dispose`/重新 setup/退出时终止。
只保留一个执行中的请求与一个最新待处理请求，取消或过期的结果不会打开菜单。
拼写默认延迟 60 ms 合并连续输入；其他来源可先显示结果。
首次大词典加载和慢语言的建议可能延迟到达，但不占用主编辑器线程。
依赖用户 init 中函数的 `spellsuggest=expr:...` 不会自动复制到后台进程。

## 菜单布局与高亮

默认布局为「kind 图标｜名称、签名与说明｜kind 名称｜来源」。`columns` 中每组可放多个组件，
组间用 `column_gap`，组内用 `gap`（默认 1）分隔。支持 `kind_icon`、`label`、`kind`、
`source`、`label_detail`、`label_description`；列列表整体替换，组件不可重复。
来源列显示 LSP、Buffer、Path、Snippets、Cmdline、Dict 或 Spell；自定义来源保留其 ID。
列宽按保留的候选统一计算，滚动时对齐；窄窗口优先压缩名称，同时保留可读名称空间。
文本按显示宽度截断，extmark 使用 UTF-8 字节范围。

`label` 默认组合 LSP `labelDetails.detail` 与 `labelDetails.description`；
缺少 detail 时可显示单行 `item.detail`。只改变展示，不修改用于接受的 CompletionItem。
使用独立 detail/description 列时可设 `label_details=false`，避免重复。
`kind_icons=false` 隐藏图标，也可设 `kind_icons={ Function="ƒ", Variable="v" }` 覆盖部分图标。
默认图标需要 Nerd Font。

Text 的图标、名称和 kind 名称统一使用灰色（`CompletionToolsKindText` 默认链接 `Comment`），
不再按代码词法另行染色，匹配强调仍保留。
Snippet 的图标、名称和 kind 名称默认链接到 `Special`，也可用
`CompletionToolsKindSnippet` 单独配色。文档预览隐藏 Markdown 代码围栏及行内代码的
反引号，保留正文、代码缩进和高亮；布局按处理后的可见内容计算。
`detail` 与 `kind="plaintext"` 文档保持字面内容，代码中的反引号不会被删除。
代码块沿用菜单的词法/Tree-sitter 高亮配置，行内代码基础高亮组为 `CompletionToolsDocCode`
（默认链接 `String`）；菜单的自定义高亮回调只用于真实候选。

高亮独立实现，不依赖 Blink 或 colorful-menu。使用 kind 颜色作为名称基础色，
内置词法规则区分类型、参数、关键字、字符串、数字及标点；可用时通过 Neovim 公共
Tree-sitter 接口读取当前语言的 highlights query。解析器或 query 缺失、签名不完整时
保留词法回退；不安装解析器，不启用注入语言。它不是语言服务器的语义 token，
也不包含 colorful-menu 针对特定服务器的签名改写。

只对可见行计算高亮；普通标识符不创建解析器。文本默认限制为 1024 字节，
Tree-sitter 输入上限为 `highlight.max_bytes`，缓存最多 `cache_size` 条纯文本范围，
不保留解析器或语法树；重新 setup/dispose 清空缓存。
`highlight.enabled=false` 关闭名称语法高亮；`treesitter=false` 仅用内置规则。
匹配字符加粗并加下划线，弃用项加删除线；两者保留语法前景与选中背景。

主题可设置 `CompletionToolsKindFunction`、`CompletionToolsKindVariable` 等全部 25 个
LSP kind 对应组（未知值用 `CompletionToolsKindUnknown`），默认链接到标准 `@function`、
`@type` 等组。其他组包括 `CompletionToolsMatch`、`CompletionToolsDeprecated`、
`CompletionToolsSource`、`CompletionToolsMenu`、`CompletionToolsSelected`、
`CompletionToolsBorder` 和 `CompletionToolsDoc`；ColorScheme 后会补建默认组，保留显式覆盖。

可用 `menu.highlight.custom=function(entry, ctx, text)` 添加自定义高亮，返回
`{ {start_byte, end_byte, "HighlightGroup", priority?}, ... }`，
起点从 0 开始、终点不包含，默认 priority=190；范围会裁剪到可见文本并检查 UTF-8 边界。
不要修改传入的候选对象。匹配强调 priority=200，弃用删除线为 210。

## 从 blink.cmp 迁移

内置来源无需 blink.cmp。LSP 能力、LuaSnip、来源分数、Enter/Tab 行为可以按上文配置。
请同时修改你自己的 LSP 依赖与能力函数引用；本仓库不代替你修改全局配置。

当前没有 Blink 来源协议兼容层，也没有内置的 Copilot、lazydev 来源，
自动括号、ghost text、signature help 或持久化 frecency。
可通过来源接口扩展；这些差异意味着目前不是完整个人 Blink 配置的直接替换。
通用匹配器支持忽略 ASCII 大小写的前缀、子序列和驼峰边界加分，不做拼写纠错或 Unicode
大小写折叠；可选的 spell 来源通过原生拼写建议独立提供纠错。

## 开发与验证

~~~sh
./tests/run.sh
REAL_LSP=1 ./tests/run.sh                 # 额外运行本机 lua-language-server
LUASNIP_PATH=/path/to/LuaSnip ./tests/run.sh
NVIM=/path/to/nvim-0.11/bin/nvim ./tests/run.sh
INPUT_TOOLS_PATH=/path/to/input-tools.nvim ./tests/run.sh # 外置命令行、上下避让及缩放
stylua --check lua tests

BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
./tests/bench.sh bench_menu              # 三列、高亮及原生 Lua query 的热渲染
DICTIONARY_FILE=/path/to/words.txt ./tests/bench.sh bench_words # 实际词典后台检索与事件循环间隔
BENCH_SOURCE=buffer BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
~~~

测试只需要 Neovim 和 Python 3。包括独立嵌入式 Neovim 的实际按键、附着 UI、
标准库实现的 stdio LSP fixture，以及真实 PTY 输入测试。
性能对照需要已编译 Rust 后端的 blink.cmp，不会自动下载或构建。

MIT License.
