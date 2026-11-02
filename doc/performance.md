# 性能记录

记录日期：2026-11-02；环境：macOS arm64，Neovim 0.12.6 / LuaJIT。
对照使用本机已安装的 blink.cmp v1.10.2（78336bc89ee5365633bcf754d93df01678b5c08f），Rust 后端已成功加载，未重新编译。
本机原生库 SHA-256：`ceeae0c3f72af97ee64b816256638883a67396430445829e2afc938246a36945`。

这些结果说明此实现在所测工作负载上达到了与 Blink 相近或更低的交互延迟。它不等价于完整功能、完整个人配置或所有设备上的性能对等。

[交互图表](benchmarks/report.html) · [固定候选原始数据](benchmarks/static-input.json) · [缓冲区原始数据](benchmarks/buffer-input.json) · [匹配原始数据](benchmarks/matcher.json)

## 输入到菜单更新

单位均为毫秒。每个插件、每个候选规模使用独立 Neovim 进程并附着 120×36 UI，通过实际 `nvim_input` 输入 `c → co → com → comp`，每轮清除前缀。先预热 5 轮，再记录 40 轮共 160 次输入。时间从子进程内的 RPC 注入前时间戳开始，到菜单渲染函数完成时结束，包含注入与编辑器调度开销，不包含终端像素绘制或父进程轮询时间。

两者均保留 50 个最终候选，菜单高度 12，single 边框，显示 label 和来源；关闭自动文档。Blink 使用 Rust、max_typos=0，关闭 frecency 和 proximity。没有使用个人配置的 Treesitter 菜单、AI 来源或其他渲染扩展。两者匹配评分不同；相同输入不保证相同排序。

候选由四组不同前缀的标识符和唯一编号组成，生成规则见 [bench_input.lua](../tests/bench_input.lua)。采样过程中断言匹配器实际收到至少指定数量的候选，避免把缓冲区裁剪或索引尚未完成当作加速。

### 固定候选来源

来源立即返回同一批候选，支持完整列表的前向复用。该场景包含请求调度、筛选、排序和菜单更新，排除了文件系统及语言服务器耗时。

| 候选数 | completion-tools p50 | p95 | Blink Rust p50 | p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.384 | 0.482 | 0.647 | 2.121 |
| 10,000 | 0.641 | 0.705 | 1.643 | 6.975 |
| 20,000 | 0.994 | 1.096 | 3.003 | 13.358 |

### 缓冲区单词来源

相同标识符按每行一个写入当前缓冲区，在文件末尾持续编辑前缀。双方只读取当前缓冲区，均允许至少 1 MiB 文件和完整语料；Blink 的 max_async_buffer_size 显式调到 1 MiB，以免默认大小限制跳过大样本。completion-tools 的词数预算为 20,000。初次索引预热后再计入统计；小样本可能另含正在键入的一个词，原始数据记录了实际候选上下界。

| 候选数 | completion-tools p50 | p95 | Blink Rust p50 | p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.397 | 0.549 | 0.666 | 2.714 |
| 10,000 | 0.777 | 0.861 | 1.749 | 12.960 |
| 20,000 | 1.182 | 1.294 | 3.418 | 26.072 |

### 结果边界

- 这是当前机器上的单次受控记录，系统负载、JIT、GC 和调度会影响尤其是 p95；不是稳定倍数保证。
- 首次模块加载、冷索引、首次目录读取和 LSP 往返没有计入上述热输入统计。
- completion-tools 的初次索引按批调度，未完成前不发布部分单词列表。连续普通输入不会重启全量扫描；有独立回归测试。
- 命令行使用同步 getcompletion，不属于这些低延迟数据的覆盖范围。
- 实际个人 Blink 配置中的其他来源、文档、ghost text、自动括号和匹配纠错未做功能等价对照。

## 匹配微基准

每个规模先预热，再记录 240 次调用，轮换 `c`、`co`、`com`、`comp`、`cmp`、`cBN` 六种查询。不包含来源和 UI。completion-tools 返回 top 50；Blink 原生 fuzzy API 返回全部排序匹配项。因此这张表比较的是各自插件所使用的处理路径，不能解释为等价算法或等量输出的纯吞吐比较。本实现支持 ASCII 忽略大小写、子序列和驼峰边界加分；没有拼写纠错、Unicode 大小写折叠或 frecency。

| 候选数 | completion-tools p50 | p95 | Blink Rust p50 | p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.060 | 0.105 | 0.107 | 0.118 |
| 10,000 | 0.358 | 0.554 | 1.060 | 1.163 |
| 20,000 | 0.701 | 1.088 | 2.195 | 2.355 |

## 复现

```sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
BENCH_SOURCE=buffer BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
```

可设置 `BENCH_OUTPUT=/path/to/results.json` 保存原始结果，设置 `NVIM=/path/to/nvim` 选择可执行文件。测试不会下载、构建或修改 Blink。为减少争用，按顺序运行三个基准。

## 正确性验证

本地分别在 Neovim 0.11.5 与 0.12.6 运行单元、附着 UI 的真实输入、stdio LSP 协议和真实 PTY 测试；另验证本机 lua-language-server 及 LuaSnip。测试覆盖过期响应、连续输入、索引饥饿、缓存失效、选择保留、按键回退、UTF-16 范围替换、额外导入、resolve、snippet 跳转和命令行接受。CI 配置为 Linux 上的两个 Neovim 版本；本次未远程运行 CI。
