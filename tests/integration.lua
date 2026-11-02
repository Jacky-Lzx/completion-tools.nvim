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
  test("kind columns and independent syntax highlights survive colorscheme and acceptance", function()
    lua([[
      package.preload['colorful-menu']=function() error('unexpected colorful-menu dependency') end
      require('completion_tools').setup({sources={'test'},documentation={auto_show=false},
        menu={highlight={treesitter=false}},providers={test={complete=function(_,cb)
          cb({items={{label='decode',kind=3,labelDetails={detail='(value: string): number',description='中文模块'}}}})
        end}}})
    ]])
    input("ide")
    wait("return require('completion_tools').is_menu_visible()")
    lua([[
      local w
      for _,id in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(id)].filetype=='completion-tools-menu' then w=id end
      end
      local b=vim.api.nvim_win_get_buf(w)
      local line=vim.api.nvim_buf_get_lines(b,0,1,false)[1]
      assert(line:find('decode(value: string): number  中文模块',1,true),line)
      assert(line:find('Function',1,true),line)
      local seen={}
      for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(b,vim.api.nvim_create_namespace('completion-tools-menu'),0,-1,{details=true})) do
        seen[mark[4].hl_group]=true
      end
      for _,name in ipairs({'CompletionToolsKindFunction','CompletionToolsMatch','@type.builtin','@variable.parameter','CompletionToolsSource'}) do
        assert(seen[name],name..' missing')
      end
      vim.api.nvim_set_hl(0,'CompletionToolsKindFunction',{fg='#ef4545'})
      vim.api.nvim_exec_autocmds('ColorScheme',{})
      assert(vim.api.nvim_get_hl(0,{name='CompletionToolsKindFunction'}).fg==0xef4545,'overrode user highlight')
      vim.cmd.redraw()
      local p=vim.fn.screenpos(w,1,1)
      local screen=''
      for col=p.col,p.col+vim.api.nvim_win_get_width(w)-1 do screen=screen..vim.fn.screenstring(p.row,col) end
      assert(screen:find('decode(value: string): number',1,true),screen)
    ]])
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line() == 'decode!'")
  end)
  test("only visible menu rows are highlighted", function()
    lua([[
      visible_highlights={}
      local items={}; for i=1,50 do items[i]={label=string.format('alpha%02d',i)} end
      require('completion_tools').setup({sources={'test'},menu={max_height=2,highlight={custom=function(entry)
        visible_highlights[#visible_highlights+1]=entry.item.label
      end}},providers={test={complete=function(_,cb) cb({items=items}) end}}})
    ]])
    input("ial")
    wait("return require('completion_tools').is_menu_visible()")
    eq({ "alpha01", "alpha02" }, lua("return visible_highlights"))
    lua("visible_highlights={}; require('completion_tools').select_next({count=5})")
    eq({ "alpha05", "alpha06" }, lua("return visible_highlights"))
  end)
  test("entering insert and moving the cursor do not open automatic completion", function()
    lua(
      [[require('completion_tools').setup({sources={'test'},min_keyword_length=0,providers={test={
      complete=function(_,cb) cb({items={{label='alpha'}}}) end
    }}}); vim.api.nvim_buf_set_lines(0,0,-1,false,{'alpha','   '}); vim.api.nvim_win_set_cursor(0,{1,0})]]
    )
    input("A")
    wait("return vim.api.nvim_get_mode().mode=='i'")
    vim.wait(60)
    assert(
      not lua("return require('completion_tools').is_menu_visible()"),
      "InsertEnter opened completion without an edit"
    )
    lua("vim.api.nvim_exec_autocmds('LspAttach',{buffer=0,data={client_id=999999}})")
    vim.wait(60)
    assert(
      not lua("return require('completion_tools').is_menu_visible()"),
      "LspAttach opened completion before typing"
    )
    input("<Left>")
    vim.wait(60)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    input("<Esc>jA")
    wait("return vim.api.nvim_get_mode().mode=='i' and vim.api.nvim_win_get_cursor(0)[1]==2")
    input(" ")
    vim.wait(60)
    assert(
      not lua("return require('completion_tools').is_menu_visible()"),
      "Whitespace opened an unfiltered list"
    )
    input("<C-Space>")
    wait("return require('completion_tools').is_menu_visible()")
    input("<C-e>a")
    wait(
      "local c=require('completion_tools'); return c.get_context() and c.get_context().prefix=='a' and c.is_menu_visible()"
    )
    input("<BS>")
    wait("return not require('completion_tools').is_menu_visible()")
    vim.wait(60)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    lua([[require('completion_tools').register_source('test',{complete=function(_,cb)
      vim.defer_fn(function() cb({items={{label='alpha'}}}) end,70)
    end})]])
    input("a")
    vim.wait(10)
    input("<BS>")
    vim.wait(100)
    assert(
      not lua("return require('completion_tools').is_menu_visible()"),
      "Late results reopened an empty query"
    )
  end)
  test("upper menu and tall documentation leave the input screen row clear", function()
    lua(
      [[local items={};for i=1,25 do items[i]={label='alpha'..i,detail=string.rep('documentation\n',30)} end
      require('completion_tools').setup({sources={'test'},menu={max_height=4},documentation={delay_ms=5},
        providers={test={complete=function(_,cb) cb({items=items}) end}}})
      local lines={};for i=1,80 do lines[i]='' end
      vim.api.nvim_buf_set_lines(0,0,-1,false,lines);vim.api.nvim_win_set_cursor(0,{80,0});vim.cmd('normal! zb')]]
    )
    input("Aalpha")
    wait(
      "local c=require('completion_tools');return c.get_context() and c.get_context().prefix=='alpha' and c._can('accept')"
    )
    wait(
      "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then return true end end;return false"
    )
    lua([[vim.cmd.redraw()
      local ctx=require('completion_tools').get_context()
      local cursor=vim.fn.screenpos(ctx.winid,ctx.row+1,ctx.col+1)
      for _,win in ipairs(vim.api.nvim_list_wins()) do
        local ft=vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        if ft=='completion-tools-menu' or ft=='markdown' then
          local wc=vim.api.nvim_win_get_config(win)
          assert(wc.row+wc.height+1<cursor.row-1,ft..' overlaps the input row: '..vim.inspect({window=wc,cursor=cursor}))
        end
      end
      local start=vim.fn.screenpos(ctx.winid,ctx.row+1,1)
      local text='';for col=start.col,start.col+4 do text=text..vim.fn.screenstring(cursor.row,col) end
      assert(text=='alpha','input is obscured on the rendered screen: '..text)
    ]])
  end)
  test("wrapped keywords anchor the menu below the cursor screen row", function()
    lua([[long_word=string.rep('a',150); require('completion_tools').setup({sources={'test'},
      providers={test={complete=function(_,cb) cb({items={{label=long_word..'Suffix'}}}) end}}})
      vim.wo.wrap=true; vim.api.nvim_buf_set_lines(0,0,-1,false,{''})]])
    input("i" .. string.rep("a", 150))
    wait(
      "local c=require('completion_tools');return c.get_context() and #c.get_context().prefix==150 and c._can('accept')"
    )
    lua([[local ctx=require('completion_tools').get_context()
      local cursor=vim.fn.screenpos(ctx.winid,ctx.row+1,ctx.col+1)
      assert(cursor.row>vim.fn.screenpos(ctx.winid,ctx.row+1,1).row,'fixture must wrap')
      for _,win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='completion-tools-menu' then
          local wc=vim.api.nvim_win_get_config(win)
          assert(wc.row>cursor.row-1,'menu covers the wrapped cursor row')
        end
      end
    ]])
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
  test("refresh mappings after a lazy dependency installs its own mapping", function()
    lua([[require('completion_tools').setup({sources={'test'},providers={test={complete=function(_,cb)
      cb({items={{label='alpha'}}})
    end}},keymap={['<CR>']={'accept','fallback'}}})
      vim.keymap.set('i','<CR>',function() return '<CR>' end,{expr=true})
      assert(require('completion_tools').refresh_keymaps())]])
    input("ial")
    wait("return require('completion_tools').is_menu_visible()")
    input("<CR>!")
    wait("return vim.api.nvim_get_current_line()=='alpha!'")
    input("<CR>x")
    wait("return vim.api.nvim_buf_line_count(0)==2 and vim.api.nvim_get_current_line()=='x'")
    lua("require('completion_tools').dispose(); vim.keymap.del('i','<CR>')")
  end)
  test("custom actions preserve already encoded key sequences", function()
    lua([[require('completion_tools').setup({sources={},keymap={
      ['<F6>']={function() return vim.keycode('<Left>') end}
    }})]])
    input("iabc<F6>!")
    wait("return vim.api.nvim_get_current_line()=='ab!c'")
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
    input("i<C-Space>")
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
    input("A<C-Space>")
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
    input("A<C-Space>")
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
  test("snippet colors and code previews hide Markdown markers and refresh highlights", function()
    lua([[
      vim.bo.filetype='tex'
      require('completion_tools').setup({sources={'test'},documentation={delay_ms=5},
        providers={test={complete=function(_,cb) cb({items={
          {label='ignore',kind=15,detail='\\ignore{value}',documentation={kind='markdown',
            value='```latex\n\\input{中文}\n```\n\nUse `path`.'}},
          {label='ignoreb',kind=15,documentation={kind='plaintext',value='Plain preview'}}
        }}) end}}})
    ]])
    input("iign")
    wait(
      "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then return true end end;return false"
    )
    lua([[
      assert(vim.api.nvim_get_hl(0,{name='CompletionToolsKindSnippet',link=false}).fg,'Snippet has no foreground')
      local doc
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        local b=vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype=='markdown' then doc=b end
      end
      local lines=vim.api.nvim_buf_get_lines(doc,0,-1,false)
      assert(vim.deep_equal(lines,{'\\ignore{value}','','\\input{中文}','','Use path.'}),vim.inspect(lines))
      local ns=vim.api.nvim_create_namespace('completion-tools-documentation')
      local marks=vim.api.nvim_buf_get_extmarks(doc,ns,0,-1,{details=true})
      assert(#marks>0,'Code highlighting missing')
      local seen={}
      for _,m in ipairs(marks) do seen[m[4].hl_group]=true end
      assert(seen['CompletionToolsDocCode'] and seen['@function'])
    ]])
    input("<C-n>")
    wait(
      "for _,w in ipairs(vim.api.nvim_list_wins()) do local b=vim.api.nvim_win_get_buf(w);if vim.bo[b].filetype=='markdown' then return vim.api.nvim_buf_get_lines(b,0,1,false)[1]=='Plain preview' end end;return false"
    )
    lua([[
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        local b=vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype=='markdown' then
          assert(#vim.api.nvim_buf_get_extmarks(b,vim.api.nvim_create_namespace('completion-tools-documentation'),0,-1,{})==0)
        end
      end
    ]])
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
      vim.api.nvim_buf_set_lines(0,0,-1,false,{"header","😀"}); vim.api.nvim_win_set_cursor(0,{2,0})]])
    start_fixture()
    input("A.")
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
      wait(
        "for _,w in ipairs(vim.api.nvim_list_wins()) do local b=vim.api.nvim_win_get_buf(w);if vim.bo[b].filetype=='markdown' then return vim.api.nvim_buf_get_lines(b,0,1,false)[1]:find('hello',1,true)~=nil end end;return false"
      )
      lua([[
        assert(vim.api.nvim_get_hl(0,{name='CompletionToolsKindSnippet',link=false}).fg)
        for _,w in ipairs(vim.api.nvim_list_wins()) do
          local b=vim.api.nvim_win_get_buf(w)
          if vim.bo[b].filetype=='markdown' then
            for _,line in ipairs(vim.api.nvim_buf_get_lines(b,0,-1,false)) do assert(not line:find('```',1,true)) end
          end
        end
      ]])
      input("<Tab>")
      wait("return vim.api.nvim_get_mode().mode == 's' and vim.api.nvim_get_current_line()=='hello world!'")
      input("user")
      wait("return vim.api.nvim_get_current_line()=='hello user!'")
      input("<Tab>")
      wait("return vim.api.nvim_get_mode().mode == 'i'")
    end)
  end
  test("custom dictionary completes words absent from the buffer and reloads edited files", function()
    lua([[
      dictionary_fixture=vim.fn.tempname()
      vim.fn.writefile({'uniqueDictionaryWord','uniqueDictionaryWord','unrelated'},dictionary_fixture)
      require('completion_tools').setup({sources={'dictionary'},dictionary={files={dictionary_fixture}}})
    ]])
    input("iuni")
    wait("return require('completion_tools').is_menu_visible()", "background dictionary", 8000)
    eq("uniqueDictionaryWord", lua("return require('completion_tools').get_selected_item().label"))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='uniqueDictionaryWord!'")
    input("<C-u>")
    wait("return vim.api.nvim_get_current_line()==''")
    lua("vim.fn.writefile({'uniqueReplacement'},dictionary_fixture)")
    input("uni")
    wait(
      "return require('completion_tools').get_selected_item() and require('completion_tools').get_selected_item().label=='uniqueReplacement'",
      "dictionary file invalidation",
      8000
    )
    input("<Tab>")
    wait("return vim.api.nvim_get_current_line()=='uniqueReplacement'")
    lua("vim.fn.delete(dictionary_fixture)")
  end)
  test("spell corrects transposed letters and accepts without copying filterText", function()
    lua([[
      vim.wo.spell=true;vim.bo.spelllang='en'
      require('completion_tools').setup({sources={'spell'},spell={sort='suggestion',debounce_ms=0}})
    ]])
    input("iteh")
    wait(
      "for _,item in ipairs(require('completion_tools').get_items()) do if item.label=='the' then return true end end;return false",
      "native background spelling",
      8000
    )
    lua(
      "local c=require('completion_tools');for _=1,#c.get_items() do if c.get_selected_item().label=='the' then break end;c.select_next() end"
    )
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='the!'")
    input("<C-u>teh")
    wait("return vim.api.nvim_get_current_line()=='teh'")
    input("<BS><BS><BS>")
    wait("return not require('completion_tools').is_menu_visible()")
    vim.wait(100)
    assert(
      not lua("return require('completion_tools').is_menu_visible()"),
      "Late spell results reopened an empty query"
    )
    lua("vim.wo.spell=false")
  end)
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
