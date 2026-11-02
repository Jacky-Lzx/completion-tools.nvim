# completion-tools.nvim

面向 Neovim 0.11+ 的补全插件。纯 Lua，无编译步骤，无必需的第三方依赖。

已实现 LSP、异步路径、缓冲区单词、snippet、带 kind 图标与语法高亮的多列浮动菜单、文档预览，以及可选的 Ex 命令行补全。使用增量单词索引、请求取消、完整 LSP 列表的前向复用和 top-k 排序，减少每次输入的工作量。

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

`keymap` 是整个映射表的替换；`keymap = {}` 表示不安装映射。
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
    columns = { { "kind_icon" }, { "label", gap = 1 }, { "kind" } },
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
  snippets = { preset = "default", collection = {} },
  cmdline = { enabled = false, min_keyword_length = 1 },
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

`cmdline = { enabled = true }` 启用 `:` 的 Ex 补全，Tab 接受不会执行命令。
Enter 保持执行命令的原有行为，`/` 和 `?` 继续使用 Neovim 自身的行为。
shell 命令不进入此来源。

此来源使用原生 `getcompletion()`，它是同步 API；很慢的自定义命令补全函数仍可能阻塞。
浮窗按原生命令行位置摆放，尚未对外置 cmdline UI 的浮动位置做适配。

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
`{ items = CompletionItem[], start_col?, reusable?, is_incomplete? }`。
start_col 为当前行从 0 开始的字节列，默认使用关键字起始列。
TextEdit 范围优先于 start_col；自定义来源的范围默认 UTF-8，可设置项的 `_encoding`。

callback 可调用多次以发布增量结果，也可从 libuv 回调调用；
引擎会处理调度和过期响应。reusable 只用于完整且稳定的列表：
允许同一上下文内继续输入时复用；回删、换行、其他行编辑、离开插入模式会使其失效。
来源应及时响应取消并自行管理外部资源。

`entry` 含有 `item`、`context`（产生该项时的上下文）、`start_col`、`source_id`。
resolve 的 callback 返回一个补全项；execute 在同步完成主要文本编辑后调用。
自定义来源若自己扩展 snippet，可用 `insertText = ""` 先清除已键入的前缀，再在 execute 中扩展。
以 `_` 开头的项字段属于来源私有元数据；标准 item.data 应可 JSON 序列化。

setup 后也可 `cmp.register_source("name", source)` 替换或新增来源。

## API 与事件

`require("completion-tools")` 和 `require("completion_tools")` 指向相同模块。

- `show({ sources = { ... } })`：手动补全，可临时选择来源。
- `hide()`、`is_menu_visible()`。
- `select_next({ count = 1 })`、`select_prev({ count = 1 })`。
- `accept()`：接受选中项；不满足当前上下文时返回 false。
- `get_items()`、`get_selected_item()`、`get_context()`：读取状态，不要修改返回值。
- `show_documentation()`、`scroll_documentation_up()`、`scroll_documentation_down()`。
- `snippet_forward()`、`snippet_backward()`。
- `get_lsp_capabilities(base?)`。
- `refresh_keymaps()`：依赖插件延迟安装映射后，重新安装补全映射并更新 fallback，不重置补全状态。
- `dispose()`：关闭界面、取消工作、释放缓存并还原映射。

动作成功返回 true，可组成按键链。新结果待返回时保留前一帧菜单，但不允许接受过期结果。

接受后发送 `User CompletionToolsAccept`，`args.data` 包含 item、source、bufnr 和可选的
client_id；事件中的 item 不含私有元数据。
主题高亮组为 `CompletionToolsMenu`、`CompletionToolsBorder`、`CompletionToolsSelected`、
`CompletionToolsMatch`、`CompletionToolsSource`、`CompletionToolsDoc`、`CompletionToolsDocCode`。

运行 `:checkhealth completion-tools` 检查版本和多补全引擎冲突。

## 菜单布局与高亮

默认布局为「kind 图标｜名称、签名与说明｜kind 名称」。`columns` 中每组可放多个组件，
组间用 `column_gap`，组内用 `gap`（默认 1）分隔。支持 `kind_icon`、`label`、`kind`、
`source`、`label_detail`、`label_description`；列列表整体替换，组件不可重复。
列宽按保留的候选统一计算，滚动时对齐；窄窗口优先压缩名称，同时保留可读名称空间。
文本按显示宽度截断，extmark 使用 UTF-8 字节范围。

`label` 默认组合 LSP `labelDetails.detail` 与 `labelDetails.description`；
缺少 detail 时可显示单行 `item.detail`。只改变展示，不修改用于接受的 CompletionItem。
使用独立 detail/description 列时可设 `label_details=false`，避免重复。
`kind_icons=false` 隐藏图标，也可设 `kind_icons={ Function="ƒ", Variable="v" }` 覆盖部分图标。
默认图标需要 Nerd Font。

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

当前没有 Blink 来源协议兼容层，也没有内置的 Copilot、lazydev、词典、拼写来源，
自动括号、ghost text、signature help 或持久化 frecency。
可通过来源接口扩展；这些差异意味着目前不是完整个人 Blink 配置的直接替换。
匹配支持忽略 ASCII 大小写的前缀、子序列和驼峰边界加分，不提供拼写纠错或 Unicode 大小写折叠。

## 开发与验证

~~~sh
./tests/run.sh
REAL_LSP=1 ./tests/run.sh                 # 额外运行本机 lua-language-server
LUASNIP_PATH=/path/to/LuaSnip ./tests/run.sh
NVIM=/path/to/nvim-0.11/bin/nvim ./tests/run.sh
stylua --check lua tests

BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
./tests/bench.sh bench_menu              # 三列、高亮及原生 Lua query 的热渲染
BENCH_SOURCE=buffer BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
~~~

测试只需要 Neovim 和 Python 3。包括独立嵌入式 Neovim 的实际按键、附着 UI、
标准库实现的 stdio LSP fixture，以及真实 PTY 输入测试。
性能对照需要已编译 Rust 后端的 blink.cmp，不会自动下载或构建。

MIT License.
