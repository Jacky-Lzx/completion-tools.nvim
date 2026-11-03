# Performance measurements

Recorded on 2026-11-02: macOS arm64, Neovim 0.12.6 / LuaJIT.
The comparison used the locally installed blink.cmp v1.10.2
(`78336bc89ee5365633bcf754d93df01678b5c08f`) with its Rust backend loaded, without rebuilding.
Native library SHA-256: `ceeae0c3f72af97ee64b816256638883a67396430445829e2afc938246a36945`.

These workloads show comparable or lower interaction latency than Blink on this
machine. They do not establish feature parity or equivalent performance across
complete personal configurations, language servers or devices.

[Interactive chart](benchmarks/report.html) · [Static input data](benchmarks/static-input.json) · [Buffer input data](benchmarks/buffer-input.json) · [Matcher data](benchmarks/matcher.json)

## Input to menu update

All values are milliseconds. Each engine and candidate count uses a separate
Neovim process with an attached 120×36 UI. Actual `nvim_input` calls type
`c → co → com → comp`, clearing the prefix between rounds. Five warmup rounds
precede 40 measured rounds, giving 160 inputs. Timing begins inside the child
process before RPC input injection and ends when menu rendering completes.
It includes injection and editor scheduling, but excludes terminal pixel drawing
and parent-process polling.

Both engines retain 50 candidates, use a 12-row menu with a single border, show
labels and sources, and disable automatic documentation. Blink uses Rust with
`max_typos=0`, frecency and proximity disabled. Neither uses personal Tree-sitter
menu customizations, AI sources or other rendering extensions. Match scores differ,
so identical input need not produce identical ordering.

Candidates consist of identifiers from four prefix groups with unique numeric
suffixes; see [bench_input.lua](../tests/bench_input.lua). Sampling asserts that
the matcher receives at least the requested candidate count, preventing buffer
truncation or incomplete indexing from appearing as a speedup.

### Static provider

The provider immediately returns the same candidate list and supports forward
reuse of complete lists. This includes scheduling, filtering, ranking and menu
updates, while excluding filesystem and language-server latency.

| Candidates | completion-tools p50 | p95 | Blink Rust p50 | p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.384 | 0.482 | 0.647 | 2.121 |
| 10,000 | 0.641 | 0.705 | 1.643 | 6.975 |
| 20,000 | 0.994 | 1.096 | 3.003 | 13.358 |

### Buffer words

The same identifiers are written one per line in the current buffer, with prefixes
edited at the end. Both engines read only that buffer and allow at least 1 MiB and
the full corpus. Blink's `max_async_buffer_size` is explicitly raised to 1 MiB to
avoid skipping larger samples. completion-tools allows 20,000 words. Initial
indexing is warmed up before measurement. Smaller samples may also contain the
word being typed; raw data records actual candidate bounds.

| Candidates | completion-tools p50 | p95 | Blink Rust p50 | p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.397 | 0.549 | 0.666 | 2.714 |
| 10,000 | 0.777 | 0.861 | 1.749 | 12.960 |
| 20,000 | 1.182 | 1.294 | 3.418 | 26.072 |

### Limits

- This is one controlled run on one machine. Load, JIT, GC and scheduling affect
  results, especially p95; no fixed speedup is guaranteed.
- Warm-input timings exclude initial module loading, cold indexes, first directory
  reads and LSP round trips.
- Initial buffer indexing is batched and publishes no partial word list. Continuous
  ordinary typing does not restart a full scan; a separate regression test covers it.
- Command-line completion uses synchronous `getcompletion()` and is outside these measurements.
- Other sources, documentation, ghost text, automatic brackets and typo correction
  in the personal Blink setup were not compared with equivalent functionality.

## Matcher microbenchmark

After warmup at each size, 240 calls rotate through `c`, `co`, `com`, `comp`, `cmp`
and `cBN`. Sources and UI are excluded. completion-tools returns the top 50;
Blink's native fuzzy API returns all sorted matches. This compares each plugin's
processing path, rather than equivalent algorithms or equal-output throughput.
The measured Lua matcher used ASCII-insensitive matching, subsequences and
camel-case boundary bonuses, without typo correction, Unicode case folding or
frecency. Optional history, proximity and one-typo ranking were added after this
recorded run and are disabled by default; these numbers do not measure them.

| Candidates | completion-tools p50 | p95 | Blink Rust p50 | p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.060 | 0.105 | 0.107 | 0.118 |
| 10,000 | 0.358 | 0.554 | 1.060 | 1.163 |
| 20,000 | 0.701 | 1.088 | 2.195 | 2.355 |

## Reproduce

```sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh
BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
BENCH_SOURCE=buffer BLINK_CMP_PATH=/path/to/blink.cmp ./tests/bench.sh bench_input
```

Set `BENCH_OUTPUT=/path/to/results.json` to save results and `NVIM=/path/to/nvim`
to select the executable. Tests do not download, build or modify Blink. Run the
three benchmarks sequentially to reduce contention.

## Correctness validation

The original local validation ran unit tests, attached-UI input tests, stdio LSP
protocol tests and real PTY tests on Neovim 0.11.5 and 0.12.6, plus local
lua-language-server and LuaSnip checks. Coverage includes stale responses,
continuous typing, index starvation, cache invalidation, selection preservation,
keymap fallback, UTF-16 replacement, additional imports, resolve, snippet jumping
and command-line acceptance. CI targets both Neovim versions on Linux; remote CI
was not run for the recorded measurements.
