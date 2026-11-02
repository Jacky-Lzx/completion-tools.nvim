local blink_path = vim.env.BLINK_CMP_PATH or (vim.fn.stdpath("data") .. "/lazy/blink.cmp")
assert(vim.fn.isdirectory(blink_path) == 1, "Set BLINK_CMP_PATH to a blink.cmp checkout")
local results = {
  benchmark = "attached UI; real input to completed menu render; 160 samples; 50 final candidates",
  neovim = tostring(vim.version()),
  cases = {},
  source = vim.env.BENCH_SOURCE or "static",
}
for _, size in ipairs({ 1000, 10000, 20000 }) do
  for _, engine in ipairs({ "completion_tools", "blink" }) do
    local child = vim.fn.jobstart(
      { vim.v.progpath, "--embed", "-u", "tests/minimal_init.lua", "-i", "NONE", "-n" },
      { rpc = true }
    )
    local function rpc(method, ...)
      return vim.rpcrequest(child, method, ...)
    end
    local function lua(code, ...)
      return rpc("nvim_exec_lua", code, { ... })
    end
    local function input(keys)
      rpc("nvim_input", keys)
    end
    local function wait(code)
      assert(
        vim.wait(3000, function()
          return lua(code)
        end, 1),
        code
      )
    end
    local succeeded, err = xpcall(function()
      rpc("nvim_ui_attach", 120, 36, { rgb = true })
      lua(
        [[
        local engine, size, blink_path, source = ...
        bench = { samples = {}, done = false, candidate_min=math.huge, candidate_max=0 }
        local function count_candidates(lists)
          if not bench.recording then return end
          local count=0
          for _,list in pairs(lists) do count=count+#(list.items or list) end
          bench.candidate_min=math.min(bench.candidate_min,count)
          bench.candidate_max=math.max(bench.candidate_max,count)
        end
        bench.count_candidates=count_candidates
        local items, names = {}, {"completeBufferName", "computeMemberValue", "compareResult", "configurationOption"}
        for i=1,size do items[i] = {label=names[(i-1)%#names+1]..string.format("%05d",i),kind=6} end
        if source == "buffer" then
          local lines = vim.tbl_map(function(item) return item.label end, items)
          lines[#lines+1] = ""
          vim.api.nvim_buf_set_lines(0,0,-1,false,lines)
          vim.api.nvim_win_set_cursor(0,{#lines,0})
        end
        if engine == "completion_tools" then
          require("completion_tools").setup({sources={source=="buffer" and "buffer" or "bench"},keymap={},documentation={auto_show=false},
            menu={columns={{"label"},{"source"}},label_details=false,highlight={enabled=false}},
            providers={bench={complete=function(_,cb) cb({items=items,reusable=true}) end}}})
          local ui = require("completion_tools.ui")
          local matcher = require("completion_tools.matcher")
          local filter = matcher.filter
          matcher.filter=function(groups,ctx,limit) count_candidates(groups); return filter(groups,ctx,limit) end
          local original = ui.render
          ui.render = function(list, selected, ctx, config)
            original(list, selected, ctx, config)
            if bench.started and ctx.line == bench.expected and #list>0 and ui.visible() and not bench.done then
              bench.elapsed=(vim.uv.hrtime()-bench.started)/1e6; bench.done=true
            end
          end
        else
          vim.opt.runtimepath:append(blink_path)
          package.preload["completion_bench_source"] = function()
            return {new=function() return {get_completions=function(_,_,cb)
              cb({items=items,is_incomplete_forward=false,is_incomplete_backward=false})
            end} end}
          end
          require("blink.cmp").setup({keymap={preset="none"},sources={default={source=="buffer" and "buffer" or "bench"},
            providers={bench={name="bench",module="completion_bench_source"},
              buffer={opts={get_bufnrs=function() return {vim.api.nvim_get_current_buf()} end,
                max_async_buffer_size=1048576,max_total_buffer_size=2097152}}}},
            fuzzy={implementation="rust",max_typos=0,use_proximity=false,frecency={enabled=false},sorts={"score","sort_text"}},
            completion={list={max_items=50},menu={max_height=12,border="single",
              draw={columns={{"label"},{"source_name"}}}},documentation={auto_show=false}},
            signature={enabled=false},cmdline={enabled=false}})
        end
      ]],
        engine,
        size,
        blink_path,
        results.source
      )
      if engine == "blink" then
        wait("return package.loaded['blink.cmp.completion'] ~= nil")
        lua([[
          local menu = require("blink.cmp.completion.windows.menu")
          local fuzzy=require("blink.cmp.fuzzy")
          local filter=fuzzy.fuzzy
          fuzzy.fuzzy=function(line,col,groups,range) bench.count_candidates(groups); return filter(line,col,groups,range) end
          local original = menu.open_with_items
          menu.open_with_items = function(ctx, items)
            original(ctx, items)
            if bench.started and ctx.line == bench.expected and #items>0 and menu.win:is_open() and not bench.done then
              bench.elapsed=(vim.uv.hrtime()-bench.started)/1e6; bench.done=true
            end
          end
        ]])
      end
      input("i")
      wait("return vim.api.nvim_get_mode().mode == 'i'")
      for round = 1, 45 do
        lua("bench.recording=false")
        if round > 1 then
          input("<C-u>")
          wait("return vim.api.nvim_get_current_line() == ''")
        end
        local prefix = ""
        for _, char in ipairs({ "c", "o", "m", "p" }) do
          prefix = prefix .. char
          lua(
            "bench.started=vim.uv.hrtime(); bench.expected,bench.recording=...; bench.done=false",
            prefix,
            round > 5
          )
          input(char)
          wait("return bench.done")
          if round > 5 then
            lua("bench.samples[#bench.samples+1]=bench.elapsed")
          end
        end
      end
      local stats = lua([[
        table.sort(bench.samples)
        return {p50_ms=bench.samples[math.ceil(#bench.samples*.5)],p95_ms=bench.samples[math.ceil(#bench.samples*.95)],samples=#bench.samples,
          candidate_min=bench.candidate_min,candidate_max=bench.candidate_max}
      ]])
      assert(
        stats.candidate_min >= size,
        "A source returned fewer candidates than the benchmark corpus: "
          .. vim.inspect({ engine = engine, size = size, stats = stats })
      )
      results.cases[#results.cases + 1] = { items = size, engine = engine, stats = stats }
      print(vim.json.encode(results.cases[#results.cases]))
    end, debug.traceback)
    pcall(rpc, "nvim_command", "qa!")
    vim.fn.jobwait({ child }, 1000)
    if not succeeded then
      error(err)
    end
  end
end
if vim.env.BENCH_OUTPUT then
  vim.fn.writefile({ vim.json.encode(results) }, vim.env.BENCH_OUTPUT)
end
