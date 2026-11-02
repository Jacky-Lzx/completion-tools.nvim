-- Drive a separate Neovim through its actual input/event loop and an attached UI.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "-u", "tests/minimal_init.lua", "-i", "NONE", "-n" },
  { rpc = true }
)
assert(child > 0)
local function rpc(method, ...)
  return vim.rpcrequest(child, method, ...)
end
local function lua(code, ...)
  return rpc("nvim_exec_lua", code, { ... })
end
local function wait(code, message, timeout)
  local done = vim.wait(timeout or 1500, function()
    return lua(code) == true
  end, 5)
  assert(
    done,
    (message or code)
      .. "\n"
      .. vim.inspect(
        lua(
          "return {line=vim.api.nvim_get_current_line(),mode=vim.api.nvim_get_mode().mode,err=vim.v.errmsg,trace=fixture_trace,context=package.loaded.completion_tools and require('completion_tools').get_context()}"
        )
      )
  )
end
local function input(keys)
  vim.rpcnotify(child, "nvim_input", keys)
end
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local passed = 0
local function test(name, run)
  input("<Esc><Esc>")
  wait("return vim.api.nvim_get_mode().mode == 'n'", "normal mode")
  lua(
    "if package.loaded.completion_tools then require('completion_tools').dispose() end; for _,c in ipairs(vim.lsp.get_clients()) do c:stop(true) end; vim.cmd('enew!'); vim.bo.filetype = 'lua'; test_notifications={}"
  )
  local ok, err = xpcall(run, debug.traceback)
  if not ok then
    error(name .. ": " .. err)
  end
  local errors = lua(
    "return vim.tbl_filter(function(n) return n.level and n.level>=vim.log.levels.ERROR end,test_notifications)"
  )
  assert(#errors == 0, name .. ": " .. vim.inspect(errors))
  passed = passed + 1
  print("input: " .. name)
end
local ok, err = xpcall(function()
  rpc("nvim_ui_attach", 120, 36, { rgb = true })
  lua(
    "test_notifications={}; vim.notify=function(message,level) test_notifications[#test_notifications+1]={message=message,level=level} end"
  )
  test("buffer auto-completion, selection, accept and following input", function()
    lua(
      [[vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'alpha alphabet alphanumeric', '' }); vim.api.nvim_win_set_cursor(0, {2, 0}); require('completion_tools').setup({ sources = {'buffer'} })]]
    )
    input("ial")
    wait("return require('completion_tools').is_menu_visible()")
    eq("alpha", lua("return require('completion_tools').get_selected_item().label"))
    input("<C-n><Tab>!")
    wait("return vim.api.nvim_get_current_line() == 'alphabet!'")
    eq("i", lua("return vim.api.nvim_get_mode().mode"))
  end)
  test("fast typing never accepts an out-of-date candidate", function()
    lua(
      [[require('completion_tools').setup({ sources = {'slow'}, providers = { slow = { complete = function(ctx, cb) vim.defer_fn(function() cb({ items = {{label = ctx.prefix .. 'Suffix'}} }) end, ctx.prefix == 'a' and 80 or 15) end } } })]]
    )
    input("ia")
    vim.wait(10)
    input("bc")
    wait(
      "local c = require('completion_tools'); return c.is_menu_visible() and c.get_selected_item().label == 'abcSuffix'"
    )
    vim.wait(100)
    eq("abcSuffix", lua("return require('completion_tools').get_selected_item().label"))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line() == 'abcSuffix!'")
  end)
  test("leaving insert cancels pending results", function()
    lua(
      [[require('completion_tools').setup({ sources = {'slow'}, providers = { slow = { complete = function(ctx, cb) vim.defer_fn(function() cb({items = {{label = 'abandoned'}}}) end, 70) end } } })]]
    )
    input("ia<Esc>")
    vim.wait(100)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
  end)
  test("streaming updates preserve an explicit selection across new item objects", function()
    lua([[require('completion_tools').setup({sources={'stream'},providers={stream={complete=function(ctx,cb)
      cb({items={{label='apple'},{label='apply'}}})
      vim.defer_fn(function() cb({items={{label='apple'},{label='apply'},{label='apt'}}}) end,80)
    end}}})]])
    input("iap")
    wait("return require('completion_tools').is_menu_visible()")
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label=='apply'")
    vim.wait(100)
    eq("apply", lua("return require('completion_tools').get_selected_item().label"))
  end)
  test("pending replacement retains the ready frame and rejects stale acceptance", function()
    lua([[require('completion_tools').setup({sources={'slow'},providers={slow={complete=function(ctx,cb)
      vim.defer_fn(function() cb({items={{label=ctx.prefix..'Result'}}}) end,ctx.prefix=='a' and 5 or 100)
    end}}})]])
    input("ia")
    wait("return require('completion_tools').is_menu_visible()")
    input("l")
    wait("return vim.api.nvim_get_current_line() == 'al'")
    assert(lua("local c=require('completion_tools'); return c.is_menu_visible() and not c.accept()"))
    wait(
      "local c=require('completion_tools'); return c.get_selected_item() and c.get_selected_item().label == 'alResult'"
    )
  end)
  test("custom actions and non-expr fallback execute outside textlock", function()
    lua(
      [[vim.keymap.set('i','<CR>',function() vim.api.nvim_set_current_line(vim.api.nvim_get_current_line()..'!') end)
      require('completion_tools').setup({sources={},keymap={
        ['<CR>']={'accept','fallback'},
        ['<F5>']={function(c) vim.api.nvim_set_current_line('custom'); return true end}
      }})]]
    )
    input("iabc<CR>")
    wait("return vim.api.nvim_get_current_line() == 'abc!'")
    input("<F5>")
    wait("return vim.api.nvim_get_current_line() == 'custom'")
    lua("require('completion_tools').dispose(); vim.keymap.del('i','<CR>')")
  end)
  test("manual completion, cancel and fallback Tab", function()
    lua(
      [[require('completion_tools').setup({ sources = {'buffer'}, auto_show = false }); vim.api.nvim_buf_set_lines(0, 0, -1, false, {'alpha', ''}); vim.api.nvim_win_set_cursor(0, {2,0})]]
    )
    input("ial")
    vim.wait(30)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    input("<C-Space>")
    wait("return require('completion_tools').is_menu_visible()")
    input("<C-e><Tab>")
    wait("return vim.api.nvim_get_current_line():find('\\t', 1, true) ~= nil")
  end)
  test("UTF-16 InsertReplaceEdit and imports", function()
    lua(
      [[require('completion_tools').setup({ sources = {'test'}, providers = { test = { complete = function(ctx, cb) cb({ items = {{ label = 'foobar', _encoding = 'utf-16', textEdit = { newText = 'foobar', insert = {start={line=1,character=2}, ['end']={line=1,character=4}}, replace = {start={line=1,character=2}, ['end']={line=1,character=8}} }, additionalTextEdits = {{ range={start={line=0,character=0}, ['end']={line=0,character=0}}, newText='import thing\n' }} }} }) end } } }); vim.api.nvim_buf_set_lines(0,0,-1,false,{'header','😀foTAIL'}); vim.api.nvim_win_set_cursor(0,{2,6})]]
    )
    input("i")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line() == '😀foobar!'")
    eq({ "import thing", "header", "😀foobar!" }, lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)"))
  end)
  test("complete lists reused across typing rebase original edit range", function()
    lua(
      [[calls=0; require('completion_tools').setup({ sources = {'test'}, providers={ test={ complete=function(ctx,cb) calls=calls+1; cb({reusable=true,items={{label='foobar',_encoding='utf-16',textEdit={newText='foobar',range={start={line=0,character=2},['end']={line=0,character=3}}}}}}) end } } }); vim.api.nvim_buf_set_lines(0,0,-1,false,{'😀'}); vim.api.nvim_win_set_cursor(0,{1,4})]]
    )
    input("Af")
    wait("return require('completion_tools').is_menu_visible()")
    local calls = lua("return calls")
    input("oo")
    wait(
      "local c=require('completion_tools'); return c.get_context() and c.get_context().before == '😀foo' and c._can('accept')"
    )
    eq(calls, lua("return calls"))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line() == '😀foobar!'")
  end)
  test("cached imports and suffix edits rebase and preserve the insertion cursor", function()
    lua([[require('completion_tools').setup({sources={'test'},providers={test={complete=function(ctx,cb)
      cb({reusable=true,items={{label='foobar',textEdit={newText='foobar',range={start={line=0,character=0},['end']={line=0,character=1}}},
        additionalTextEdits={
          {range={start={line=0,character=0},['end']={line=0,character=0}},newText='import thing\n'},
          {range={start={line=0,character=1},['end']={line=0,character=1}},newText='TAIL'}
        }}}})
    end}}}); vim.api.nvim_buf_set_lines(0,0,-1,false,{'f'})]])
    input("A")
    wait("return require('completion_tools').is_menu_visible()")
    input("oo")
    wait(
      "local c=require('completion_tools'); return c.get_context() and c.get_context().prefix=='foo' and c._can('accept')"
    )
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line() == 'foobar!TAIL'")
    eq({ "import thing", "foobar!TAIL" }, lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)"))
    input("<Esc>u")
    wait(
      "return vim.api.nvim_buf_line_count(0)==1 and not vim.api.nvim_get_current_line():find('TAIL',1,true)"
    )
  end)
  test("snippets with an import at the same starting position", function()
    lua([[require('completion_tools').setup({sources={'test'},providers={test={complete=function(ctx,cb)
      cb({items={{label='snippet',insertTextFormat=2,textEdit={newText='say(${1:name})$0',range={start={line=0,character=0},['end']={line=0,character=2}}},
        additionalTextEdits={{range={start={line=0,character=0},['end']={line=0,character=0}},newText='import thing\n'}}}}})
    end}}}); vim.api.nvim_buf_set_lines(0,0,-1,false,{'sn'})]])
    input("A")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.api.nvim_get_mode().mode == 's'")
    input("value")
    wait("return vim.api.nvim_get_current_line() == 'say(value)'")
    eq({ "import thing", "say(value)" }, lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)"))
    input("<Tab>")
    wait("return vim.api.nvim_get_mode().mode == 'i'")
  end)
  test("snippet expansion and jumping", function()
    lua(
      [[require('completion_tools').setup({sources={'snippets'},snippets={collection={lua={{prefix='fn',body='function ${1:name}(${2:args})\n\t$0\nend'}}}}})]]
    )
    input("ifn")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.snippet.active()")
    assert(lua("return vim.api.nvim_get_current_line():match('function name') ~= nil"))
    wait("return vim.api.nvim_get_mode().mode == 's'")
    input("demo<Tab>")
    wait(
      "return vim.api.nvim_get_mode().mode == 's' and vim.api.nvim_get_current_line():find('demo',1,true) ~= nil"
    )
    input("value<Tab>")
    wait("return vim.api.nvim_get_mode().mode == 'i'")
    input("body")
    wait(
      "return table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),'\\n'):find('function demo(value)',1,true) ~= nil"
    )
  end)
  test("edits outside the completion row invalidate reusable lists", function()
    lua(
      [[calls=0; require('completion_tools').setup({sources={'test'},providers={test={complete=function(ctx,cb)
      calls=calls+1; cb({reusable=true,items={{label='foobar'}}})
    end}}}); vim.api.nvim_buf_set_lines(0,0,-1,false,{'header',''}); vim.api.nvim_win_set_cursor(0,{2,0})]]
    )
    input("if")
    wait("return require('completion_tools').is_menu_visible()")
    local calls = lua("return calls")
    lua("vim.api.nvim_buf_set_lines(0,0,1,false,{'different context'})")
    input("o")
    wait(
      "local c=require('completion_tools'); return c.get_context() and c.get_context().prefix=='fo' and c._can('accept')"
    )
    assert(lua("return calls") > calls)
  end)
  test("documentation rendering, navigation and close", function()
    lua(
      [[require('completion_tools').setup({ sources={'test'}, documentation={delay_ms=10}, providers={test={complete=function(ctx,cb) cb({items={{label='alpha',detail='function alpha()\n  return 1\nend',documentation={kind='markdown',value='Some **documentation**'}},{label='alpine'}}}) end}}})]]
    )
    input("ial")
    wait(
      "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'markdown' then return true end end; return false"
    )
    assert(lua("return require('completion_tools').scroll_documentation_down()"))
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label == 'alpine'")
    input("<C-e>")
    wait("return #vim.api.nvim_list_wins() == 1")
  end)
  local function start_fixture(extra)
    lua(
      [[
      local extra = ...
      fixture_trace = fixture_trace or {}
      local cmp = require("completion_tools")
      fixture_id = vim.lsp.start({name=extra or "completion-fixture",cmd={vim.fn.exepath("python3"),
        vim.fn.getcwd().."/tests/fixtures/lsp_server.py"},root_dir=vim.fn.getcwd(),
        capabilities=cmp.get_lsp_capabilities(),init_options={extra_label=extra},
        on_exit=function(code,signal) fixture_trace[#fixture_trace+1]={kind='exit',code=code,signal=signal} end,
        handlers={["completionFixture/trace"]=function(_,data) fixture_trace[#fixture_trace+1]=data end}})
    ]],
      extra
    )
    wait(
      "local c=vim.lsp.get_client_by_id(fixture_id); return c and c.initialized and vim.lsp.buf_is_attached(0,fixture_id)",
      "fixture initialize",
      5000
    )
  end
  test("LSP protocol: trigger, UTF-16 defaults, cached ranges and late imports/command", function()
    lua([[fixture_trace={}; require("completion_tools").setup({sources={"lsp"}});
      vim.api.nvim_buf_set_lines(0,0,-1,false,{"header","😀."}); vim.api.nvim_win_set_cursor(0,{2,4})]])
    start_fixture()
    input("A")
    wait("return require('completion_tools').is_menu_visible()")
    assert(
      lua(
        "for _,e in ipairs(fixture_trace) do if e.kind=='completion' and e.triggerKind==2 and e.triggerCharacter=='.' then return true end end; return false"
      )
    )
    input("fo")
    wait(
      "local c=require('completion_tools'); return c.get_context() and c.get_context().before=='😀.fo' and c._can('accept')"
    )
    input("<Tab>")
    wait("return vim.api.nvim_get_current_line() == '😀.foobar'")
    wait("return vim.api.nvim_buf_get_lines(0,0,1,false)[1] == 'import fixture'")
    wait("for _,e in ipairs(fixture_trace) do if e.kind=='execute' then return true end end; return false")
    eq({ "import fixture", "header", "😀.foobar" }, lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)"))
    assert(lua("for _,e in ipairs(fixture_trace) do if e.kind=='capabilities' then return e.snippet end end"))
  end)
  test("LSP protocol: incomplete lists retrigger with kind 3", function()
    lua([[fixture_trace={}; require("completion_tools").setup({sources={"lsp"}})]])
    start_fixture()
    input("iinc")
    wait("return require('completion_tools').is_menu_visible()")
    input("o")
    wait(
      "for _,e in ipairs(fixture_trace) do if e.kind=='completion' and e.prefix=='inco' and e.triggerKind==3 then return true end end; return false"
    )
  end)
  test("LSP protocol: Unicode trigger characters", function()
    lua([[fixture_trace={}; require("completion_tools").setup({sources={"lsp"}})]])
    start_fixture()
    input("iλ")
    wait(
      "for _,e in ipairs(fixture_trace) do if e.kind=='completion' and e.triggerKind==2 and e.triggerCharacter=='λ' then return true end end; return false"
    )
  end)
  test("LSP protocol: merge multiple clients", function()
    lua([[fixture_trace={}; require("completion_tools").setup({sources={"lsp"}})]])
    start_fixture()
    start_fixture("functionFromSecond")
    input("if")
    wait(
      "local labels={}; for _,item in ipairs(require('completion_tools').get_items()) do labels[item.label]=true end; return labels.foobar and labels.forest and labels.functionFromSecond"
    )
  end)
  test("LSP protocol: delayed resolve cannot edit newly typed text", function()
    lua([[fixture_trace={}; require("completion_tools").setup({sources={"lsp"}})]])
    start_fixture()
    input("ifo")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line() == 'foobar!'")
    vim.wait(150)
    eq({ "foobar!" }, lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)"))
    assert(
      lua("for _,e in ipairs(fixture_trace) do if e.kind=='execute' then return false end end; return true")
    )
  end)
  if vim.env.REAL_LSP == "1" then
    test("real lua-language-server: member completion and accept", function()
      lua([[
        require("completion_tools").setup({sources={"lsp"}})
        vim.api.nvim_buf_set_lines(0,0,-1,false,{"local example = { apple = 1, apply = function() end }",""})
        vim.api.nvim_buf_set_name(0,vim.fn.getcwd().."/tests/fixtures/member.lua")
        vim.api.nvim_win_set_cursor(0,{2,0})
        real_id=vim.lsp.start({name="completion-real-luals",cmd={vim.fn.exepath("lua-language-server")},
          root_dir=vim.fn.getcwd(),capabilities=require("completion_tools").get_lsp_capabilities(),
          settings={Lua={runtime={version="LuaJIT"},workspace={checkThirdParty=false},telemetry={enable=false}}},
          handlers={["textDocument/publishDiagnostics"]=function(_,result) real_diagnostics=true end}})
      ]])
      wait("local c=vim.lsp.get_client_by_id(real_id); return c and c.initialized", "LuaLS initialize", 10000)
      wait("return real_diagnostics == true", "LuaLS initial analysis", 10000)
      input("iexample.")
      wait(
        "for _,item in ipairs(require('completion_tools').get_items()) do if item.label=='apple' then return true end end; return false",
        "LuaLS member completion",
        10000
      )
      lua(
        "local c=require('completion_tools'); for _=1,#c.get_items() do if c.get_selected_item().label=='apple' then break end; c.select_next() end"
      )
      input("<Tab>!")
      wait("return vim.api.nvim_get_current_line() == 'example.apple!'")
    end)
  end
  if vim.env.LUASNIP_PATH then
    test("optional LuaSnip source, expansion and jump", function()
      lua(
        [[
        vim.opt.runtimepath:append(...)
        local ls = require("luasnip")
        ls.config.setup({})
        ls.add_snippets("lua",{ls.snippet("hello",{ls.text_node("hello "),ls.insert_node(1,"world"),ls.text_node("!")})})
        require("completion-tools").setup({sources={"snippets"},snippets={preset="luasnip"}})
      ]],
        vim.env.LUASNIP_PATH
      )
      input("ihe")
      wait("return require('completion-tools').is_menu_visible()")
      input("<Tab>")
      wait("return vim.api.nvim_get_mode().mode == 's' and vim.api.nvim_get_current_line()=='hello world!'")
      input("user")
      wait("return vim.api.nvim_get_current_line()=='hello user!'")
      input("<Tab>")
      wait("return vim.api.nvim_get_mode().mode == 'i'")
    end)
  end
  test("command-line Tab accepts without executing", function()
    lua([[require('completion_tools').setup({cmdline={enabled=true}})]])
    input(":set nu")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.fn.getcmdline() == 'set number'")
    eq("c", lua("return vim.api.nvim_get_mode().mode"))
    input("<Esc>")
  end)
end, debug.traceback)
pcall(rpc, "nvim_command", "qa!")
vim.fn.jobwait({ child }, 1000)
if not ok then
  error(err)
end
print(string.format("integration: %d passed (attached UI, actual nvim_input)", passed))
