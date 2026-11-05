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
local function copilot_cache_fixture(texts, preselect)
  lua(
    [[
    local texts,preselect=...
    vim.api.nvim_buf_set_lines(0,0,-1,false,{'中😀 = )','untouched'})
    vim.api.nvim_win_set_cursor(0,{1,#'中😀 = '})
    cache_requests, cache_accepted, cache_allowed, cache_enabled = 0, {}, true, true
    cache_accepted_lengths={}
    cache_other_calls, cache_with_other = 0, false
    cache_response_delay, cache_cancellations = 30, 0
    local client={initialized=true}
    function client:is_stopped() return false end
    function client:cancel_request() cache_cancellations=cache_cancellations+1 end
    function client:request(method,params,cb)
      if method=='notifyAccepted' then
        cache_accepted[#cache_accepted+1]=params.uuid
        cache_accepted_lengths[#cache_accepted_lengths+1]=params.acceptedLength
        cb(); return true
      end
      cache_requests=cache_requests+1
      local id=cache_requests
      vim.defer_fn(function()
        local items={}
        for i,text in ipairs(texts) do
          items[i]={text='中😀 = '..text,uuid=id..':'..i,
            range={start={line=0,character=0},['end']=params.position}}
        end
        cb(nil,{completions=items})
      end,cache_response_delay)
      return true,id
    end
    local native=require('completion_tools.copilot')
    local original=native.new
    native.new=function() return {
      eligible=function() return cache_allowed end,
      ensure=function(_,cb) cb(client); return function() end end,
      dispose=function() end,
    } end
    require('completion_tools').setup({
      sources=function() return cache_with_other and {'copilot','other'} or {'copilot'} end,
      copilot={debounce_ms=150}, preselect=preselect,
      keymap=vim.tbl_extend('force',require('completion_tools.config').defaults.keymap,{
        ['<C-l>']={'accept_word','fallback'},['<M-l>']={'accept_line','fallback'},
      }), providers={
        copilot={enabled=function() return cache_enabled end},
        other={complete=function(_,cb) cache_other_calls=cache_other_calls+1; cb({items={}}) end},
      }})
    native.new=original
  ]],
    texts or { "print(1)\nfinish()", "printf(2)\nfinish()", "prune(3)\nfinish()" },
    preselect ~= false
  )
  input("ipr")
  wait("return cache_requests==1 and require('completion_tools').get_status().sources.copilot.status=='done'")
  if preselect == false then
    input("<C-n>")
  end
  wait("return require('completion_tools')._can('accept')")
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
  test("manual completion survives text events from the same input batch", function()
    lua([[
      require('completion_tools').setup({sources={'test'},providers={test={complete=function(_,cb)
        cb({items={{label='alpha'}}})
      end}}})
    ]])
    input("i(<C-Space>")
    wait(
      "return require('completion_tools').is_menu_visible()",
      "manual menu after typing and triggering together"
    )
    vim.wait(100)
    assert(lua("return require('completion_tools')._can('accept')"), "delayed text event closed manual menu")
    input("(")
    wait(
      "return not require('completion_tools').is_menu_visible()",
      "new punctuation still closes the session"
    )
  end)
  test("manual completion survives LSP refreshes at a blocked symbol", function()
    lua([[
      manual_calls = 0
      require('completion_tools').setup({sources={'test'},providers={test={complete=function(_,cb)
        manual_calls=manual_calls+1; cb({items={{label='alpha'},{label='alpine'}}})
      end}}})
    ]])
    input("i(")
    wait("return vim.api.nvim_get_current_line()=='(' and not require('completion_tools').is_menu_visible()")
    input("<C-Space>")
    wait("return require('completion_tools').is_menu_visible()")
    for _, event in ipairs({ "LspAttach", "LspDetach" }) do
      local before = lua("return manual_calls")
      lua("vim.api.nvim_exec_autocmds(...,{buffer=0,data={client_id=999999}})", event)
      wait("return manual_calls > " .. before, "manual source re-requested by " .. event)
      assert(lua("return require('completion_tools').is_menu_visible()"), "manual menu closed on " .. event)
      assert(lua("return require('completion_tools')._can('accept')"), "refreshed menu must remain usable")
    end
  end)
  test("manual-only completion preserves source overrides and its window during delayed refresh", function()
    lua([[
      manual_calls=0
      local maps=vim.deepcopy(require('completion_tools.config').defaults.keymap)
      maps['<C-Space>']={function(cmp) return cmp.show({sources={'test'}}) end}
      require('completion_tools').setup({auto_show=false,sources={},keymap=maps,
        providers={test={complete=function(_,cb)
          manual_calls=manual_calls+1
          if manual_calls==1 then cb({items={{label='alpha'},{label='alpine'}}})
          else vim.defer_fn(function() cb({items={{label='alpha'},{label='alpine'}}}) end,100) end
        end}}})
    ]])
    input("i<C-Space>")
    wait("return require('completion_tools')._can('accept')")
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label=='alpine'")
    lua([[
      manual_window=nil
      for _,win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='completion-tools-menu' then manual_window=win end
      end
      manual_window_closed=false
      vim.api.nvim_create_autocmd('WinClosed',{once=true,pattern=tostring(manual_window),
        callback=function() manual_window_closed=true end})
      vim.api.nvim_exec_autocmds('LspAttach',{buffer=0,data={client_id=999999}})
    ]])
    wait("return manual_calls==2 and not require('completion_tools')._can('accept')")
    assert(lua("return require('completion_tools').is_menu_visible() and not manual_window_closed"))
    wait("return require('completion_tools')._can('accept')")
    assert(lua("return vim.api.nvim_win_is_valid(manual_window) and not manual_window_closed"))
    eq("alpine", lua("return require('completion_tools').get_selected_item().label"))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='alpine!'")
  end)
  test("automatic completion blocks symbols even when a provider declares them as triggers", function()
    lua([[
      symbol_calls=0
      require('completion_tools').setup({sources={'test'},min_keyword_length=0,
        providers={test={trigger=function() return true end,complete=function(_,cb)
          symbol_calls=symbol_calls+1; cb({items={{label='alpha'}}})
        end}}})
    ]])
    input("ia")
    wait("return require('completion_tools').is_menu_visible()")
    for _, character in ipairs({
      " ",
      "(",
      ")",
      "[",
      "]",
      "{",
      "}",
      ",",
      ";",
      ":",
      "/",
      "\\",
      "!",
      "，",
      "。",
    }) do
      local before = lua("return symbol_calls")
      input(character)
      wait(string.format("return vim.api.nvim_get_current_line() == %q", "a" .. character))
      vim.wait(60)
      eq(before, lua("return symbol_calls"))
      assert(not lua("return require('completion_tools').is_menu_visible()"), character)
      input("<BS>")
      wait("return vim.api.nvim_get_current_line()=='a' and require('completion_tools').is_menu_visible()")
    end
    input("(")
    wait("return vim.api.nvim_get_current_line()=='a('")
    input("<C-Space>")
    wait("return require('completion_tools').is_menu_visible()")
  end)
  test("dot and filetype-specific symbols trigger without a provider trigger", function()
    lua([[
      require('completion_tools').setup({sources={'test'},min_keyword_length=3,
        trigger_characters=function(ctx)
          return ctx.filetype=='tex' and {'.','\\','{'} or {'.'}
        end, providers={test={complete=function(_,cb) cb({items={{label='alpha'}}}) end}}})
    ]])
    input("i.")
    wait("return require('completion_tools').is_menu_visible()")
    input("{")
    wait("return vim.api.nvim_get_current_line()=='.{' and not require('completion_tools').is_menu_visible()")
    lua("vim.bo.filetype='tex'")
    input("<BS>{")
    wait("return require('completion_tools').is_menu_visible()")
    input("\\")
    wait(
      "local c=require('completion_tools'); local ctx=c.get_context(); return ctx and ctx.before=='.{\\\\' and c.is_menu_visible()"
    )
    input(" ")
    wait("return not require('completion_tools').is_menu_visible()")
  end)
  test("blocked symbols cancel delayed completion and allow subsequent word input", function()
    lua([[
      symbol_requests=0; symbol_cancelled=0
      require('completion_tools').setup({sources={'test'},debounce_ms=20,
        providers={test={complete=function(_,cb)
          symbol_requests=symbol_requests+1
          vim.defer_fn(function() cb({items={{label='alpha'}}}) end,100)
          return function() symbol_cancelled=symbol_cancelled+1 end
        end}}})
    ]])
    input("ia")
    wait("return symbol_requests==1")
    input("(")
    wait("return vim.api.nvim_get_current_line()=='a(' and symbol_cancelled==1")
    vim.wait(150)
    eq(1, lua("return symbol_requests"))
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    input("a")
    wait("return require('completion_tools').is_menu_visible()")
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
  test("paging stops at both ends and consumes boundary keys while single steps wrap", function()
    lua([[paging_fallback=0;paging_calls=0;local items={}
      for i=1,8 do items[i]={label=string.format('alpha%02d',i)} end
      require('completion_tools').setup({sources={'test'},keymap={
        ['<A-d>']={function(c) paging_calls=paging_calls+1;return c.select_next({count=5,wrap=false}) end,
          function() paging_fallback=paging_fallback+1 end},
        ['<A-u>']={function(c) paging_calls=paging_calls+1;return c.select_prev({count=5,wrap=false}) end,
          function() paging_fallback=paging_fallback+1 end},
        ['<C-n>']={'select_next'},['<C-p>']={'select_prev'}},
        providers={test={complete=function(_,cb) cb({items=items}) end}}})]])
    input("ial")
    wait("return require('completion_tools')._can('accept')")
    local calls = 0
    for _, step in ipairs({
      { "<A-d>", "alpha06" },
      { "<A-d>", "alpha08" },
      { "<A-d>", "alpha08" },
      { "<C-n>", "alpha01" },
      { "<C-p>", "alpha08" },
      { "<A-u>", "alpha03" },
      { "<A-u>", "alpha01" },
      { "<A-u>", "alpha01" },
    }) do
      input(step[1])
      if step[1]:find("<A-", 1, true) then
        calls = calls + 1
        wait("return paging_calls==" .. calls)
      end
      wait("return require('completion_tools').get_selected_item().label=='" .. step[2] .. "'")
    end
    eq(0, lua("return paging_fallback"))
    eq("al", lua("return vim.api.nvim_get_current_line()"))
    lua([[assert(require('completion_tools').select_next({count=100,wrap=false}))
      assert(require('completion_tools').get_selected_item().label=='alpha08')]])
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
  test("automatic selection follows the first item when a slower source returns", function()
    lua([[slow_reply=nil;require('completion_tools').setup({sources={'fast','slow'},providers={
      fast={complete=function(_,cb) cb({items={{label='alpha'},{label='alphaZ'}}}) end},
      slow={score_offset=1000,complete=function(_,cb) slow_reply=cb end}
    }})]])
    input("ial")
    wait("return require('completion_tools')._can('accept')")
    eq("alpha", lua("return require('completion_tools').get_selected_item().label"))
    lua("slow_reply({items={{label='alphaLsp'}}})")
    wait("return require('completion_tools').get_items()[1].label=='alphaLsp'")
    eq("alphaLsp", lua("return require('completion_tools').get_selected_item().label"))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='alphaLsp!'")
  end)
  for _, keys in ipairs({ "<C-n>", "<C-n><C-p>" }) do
    test("manual navigation keeps the same candidate across slower-source reordering: " .. keys, function()
      lua([[slow_reply=nil;require('completion_tools').setup({sources={'fast','slow'},providers={
        fast={complete=function(_,cb) cb({items={{label='alpha'},{label='alphaZ'}}}) end},
        slow={score_offset=1000,complete=function(_,cb) slow_reply=cb end}
      }})]])
      input("ial")
      wait("return require('completion_tools')._can('accept')")
      input(keys)
      local expected = keys == "<C-n>" and "alphaZ" or "alpha"
      wait("return require('completion_tools').get_selected_item().label=='" .. expected .. "'")
      lua("require('completion_tools').show()") -- Same-context source refresh is not an edit.
      wait("return require('completion_tools')._can('accept')")
      eq(expected, lua("return require('completion_tools').get_selected_item().label"))
      lua("slow_reply({items={{label='alphaLsp'}}})")
      wait("return require('completion_tools').get_items()[1].label=='alphaLsp'")
      eq(expected, lua("return require('completion_tools').get_selected_item().label"))
    end)
  end
  test("same-label overload selection survives reordered streaming items", function()
    lua([[require('completion_tools').setup({sources={'stream'},providers={stream={
      complete=function(_,cb)
        overload_reply=cb
        cb({items={{label='open',kind=3,detail='open(path)',data={id=1}},
          {label='open',kind=3,detail='open(fd)',data={id=2}}}})
      end,
      execute=function(entry) accepted_overload=entry.item.data.id end,
    }}})]])
    input("iop")
    wait("return #require('completion_tools').get_items()==2 and require('completion_tools')._can('accept')")
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().data.id==2")
    lua([[overload_reply({items={{label='open',kind=3,detail='open(fd)',data={id=2}},
      {label='open',kind=3,detail='open(path)',data={id=1}}}})]])
    wait("return require('completion_tools').get_items()[1].data.id==2")
    eq(2, lua("return require('completion_tools').get_selected_item().data.id"))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='open!' and accepted_overload==2")
  end)
  test("acceptance learns history across setup without changing command-line sorting", function()
    lua([[history_path=vim.fn.tempname()..'/history.json'
      function history_setup(enabled)
        require('completion_tools').setup({sources={'test'},ranking={history={enabled=enabled,path=history_path}},
          providers={test={complete=function(_,cb) cb({items={{label='alpha'},{label='alpine'}}}) end}}})
      end
      history_setup(true)
    ]])
    input("ial")
    wait("return require('completion_tools')._can('accept')")
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label=='alpine'")
    input("<Tab><Esc>")
    wait("return vim.api.nvim_get_mode().mode=='n' and vim.api.nvim_get_current_line()=='alpine'")
    lua(
      "history_setup(true);vim.api.nvim_buf_set_lines(0,0,-1,false,{''});vim.api.nvim_win_set_cursor(0,{1,0})"
    )
    input("ial")
    wait(
      "return require('completion_tools')._can('accept') and require('completion_tools').get_selected_item().label=='alpine'"
    )
    input("<Esc>")
    wait("return vim.api.nvim_get_mode().mode=='n'")
    lua(
      "history_setup(false);vim.api.nvim_buf_set_lines(0,0,-1,false,{''});vim.api.nvim_win_set_cursor(0,{1,0})"
    )
    input("ial")
    wait(
      "return require('completion_tools')._can('accept') and require('completion_tools').get_selected_item().label=='alpha'"
    )
    lua("vim.fn.delete(vim.fs.dirname(history_path),'rf')")
  end)
  test("fallback waits for completion and uses matching results rather than raw counts", function()
    lua([[fallback_calls=0
      require('completion_tools').setup({sources={'fallback','main'},providers={
        main={complete=function(_,cb) main_reply=cb;cb({items={{label='unrelated'}},pending=true}) end},
        fallback={fallback_for={'main'},max_items=1,complete=function(_,cb)
          fallback_calls=fallback_calls+1;cb({items={{label='alphanumeric'},{label='alpha'}}})
        end},
      }})]])
    input("ial")
    wait("return main_reply~=nil")
    eq(0, lua("return fallback_calls"))
    lua("main_reply({items={{label='unrelated'}}})")
    wait("return require('completion_tools')._can('accept')")
    eq(1, lua("return fallback_calls"))
    eq(
      { "alpha" },
      lua("return vim.tbl_map(function(i) return i.label end,require('completion_tools').get_items())")
    )
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='alpha!'")
  end)
  test("matching main results suppress fallback even when configured first", function()
    lua([[fallback_calls=0
      require('completion_tools').setup({sources={'fallback','main'},providers={
        main={complete=function(_,cb) cb({items={{label='alpha'}}}) end},
        fallback={fallback_for={'main'},complete=function(_,cb)
          fallback_calls=fallback_calls+1;cb({items={{label='alpine'}}})
        end},
      }})]])
    input("ial")
    wait("return require('completion_tools')._can('accept')")
    eq(0, lua("return fallback_calls"))
    eq(1, lua("return #require('completion_tools').get_items()"))
  end)
  test("source deadline closes retained menus and ignores late callbacks", function()
    lua([[timeout_cancelled=0
      require('completion_tools').setup({sources={'main'},timeout_ms=50,providers={
        main={complete=function(ctx,cb)
          if ctx.prefix=='a' then cb({items={{label='alpha'}}}) else timeout_reply=cb end
          return function() timeout_cancelled=timeout_cancelled+1 end
        end},
      }})]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    input("l")
    wait("return timeout_reply~=nil")
    wait("return not require('completion_tools').is_menu_visible()")
    assert(lua("return timeout_cancelled>0"))
    lua("timeout_reply({items={{label='alpha'}}})")
    vim.wait(40)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
  end)
  test("live diagnostics track cached requests, counts and trigger rejection", function()
    lua([[diag_calls=0
      require('completion_tools').setup({sources={'test'},providers={test={max_items=1,complete=function(_,cb)
        diag_calls=diag_calls+1; cb({items={{label='alpha'},{label='alpine'}},reusable=true})
      end}}})]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    lua([[local s=require('completion_tools').get_status();local p=s.sources.test
      assert(s.reason=='ready' and p.status=='done' and p.raw_count==2 and p.shown_count==1)
      assert(p.requests==1 and p.cache_hits==0 and p.elapsed_ms>=0)
      p.requests=999
      assert(require('completion_tools').get_status().sources.test.requests==1)
    ]])
    input("l")
    wait(
      "return require('completion_tools').get_status().sources.test.cache_hits==1 and require('completion_tools')._can('accept')"
    )
    eq(1, lua("return diag_calls"))
    input("(")
    wait("return require('completion_tools').get_status().reason=='trigger_filtered'")
    lua([[local s=require('completion_tools').get_status()
      assert(not s.menu_visible and s.sources.test.shown_count==0)
      assert(s.last_request_reason=='trigger_filtered')]])
  end)
  test("diagnostics distinguish pending, timeout, waiting and skipped sources", function()
    lua([[require('completion_tools').setup({sources={'main','fallback','last'},timeout_ms=100,
      providers={main={complete=function() end},fallback={fallback_for={'main'},complete=function(_,cb)
        cb({items={{label='alpha'}}})
      end},last={fallback_for={'fallback'},complete=function() error('must not run') end}}})]])
    input("ial")
    wait("return require('completion_tools').get_status().sources.main.status=='pending'")
    eq("waiting", lua("return require('completion_tools').get_status().sources.fallback.status"))
    wait("return require('completion_tools').get_status().sources.main.status=='timeout'")
    lua([[local s=require('completion_tools').get_status()
      assert(s.sources.main.timeouts==1 and s.sources.main.elapsed_ms>=80)
      assert(s.sources.fallback.status=='done' and s.sources.last.status=='skipped')]])
  end)
  test("provider errors remain inspectable after a later successful request", function()
    lua([[diag_fail=true
      require('completion_tools').setup({sources={'test'},providers={test={complete=function(_,cb)
        if diag_fail then error('diagnostic fixture failure') end
        cb({items={{label='alpha'}}})
      end}}})]])
    input("ia")
    wait("return require('completion_tools').get_status().sources.test.status=='error'")
    lua([[local p=require('completion_tools').get_status().sources.test
      assert(p.errors==1 and p.last_error:find('diagnostic fixture failure',1,true))
      test_notifications={};diag_fail=false]])
    input("l")
    wait("return require('completion_tools')._can('accept')")
    lua(
      [[local p=require('completion_tools').get_status().sources.test
      assert(p.status=='done' and p.errors==1 and p.last_error:find('diagnostic fixture failure',1,true))]]
    )
  end)
  test("source eligibility callback errors are diagnosed and release fallback", function()
    lua([[require('completion_tools').setup({sources={'bad','fallback'},providers={
      bad={enabled=function() error('eligibility fixture failure') end,complete=function() end},
      fallback={fallback_for={'bad'},complete=function(_,cb) cb({items={{label='alpha'}}}) end},
    }})]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    lua([[local p=require('completion_tools').get_status().sources.bad
      assert(p.status=='error' and p.errors==1 and p.last_error:find('eligibility fixture failure',1,true))
      test_notifications={}]])
  end)
  test("typing and backspace reset manual selection to the latest first item", function()
    lua([[require('completion_tools').setup({sources={'test'},providers={test={complete=function(_,cb)
      cb({items={{label='alpha'},{label='alphaZ'}},reusable=true})
    end}}})]])
    input("ial")
    wait("return require('completion_tools')._can('accept')")
    for _, key in ipairs({ "p", "<BS>" }) do
      input("<C-n>")
      wait("return require('completion_tools').get_selected_item().label=='alphaZ'")
      input(key)
      wait(
        "return require('completion_tools')._can('accept') and require('completion_tools').get_selected_item().label=='alpha'"
      )
    end
    eq("al", lua("return vim.api.nvim_get_current_line()"))
  end)
  test("a vanished manual selection stays empty until navigation or another edit", function()
    lua(
      [[stream_reply=nil;require('completion_tools').setup({sources={'stream'},documentation={delay_ms=5},providers={
      stream={complete=function(_,cb) stream_reply=cb;cb({items={{label='alpha',detail='first'},
        {label='alphaZ',detail='selected'}}}) end}
    }})]]
    )
    input("ial")
    wait("return require('completion_tools')._can('accept')")
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label=='alphaZ'")
    wait([[for _,w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then
        return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,-1,false),'\n'):find('selected',1,true)~=nil
      end end;return false]])
    lua("stream_reply({items={{label='alpha'},{label='alphaNew'}}})")
    wait("return require('completion_tools').get_items()[2].label=='alphaNew'")
    lua([[local c=require('completion_tools')
      assert(c.is_menu_visible() and c.get_selected_item()==nil and not c._can('accept') and not c.accept())
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        assert(vim.bo[vim.api.nvim_win_get_buf(w)].filetype~='markdown','cleared selection kept documentation')
      end
      stream_reply({items={{label='alpha'},{label='alphaZ'},{label='alphaOther'}}})
    ]])
    wait("return #require('completion_tools').get_items()==3")
    eq(true, lua("return require('completion_tools').get_selected_item()==nil"))
    input("<C-p>")
    wait("return require('completion_tools')._can('accept')")
    eq(
      true,
      lua(
        "return require('completion_tools').get_selected_item().label==require('completion_tools').get_items()[3].label"
      )
    )
    input("p")
    wait(
      "return require('completion_tools')._can('accept') and require('completion_tools').get_selected_item().label=='alpha'"
    )
  end)
  test("disabled preselection stays disabled across asynchronous updates and edits", function()
    lua([[stream_reply=nil;require('completion_tools').setup({preselect=false,sources={'stream'},providers={
      stream={complete=function(_,cb) stream_reply=cb;cb({items={{label='alpha'},{label='alphaZ'}}}) end}
    }})]])
    input("ial")
    wait("return require('completion_tools').is_menu_visible()")
    eq(true, lua("return require('completion_tools').get_selected_item()==nil"))
    lua("stream_reply({items={{label='alpha'},{label='alphaZ'},{label='alphaNew'}}})")
    wait("return #require('completion_tools').get_items()==3")
    eq(true, lua("return require('completion_tools').get_selected_item()==nil"))
    input("<C-n>")
    wait("return require('completion_tools')._can('accept')")
    input("p")
    wait(
      "return require('completion_tools').get_context().prefix=='alp' and require('completion_tools')._can('select_next')"
    )
    eq(true, lua("return require('completion_tools').get_selected_item()==nil"))
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
  test("empty fast sources do not blank a pending replacement", function()
    lua([[
      require('completion_tools').setup({sources={'fast','slow'},documentation={auto_show=false},providers={
        fast={complete=function(_,cb) cb({items={{label='zzzz'}}}) end},
        slow={complete=function(ctx,cb)
          if ctx.prefix~='a' then cb({items={},pending=true}) end
          vim.defer_fn(function()
          cb({items=ctx.prefix=='alz' and {} or {{label=ctx.prefix..'Result'}}})
        end,ctx.prefix=='a' and 5 or 160) end}
      }})
    ]])
    input("ia")
    wait("return require('completion_tools').is_menu_visible()")
    local id = lua([[for _,w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then return w end end]])
    lua(
      [[menu_closed=0;vim.api.nvim_create_autocmd('WinClosed',{pattern=tostring(...),callback=function() menu_closed=menu_closed+1 end})]],
      id
    )
    input("l")
    wait(
      "return require('completion_tools').get_context() and require('completion_tools').get_context().prefix=='al'"
    )
    vim.wait(30)
    assert(
      lua("local c=require('completion_tools');return c.is_menu_visible() and not c.accept()"),
      "empty source blanked the last ready frame"
    )
    eq(0, lua("return menu_closed"))
    wait("return require('completion_tools').get_selected_item().label=='alResult'")
    eq(true, lua("return vim.api.nvim_win_is_valid(...)", id))
    input("z")
    wait(
      "return require('completion_tools').get_context() and require('completion_tools').get_context().prefix=='alz'"
    )
    vim.wait(30)
    assert(lua("return require('completion_tools').is_menu_visible()"))
    wait("return not require('completion_tools').is_menu_visible()")
    eq(1, lua("return menu_closed"))
  end)
  test("fresh matches remain usable while another source is pending", function()
    lua([[slow_done=false;require('completion_tools').setup({sources={'fast','slow'},providers={
      fast={complete=function(_,cb) cb({items={{label='alphaFast'}}}) end},
      slow={complete=function(_,cb) vim.defer_fn(function() slow_done=true;cb({items={}}) end,300) end}
    }})]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    assert(not lua("return slow_done"))
    assert(lua("return require('completion_tools').accept()"))
    wait("return vim.api.nvim_get_current_line()=='alphaFast'")
    input("<Esc>")
  end)
  test("menu direction reserves maximum height before small asynchronous results grow", function()
    lua([[
      local lines={};for i=1,32 do lines[i]='' end
      vim.api.nvim_buf_set_lines(0,0,-1,false,lines)
      vim.api.nvim_win_set_cursor(0,{26,0})
      require('completion_tools').setup({sources={'test'},documentation={auto_show=false},
        providers={test={complete=function(_,cb)
          direction_reply=cb;cb({items={{label='alpha01'},{label='alpha02'}}})
        end}}})
      function direction_menu()
        for _,w in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then
            local wc=vim.api.nvim_win_get_config(w);wc.win=w
            wc.lines=vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,-1,false)
            wc.cursor=vim.api.nvim_win_get_cursor(w)[1]
            return wc
          end
        end
      end
    ]])
    input("ia")
    wait("return require('completion_tools').is_menu_visible()")
    local small = lua("return direction_menu()")
    assert(small.row < 25, "small initial result ignored menu.max_height")
    eq(2, small.cursor)
    lua([[
      local items={};for i=1,20 do items[i]={label=string.format('alpha%02d',i)} end
      direction_reply({items=items})
    ]])
    wait("return direction_menu().height==12")
    local large = lua("return direction_menu()")
    eq(small.win, large.win)
    eq(small.row + small.height, large.row + large.height)
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='alpha01!'")
  end)
  for _, case in ipairs({
    { row = 1, inverse = "auto", reversed = false },
    { row = 32, inverse = "auto", reversed = true },
    { row = 1, inverse = true, reversed = true },
    { row = 32, inverse = true, reversed = true },
    { row = 1, inverse = false, reversed = false },
    { row = 32, inverse = false, reversed = false },
    { row = 32, inverse = "auto", reversed = true, preselect = false },
  }) do
    test("inverse menu scrolling and acceptance " .. vim.inspect(case), function()
      lua(
        [[
        local case=...
        local lines={};for i=1,32 do lines[i]='' end
        vim.api.nvim_buf_set_lines(0,0,-1,false,lines)
        vim.api.nvim_win_set_cursor(0,{case.row,0})
        local items={};for i=1,8 do items[i]={label=string.format('alpha%02d',i)} end
        require('completion_tools').setup({sources={'test'},preselect=case.preselect~=false,
          menu={max_height=3,inverse=case.inverse},documentation={auto_show=false},
          providers={test={complete=function(_,cb) cb({items=items}) end}}})
      ]],
        case
      )
      input("ia")
      wait("return require('completion_tools').is_menu_visible()")
      local menu = lua("return direction_menu()")
      eq(case.row == 32, menu.row < case.row - 1)
      eq(case.reversed and 3 or 1, menu.cursor)
      assert(menu.lines[menu.cursor]:find("alpha01", 1, true))
      eq(case.preselect ~= false, lua("return require('completion_tools').get_selected_item()~=nil"))
      if case.preselect == false then
        input(case.reversed and "<C-p>" or "<C-n>")
        wait("return require('completion_tools').get_selected_item()~=nil")
      end
      lua(
        "require('completion_tools')."
          .. (case.reversed and "select_prev" or "select_next")
          .. "({count=5,wrap=false})"
      )
      menu = lua("return direction_menu()")
      assert(menu.lines[menu.cursor]:find("alpha06", 1, true))
      -- Ranked API order stays intact even when the visible rows are reversed.
      eq("alpha01", lua("return require('completion_tools').get_items()[1].label"))
      local previous_row = menu.cursor
      input("<C-n>")
      wait(
        "return require('completion_tools').get_selected_item().label=='"
          .. (case.reversed and "alpha05" or "alpha07")
          .. "'"
      )
      menu = lua("return direction_menu()")
      if case.reversed then
        eq(previous_row + 1, menu.cursor)
      end
      input("<C-p>")
      wait("return require('completion_tools').get_selected_item().label=='alpha06'")
      lua("require('completion_tools').select_next({count=100,wrap=false})")
      eq(
        case.reversed and "alpha01" or "alpha08",
        lua("return require('completion_tools').get_selected_item().label")
      )
      lua("require('completion_tools').select_prev({count=100,wrap=false})")
      eq(
        case.reversed and "alpha08" or "alpha01",
        lua("return require('completion_tools').get_selected_item().label")
      )
      lua(
        "require('completion_tools')."
          .. (case.reversed and "select_next" or "select_prev")
          .. "({count=3,wrap=false})"
      )
      input("<Tab>!")
      wait("return vim.api.nvim_get_current_line()=='" .. (case.reversed and "alpha05!" or "alpha01!") .. "'")
    end)
  end
  test("retained menu reverses its rows and selection when repositioned across the input", function()
    lua([[
      local lines={};for i=1,32 do lines[i]='' end
      vim.api.nvim_buf_set_lines(0,0,-1,false,lines)
      require('completion_tools').setup({sources={'test'},menu={max_height=3},
        documentation={auto_show=false},providers={test={complete=function(_,cb)
          cb({items={{label='alpha01'},{label='alpha02'},{label='alpha03'}}})
        end}}})
    ]])
    input("ia")
    wait("return require('completion_tools').is_menu_visible()")
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label=='alpha02'")
    local original = lua("return direction_menu()")
    lua([[
      -- Exercise the retained-frame path without a new provider result.
      local ctx=vim.deepcopy(require('completion_tools').get_context())
      ctx.row=31
      require('completion_tools.ui').reposition(ctx,require('completion_tools.config').validate({menu={max_height=3}}))
    ]])
    local menu = lua("return direction_menu()")
    eq(original.win, menu.win)
    assert(menu.row < 31 and menu.lines[1]:find("alpha03", 1, true))
    assert(menu.lines[menu.cursor]:find("alpha02", 1, true))
    lua([[
      require('completion_tools.ui').reposition(require('completion_tools').get_context(),
        require('completion_tools.config').validate({menu={max_height=3}}))
    ]])
    menu = lua("return direction_menu()")
    assert(menu.row > 0 and menu.lines[1]:find("alpha01", 1, true))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='alpha02!'")
  end)
  test("neither side fits maximum height: use more space and prefer below on ties", function()
    rpc("nvim_ui_try_resize", 120, 18)
    for _, case in ipairs({
      { row = 8, above = false, height = 7 },
      { row = 9, above = false, height = 6 },
      { row = 11, above = true, height = 8 },
    }) do
      lua(
        [[
        require('completion_tools').hide()
        local lines={};for i=1,14 do lines[i]='' end
        vim.api.nvim_buf_set_lines(0,0,-1,false,lines)
        vim.api.nvim_win_set_cursor(0,{...,0})
        local items={};for i=1,20 do items[i]={item={label='alpha'..i},source_id='test',start_col=0} end
        local config=require('completion_tools.config').validate({})
        require('completion_tools.ui').render(items,1,{mode='insert',winid=vim.api.nvim_get_current_win(),
          row=...-1,col=0,start_col=0,before='',filetype='lua'},config)
      ]],
        case.row
      )
      local menu = lua("return direction_menu()")
      eq(case.above, menu.row < case.row - 1)
      eq(case.height, menu.height)
    end
    lua("require('completion_tools').hide()")
    rpc("nvim_ui_try_resize", 120, 36)
  end)
  test("session width and columns survive streaming results, edits and reset on hide", function()
    lua([[
      require('completion_tools').setup({sources={'test'},documentation={auto_show=false},
        providers={test={complete=function(ctx,cb)
          width_reply=cb
          cb({items={{label=ctx.prefix..'LongName',kind=25,labelDetails={description='module'}}},pending=true})
        end}}})
      function width_menu()
        for _,w in ipairs(vim.api.nvim_list_wins()) do
          local b=vim.api.nvim_win_get_buf(w)
          if vim.bo[b].filetype=='completion-tools-menu' then
            return {win=w,width=vim.api.nvim_win_get_width(w),lines=vim.api.nvim_buf_get_lines(b,0,-1,false)}
          end
        end
      end
    ]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    local original = lua("return width_menu()")
    lua("width_reply({items={{label='alpha',kind=1}},pending=true})")
    wait("return require('completion_tools').get_selected_item().label=='alpha'")
    local short = lua("return width_menu()")
    eq(original.width, short.width)
    eq(original.win, short.win)
    eq(original.lines[1]:find("test", 1, true), short.lines[1]:find("test", 1, true))
    input("l")
    wait("return require('completion_tools').get_selected_item().label=='alLongName'")
    assert(lua("return width_menu().width") >= original.width)
    lua("width_reply({items={{label='alpha',kind=1}}})")
    wait("return require('completion_tools').get_selected_item().label=='alpha'")
    lua([[
      require('completion_tools').hide();require('completion_tools').show()
      width_reply({items={{label='alpha',kind=1}}})
    ]])
    wait("return require('completion_tools')._can('accept')")
    assert(lua("return width_menu().width") < original.width, "hidden menu retained its previous width")
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='alpha!'")
  end)
  test("unchanged frames preserve buffer text and highlight marks", function()
    lua([[
      require('completion_tools').setup({sources={'test'},documentation={auto_show=false},
        providers={test={complete=function(_,cb) cb({items={{label='alpha'},{label='alpine'}}}) end}}})
    ]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    lua([[
      local b
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then b=vim.api.nvim_win_get_buf(w) end
      end
      local ns=vim.api.nvim_create_namespace('completion-tools-menu')
      local tick,marks=vim.api.nvim_buf_get_changedtick(b),vim.api.nvim_buf_get_extmarks(b,ns,0,-1,{details=true})
      require('completion_tools').select_next();require('completion_tools').select_prev()
      assert(tick==vim.api.nvim_buf_get_changedtick(b),'selection rewrote unchanged text')
      assert(vim.deep_equal(marks,vim.api.nvim_buf_get_extmarks(b,ns,0,-1,{details=true})),'selection replaced unchanged highlights')
    ]])
  end)
  test("changed rows and highlight-only updates preserve neighboring marks", function()
    lua([[
      row_color='String'
      require('completion_tools').setup({sources={'test'},documentation={auto_show=false},
        menu={min_width=30,label_details=false,columns={{'label'}},highlight={custom=function(_,_,text)
          return {{0,#text,row_color,220}}
        end}},providers={test={complete=function(_,cb)
          row_reply=cb;cb({items={{label='alpha'},{label='alpine'}},pending=true})
        end}}})
      function row_snapshot()
        for _,w in ipairs(vim.api.nvim_list_wins()) do
          local b=vim.api.nvim_win_get_buf(w)
          if vim.bo[b].filetype=='completion-tools-menu' then
            return {tick=vim.api.nvim_buf_get_changedtick(b),marks=vim.api.nvim_buf_get_extmarks(
              b,vim.api.nvim_create_namespace('completion-tools-menu'),{1,0},{1,-1},{details=true})}
          end
        end
      end
    ]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    local original = lua("return row_snapshot()")
    lua("row_reply({items={{label='atlas'},{label='alpine'}},pending=true})")
    wait("return require('completion_tools').get_selected_item().label=='atlas'")
    local changed = lua("return row_snapshot()")
    assert(changed.tick > original.tick)
    eq(original.marks, changed.marks)
    lua("row_color='Special';row_reply({items={{label='atlas'},{label='alpine'}}})")
    wait([[
      for _,m in ipairs(row_snapshot().marks) do if m[4].hl_group=='Special' then return true end end
      return false
    ]])
    eq(changed.tick, lua("return row_snapshot().tick"))
  end)
  test("streaming bursts coalesce with a bounded deadline and cancel on hide", function()
    lua([[
      burst_paints={}
      local ui=require('completion_tools.ui');burst_render=ui.render
      ui.render=function(items,...)
        burst_paints[#burst_paints+1]=items[1] and items[1].item.label or ''
        return burst_render(items,...)
      end
      require('completion_tools').setup({sources={'test'},menu={update_interval_ms=200},
        documentation={auto_show=false},providers={test={complete=function(ctx,cb)
          burst_reply=cb;cb({items={{label=ctx.prefix..'First'}},pending=true})
        end}}})
    ]])
    input("ia")
    wait("return require('completion_tools')._can('accept')")
    lua([[
      for i=1,12 do vim.defer_fn(function()
        burst_reply({items={{label='aBurst'..i}},pending=true})
        if i==12 then burst_at_end=#burst_paints end
      end,i*3) end
    ]])
    wait("return burst_at_end~=nil")
    eq(1, lua("return burst_at_end"))
    wait("return require('completion_tools').get_selected_item().label=='aBurst12'")
    eq({ "aFirst", "aBurst12" }, lua("return burst_paints"))
    lua([[
      for i=1,120 do vim.defer_fn(function()
        burst_reply({items={{label='aContinuous'..i}},pending=true})
        if i==120 then burst_during_stream=#burst_paints end
      end,i*5) end
    ]])
    wait("return burst_during_stream~=nil")
    assert(lua("return burst_during_stream>=4"), "continuous publications postponed every frame")
    wait("return require('completion_tools').get_selected_item().label=='aContinuous120'")
    lua("burst_reply({items={{label='aStale'}}})")
    input("l")
    wait("return require('completion_tools').get_selected_item().label=='alFirst'")
    lua(
      "burst_reply({items={{label='alCancelled'}}});require('completion_tools').hide();burst_before_hide=#burst_paints"
    )
    vim.wait(250)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    lua([[
      assert(#burst_paints==burst_before_hide)
      assert(not vim.tbl_contains(burst_paints,'aStale') and not vim.tbl_contains(burst_paints,'alCancelled'))
    ]])
    lua("require('completion_tools.ui').render=burst_render")
  end)
  local function height_fixture(delay)
    lua(
      [[
      local lines={};for i=1,32 do lines[i]='' end
      vim.api.nvim_buf_set_lines(0,0,-1,false,lines)
      vim.api.nvim_win_set_cursor(0,{26,0})
      function height_menu()
        for _,w in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then
            local wc=vim.api.nvim_win_get_config(w);wc.win=w
            wc.lines=vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,-1,false)
            return wc
          end
        end
      end
      require('completion_tools').setup({sources={'test'},documentation={auto_show=false},
        menu={shrink_delay_ms=...},providers={test={complete=function(ctx,cb)
          height_send=function(count,pending)
            local items={};for i=1,count do items[i]={label=ctx.prefix..string.format('Fresh%02d',i)} end
            cb({items=items,pending=pending})
          end
          if ctx.prefix~='abc' then height_send(#ctx.prefix==1 and 12 or 2) end
        end}}})
    ]],
      delay
    )
    input("ia")
    wait("return height_menu() and height_menu().height==12")
  end
  test("height settles without delaying contents, selecting blank rows or flipping direction", function()
    height_fixture(200)
    local original = lua("return height_menu()")
    assert(original.row < 25)
    input("b")
    wait(
      "return require('completion_tools').get_context().prefix=='ab' and #require('completion_tools').get_items()==2"
    )
    lua([[
      local wc=height_menu();assert(wc.height==12 and wc.row<25)
      assert(wc.lines[12]:find('abFresh01',1,true))
      for i=1,10 do assert(wc.lines[i]=='','stale candidate retained in blank row') end
    ]])
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label=='abFresh02'")
    input("<C-n>")
    wait("return require('completion_tools').get_selected_item().label=='abFresh01'")
    wait("return height_menu().height==2")
    local settled = lua("return height_menu()")
    eq(original.win, settled.win)
    assert(settled.row < 25, "shrinking switched the menu below the cursor")
    lua("height_send(9)")
    wait("return height_menu().height==9 and #require('completion_tools').get_items()==9")
    lua("height_send(0)")
    wait("return not require('completion_tools').is_menu_visible()")
    vim.wait(250)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
  end)
  test("new results and input invalidate pending height reductions", function()
    height_fixture(200)
    input("b")
    wait("return #require('completion_tools').get_items()==2")
    vim.wait(120)
    lua("height_send(1)")
    wait("return #require('completion_tools').get_items()==1")
    vim.wait(120)
    eq(12, lua("return height_menu().height"))
    lua("height_send(0,true)")
    vim.wait(250)
    lua("assert(height_menu().height==12 and not require('completion_tools')._can('accept'))")
    lua("height_send(1)")
    wait("return require('completion_tools')._can('accept')")
    input("c")
    wait("return require('completion_tools').get_context().prefix=='abc'")
    vim.wait(250)
    lua("assert(height_menu().height==12 and not require('completion_tools')._can('accept'))")
    lua("height_send(1)")
    wait("return height_menu().height==1")
  end)
  test("hiding resets retained height and disposal cancels shrink callbacks", function()
    height_fixture(200)
    input("b")
    wait("return #require('completion_tools').get_items()==2")
    lua("require('completion_tools').hide();require('completion_tools').show()")
    wait("return height_menu() and height_menu().height==2")
    assert(lua("return height_menu().row<25"), "reopening ignored menu.max_height")
    lua("height_send(1)")
    wait("return #require('completion_tools').get_items()==1")
    lua("require('completion_tools').dispose()")
    vim.wait(250)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
  end)
  test("zero shrink delay reduces height immediately", function()
    height_fixture(0)
    input("b")
    wait("return #require('completion_tools').get_items()==2")
    eq(2, lua("return height_menu().height"))
    input("<Tab>")
    wait("return vim.api.nvim_get_current_line()=='abFresh01'")
  end)
  test("typing and backspace keep the same menu and selected-item documentation", function()
    lua([[require('completion_tools').setup({sources={'slow'},documentation={delay_ms=120},providers={
      slow={complete=function(ctx,cb) vim.defer_fn(function()
        local items={{label='alphaLong',detail='function alphaLong()'}}
        if ctx.prefix=='alp' then items[#items+1]={label='alphaLong'..string.rep('Extra',8)} end
        cb({items=items})
      end,90) end}
    }})]])
    input("ial")
    wait(
      "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then return true end end;return false"
    )
    local ids = lua([[local ids={};for _,w in ipairs(vim.api.nvim_list_wins()) do
      local ft=vim.bo[vim.api.nvim_win_get_buf(w)].filetype
      if ft=='markdown' or ft=='completion-tools-menu' then ids[#ids+1]=w end
    end;return ids]])
    for _, key in ipairs({ "p", "<BS>" }) do
      input(key)
      wait(
        "return require('completion_tools').get_context() and not require('completion_tools')._can('accept')"
      )
      vim.wait(20)
      for _, id in ipairs(ids) do
        eq(true, lua("return vim.api.nvim_win_is_valid(...)", id))
      end
      wait("return require('completion_tools')._can('accept')")
      vim.wait(20)
      for _, id in ipairs(ids) do
        eq(true, lua("return vim.api.nvim_win_is_valid(...)", id))
      end
      lua([[local menu,doc
        for _,w in ipairs(vim.api.nvim_list_wins()) do
          local ft=vim.bo[vim.api.nvim_win_get_buf(w)].filetype
          if ft=='completion-tools-menu' then menu=vim.api.nvim_win_get_config(w)
          elseif ft=='markdown' then doc=vim.api.nvim_win_get_config(w) end
        end
        assert(doc.col>=menu.col+menu.width+2 or doc.col+doc.width+2<=menu.col,
          'retained documentation overlaps the resized menu')
      ]])
    end
    eq("al", lua("return vim.api.nvim_get_current_line()"))
  end)
  test("a retained frame follows the cursor across a wrapped line", function()
    lua(
      [[vim.wo.wrap=true;require('completion_tools').setup({sources={'slow'},documentation={auto_show=false},providers={
      slow={complete=function(ctx,cb) vim.defer_fn(function()
        cb({items={{label=ctx.prefix..'Value'}}})
      end,#ctx.prefix==119 and 5 or 160) end}
    }})]]
    )
    input("i" .. string.rep("a", 119))
    wait("return require('completion_tools').is_menu_visible()")
    input("a")
    wait(
      "return require('completion_tools').get_context() and #require('completion_tools').get_context().prefix==120"
    )
    lua([[local ctx=require('completion_tools').get_context()
      local cursor=vim.fn.screenpos(ctx.winid,ctx.row+1,ctx.col+1)
      assert(cursor.row>1,'fixture must wrap')
      local found=false
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then
          found=true;local wc=vim.api.nvim_win_get_config(w)
          assert(wc.row>cursor.row-1,'old frame covers the wrapped input')
        end
      end
      assert(found and not require('completion_tools').accept())
    ]])
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
  for _, mode in ipairs({ "insert", "replace", "override" }) do
    test("accept mode preserves or replaces the suffix with imports: " .. mode, function()
      lua(
        [[
        local mode=...
        local keys=vim.deepcopy(require('completion_tools.config').defaults.keymap)
        if mode=='override' then keys['<Tab>']={function(c) return c.accept({mode='insert'}) end} end
        require('completion_tools').setup({sources={'test'},accept={mode=mode=='insert' and 'insert' or 'replace'},
          keymap=keys,providers={test={complete=function(_,cb)
            cb({items={{label='foobar',_encoding='utf-16',textEdit={newText='foobar',
              insert={start={line=1,character=2},['end']={line=1,character=4}},
              replace={start={line=1,character=2},['end']={line=1,character=8}}},
              additionalTextEdits={{newText='import thing\n',range={start={line=0,character=0},['end']={line=0,character=0}}}}}}})
          end}}})
        vim.api.nvim_buf_set_lines(0,0,-1,false,{'header','😀foTAIL'})
        vim.api.nvim_win_set_cursor(0,{2,6})
      ]],
        mode
      )
      input("i<C-Space>")
      wait("return require('completion_tools')._can('accept')")
      input("<Tab>!")
      local expected = "😀foobar!" .. (mode == "replace" and "" or "TAIL")
      wait("return vim.api.nvim_get_current_line()==" .. vim.inspect(expected))
      eq({ "import thing", "header", expected }, lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)"))
    end)
  end
  for _, mode in ipairs({ 1, 2 }) do
    test("multiline plain text follows insertTextMode " .. mode, function()
      lua(
        [[
        local mode=...
        require('completion_tools').setup({sources={'test'},providers={test={complete=function(_,cb)
          cb({items={{label='block',insertText='block\n\tinner\nend',insertTextMode=mode}}})
        end}}})
        vim.api.nvim_buf_set_lines(0,0,-1,false,{'    bl'})
        vim.api.nvim_win_set_cursor(0,{1,6})
      ]],
        mode
      )
      input("A<C-Space>")
      wait("return require('completion_tools')._can('accept')")
      input("<Tab>!")
      wait("return vim.api.nvim_buf_line_count(0)==3")
      local indent = mode == 2 and "    " or ""
      eq(
        { "    block", indent .. "\tinner", indent .. "end!" },
        lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)")
      )
    end)
    test("native snippet indentation retains placeholder editing for mode " .. mode, function()
      lua(
        [[
        local mode=...
        vim.bo.expandtab=true;vim.bo.shiftwidth=2
        require('completion_tools').setup({sources={'test'},providers={test={complete=function(_,cb)
          cb({items={{label='block',insertText='block\n\t${1:value}\n$0',insertTextFormat=2,insertTextMode=mode}}})
        end}}})
        vim.api.nvim_buf_set_lines(0,0,-1,false,{'    bl'})
        vim.api.nvim_win_set_cursor(0,{1,6})
      ]],
        mode
      )
      input("A<C-Space>")
      wait("return require('completion_tools')._can('accept')")
      input("<Tab>")
      wait("return vim.snippet.active() and vim.api.nvim_get_mode().mode=='s'")
      input("changed")
      wait("return vim.api.nvim_get_current_line():find('changed',1,true)~=nil")
      input("<Tab>!")
      wait("return vim.api.nvim_get_current_line():find('!',1,true)~=nil")
      eq(
        mode == 1 and { "    block", "\tchanged", "!" } or { "    block", "      changed", "    !" },
        lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)")
      )
      assert(lua("return vim.bo.expandtab"))
    end)
  end
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
  test("Markdown documentation conceals delimiters and renders rules and nested emphasis", function()
    lua([[
      require('completion_tools').setup({sources={'test'},documentation={delay_ms=5,max_width=40},
        providers={test={complete=function(_,cb) cb({items={{label='alpha',documentation={kind='markdown',
          value='Overview\n\n---\n\n@*param* `url` — **Target** file.\n*outer **inner** text*'}}}}) end}}})
    ]])
    input("ial")
    wait(
      "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then return true end end;return false"
    )
    lua([[
      vim.cmd.redraw()
      local win
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then win=w end
      end
      assert(vim.wo[win].conceallevel==2 and vim.wo[win].concealcursor=='nvic')
      assert(vim.api.nvim_win_get_height(win)==6,'Unexpected document height')
      local width=vim.api.nvim_win_get_width(win)
      assert(width==vim.fn.strdisplaywidth('@*param* url — **Target** file.'),'Concealed prose may wrap early')
      local at=vim.fn.screenpos(win,1,1)
      local function screen(row)
        local text=''
        for col=at.col,at.col+width-1 do text=text..vim.fn.screenstring(at.row+row,col) end
        return text:gsub('%s+$','')
      end
      assert(screen(2)==string.rep('─',width),screen(2))
      assert(screen(4)=='@param url — Target file.',screen(4))
      assert(screen(5)=='outer inner text',screen(5))
      assert(vim.fn.screenattr(at.row+4,at.col)~=vim.fn.screenattr(at.row+4,at.col+1),'Italic style missing')
      assert(vim.fn.screenattr(at.row+5,at.col)~=vim.fn.screenattr(at.row+5,at.col+6),'Nested bold style missing')
      local raw=table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win),0,-1,false),'\n')
      assert(raw:find('@*param*',1,true),'Expected conceal rather than destructive marker removal')
    ]])
  end)
  test("concealed Markdown in a narrow preview wraps without clipping trailing text", function()
    lua([[
      require('completion_tools').setup({sources={'test'},documentation={delay_ms=5,max_width=12},
        providers={test={complete=function(_,cb) cb({items={{label='alpha',documentation={kind='markdown',
          value='**one two three four five six seven eight nine ten**'}}}}) end}}})
    ]])
    input("ial")
    wait(
      "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then return true end end;return false"
    )
    lua([[
      vim.cmd.redraw()
      for _,win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='markdown' then
          local at=vim.fn.screenpos(win,1,1)
          local height=vim.api.nvim_win_get_height(win)
          assert(height==5,'Conceal wrap rows were undercounted')
          local screen=''
          for row=at.row,at.row+height-1 do
            for col=at.col,at.col+11 do screen=screen..vim.fn.screenstring(row,col) end
          end
          assert(not screen:find('*',1,true),screen)
          assert(screen:find('ten',1,true),'Trailing content clipped: '..screen)
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
  test("manual completion survives an actual LSP client attaching after the menu opens", function()
    lua([[
      require('completion_tools').setup({sources={'test','lsp'},providers={test={complete=function(_,cb)
        cb({items={{label='alpha'}}})
      end}}})
    ]])
    input("i(<C-Space>")
    wait("return require('completion_tools')._can('accept')")
    start_fixture()
    wait("return #require('completion_tools').get_items()==3 and require('completion_tools')._can('accept')")
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line():sub(-1)=='!'")
  end)
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
    for _, mode in ipairs({ 1, 2 }) do
      test("LuaSnip respects explicit insertion indentation mode " .. mode, function()
        lua(
          [[
          local path,mode=...
          vim.opt.runtimepath:append(path)
          require('luasnip').config.setup({})
          require('completion_tools').setup({sources={'test'},snippets={preset='luasnip'},
            providers={test={complete=function(_,cb)
              cb({items={{label='block',insertText='block\n  ${1:value}\n$0',insertTextFormat=2,insertTextMode=mode}}})
            end}}})
          vim.api.nvim_buf_set_lines(0,0,-1,false,{'    bl'})
          vim.api.nvim_win_set_cursor(0,{1,6})
        ]],
          vim.env.LUASNIP_PATH,
          mode
        )
        input("A<C-Space>")
        wait("return require('completion_tools')._can('accept')")
        input("<Tab>")
        wait("return vim.api.nvim_get_mode().mode=='s'")
        input("changed")
        wait("return vim.api.nvim_get_current_line():find('changed',1,true)~=nil")
        input("<Tab>!")
        wait("return vim.api.nvim_get_current_line():find('!',1,true)~=nil")
        eq(
          mode == 1 and { "    block", "  changed", "!" } or { "    block", "      changed", "    !" },
          lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)")
        )
      end)
    end
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
  test("dictionary selection resolves meanings and cancels obsolete lookups on acceptance", function()
    lua([[
      dictionary_fixture=vim.fn.tempname(); dictionary_trace=vim.fn.tempname()
      previous_dictionary_trace=vim.env.COMPLETION_DICTIONARY_TRACE
      vim.env.COMPLETION_DICTIONARY_TRACE=dictionary_trace
      vim.fn.writefile({'apple','appleSlow'},dictionary_fixture)
      require('completion_tools').setup({sources={'dictionary'},documentation={delay_ms=5},
        dictionary={files={dictionary_fixture},documentation={command=vim.fn.getcwd()..'/tests/dictionary_command.py'}}})
    ]])
    input("iapp")
    wait(
      [[local item=require('completion_tools').get_selected_item()
      return item and item.documentation and item.documentation.value:find('Meaning of apple.',1,true)~=nil]]
    )
    wait([[for _,w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then
        return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,-1,false),'\n'):find('Meaning of apple.',1,true)~=nil
      end end;return false]])
    input("<C-n>")
    wait([[return vim.fn.filereadable(dictionary_trace)==1 and #vim.fn.readfile(dictionary_trace)==2]])
    eq("appleSlow", lua("return require('completion_tools').get_selected_item().label"))
    input("<Tab>!")
    wait("return vim.api.nvim_get_current_line()=='appleSlow!'")
    vim.wait(150)
    eq(2, lua("return #vim.fn.readfile(dictionary_trace)"))
    lua([[assert(not require('completion_tools').is_menu_visible())
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        assert(vim.bo[vim.api.nvim_win_get_buf(w)].filetype~='markdown','stale definition reopened documentation')
      end
      vim.env.COMPLETION_DICTIONARY_TRACE=previous_dictionary_trace
      vim.fn.delete(dictionary_fixture);vim.fn.delete(dictionary_trace)
    ]])
  end)
  if vim.env.REAL_WORDNET == "1" then
    test("real WordNet meanings render for capitalized dictionary candidates", function()
      lua([[
        dictionary_fixture=vim.fn.tempname();vim.fn.writefile({'apple'},dictionary_fixture)
        require('completion_tools').setup({sources={'dictionary'},documentation={delay_ms=5},
          dictionary={files={dictionary_fixture}}})
      ]])
      input("iAPP")
      wait([[local item=require('completion_tools').get_selected_item()
        return item and item.label=='APPLE' and item.documentation
          and item.documentation.value:find('Overview of noun apple',1,true)~=nil]])
      wait(
        [[for _,w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='markdown' then return true end end;return false]]
      )
      input("<Tab>!")
      wait("return vim.api.nvim_get_current_line()=='APPLE!'")
      lua("vim.fn.delete(dictionary_fixture)")
    end)
  end
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
  test("Copilot accepts words and lines while retaining the remaining suggestion", function()
    copilot_cache_fixture({ "print(1)\n  local 中文 = true\n  finish()" })
    lua([[partial_events={}; vim.api.nvim_create_autocmd('User',{pattern='CompletionToolsAccept',
      callback=function(args) partial_events[#partial_events+1]=args.data end})]])
    input("<C-l>")
    wait(
      [[return vim.api.nvim_get_current_line()=='中😀 = print)' and require('completion_tools')._can('accept')]]
    )
    input("<M-l>")
    wait([[return vim.api.nvim_get_current_line()=='  )' and require('completion_tools')._can('accept')]])
    input("<C-l>")
    wait(
      [[return vim.api.nvim_get_current_line()=='  local )' and require('completion_tools')._can('accept')]]
    )
    input("<C-l>")
    wait(
      [[return vim.api.nvim_get_current_line()=='  local 中文 )' and require('completion_tools')._can('accept')]]
    )
    eq(1, lua("return cache_requests"))
    eq({ 11, 17, 23, 26 }, lua("return cache_accepted_lengths"))
    assert(lua([[return #partial_events==4 and partial_events[1].partial=='word'
      and partial_events[2].partial=='line' and partial_events[4].text=='中文 '
      and partial_events[1].item.textEdit.newText=='int' and not partial_events[1].item._copilot_uuid]]))
    input("<Tab>!")
    wait([[return vim.deep_equal(vim.api.nvim_buf_get_lines(0,0,-1,false),
      {'中😀 = print(1)','  local 中文 = true','  finish()!)','untouched'})]])
    eq({ "1:1", "1:1", "1:1", "1:1", "1:1" }, lua("return cache_accepted"))
  end)
  test("partial Copilot acceptance remains selectable without automatic preselection", function()
    copilot_cache_fixture({ "print(1)\nfinish()" }, false)
    input("<C-l>")
    wait(
      [[return vim.api.nvim_get_current_line()=='中😀 = print)' and require('completion_tools')._can('accept')]]
    )
    input("(")
    wait(
      [[return vim.api.nvim_get_current_line()=='中😀 = print()' and require('completion_tools').get_status().ready]]
    )
    input("<C-n><Tab>")
    wait(
      [[return vim.deep_equal(vim.api.nvim_buf_get_lines(0,0,-1,false),{'中😀 = print(1)','finish())','untouched'})]]
    )
    eq(1, lua("return cache_requests"))
  end)
  test("Copilot cache prunes alternatives and accepts before another debounce", function()
    copilot_cache_fixture()
    input("i")
    wait("return require('completion_tools').get_status().sources.copilot.cache_hits==1")
    eq(2, lua("return #require('completion_tools').get_items()"))
    input("ntf(")
    wait("return require('completion_tools')._can('accept') and #require('completion_tools').get_items()==1")
    eq("2)", lua("return require('completion_tools').get_selected_item().label"))
    vim.wait(220)
    eq(1, lua("return cache_requests"))
    input("<Tab>!")
    wait(
      [[return vim.deep_equal(vim.api.nvim_buf_get_lines(0,0,-1,false),{'中😀 = printf(2)','finish()!)','untouched'})]]
    )
    eq({ "1:2" }, lua("return cache_accepted"))
  end)
  test("Copilot cache miss waits for debounce and rejects old acceptance", function()
    copilot_cache_fixture()
    input("i")
    wait("return require('completion_tools').get_status().sources.copilot.cache_hits==1")
    input("X")
    wait(
      "return vim.api.nvim_get_current_line()=='中😀 = priX)' and not require('completion_tools')._can('accept')"
    )
    eq(1, lua("return cache_requests"))
    wait("return cache_requests==2 and require('completion_tools')._can('accept')")
    eq(1, lua("return require('completion_tools').get_status().sources.copilot.cache_hits"))
  end)
  test("same-snapshot refreshes share pending Copilot requests", function()
    copilot_cache_fixture()
    lua("cache_response_delay=250")
    input("X")
    wait("return cache_requests==2")
    lua([[
      require('completion_tools').show()
      vim.api.nvim_exec_autocmds('LspAttach',{buffer=0,data={client_id=999999}})
      require('completion_tools').show()
    ]])
    wait("return require('completion_tools')._can('accept')")
    eq(2, lua("return cache_requests"))
    eq(0, lua("return cache_cancellations"))
    input("Y")
    wait("return cache_requests==3")
    input("<C-e>")
    wait("return cache_cancellations==1")
    vim.wait(300)
    assert(lua("return not require('completion_tools').is_menu_visible()"))
  end)
  test("Copilot cache follows Unicode and spaces across keyword boundaries", function()
    copilot_cache_fixture({ "pr😀 中文\nfinish()" })
    input("😀 ")
    wait(
      [[return require('completion_tools')._can('accept') and require('completion_tools').get_selected_item().label=='中文']]
    )
    input("中")
    wait(
      [[return require('completion_tools').get_context().prefix=='中' and require('completion_tools')._can('accept')]]
    )
    eq(1, lua("return cache_requests"))
    input("<Tab>!")
    wait(
      [[return vim.deep_equal(vim.api.nvim_buf_get_lines(0,0,-1,false),{'中😀 = pr😀 中文','finish()!)','untouched'})]]
    )
    eq({ "1:1" }, lua("return cache_accepted"))
  end)
  test("Copilot cached punctuation does not start other providers", function()
    copilot_cache_fixture()
    lua("cache_with_other=true")
    input("i")
    wait("return cache_other_calls==1 and require('completion_tools')._can('accept')")
    input("nt(")
    wait(
      [[return require('completion_tools')._can('accept') and require('completion_tools').get_selected_item().label=='1)']]
    )
    eq(1, lua("return cache_other_calls"))
    eq(1, lua("return cache_requests"))
  end)
  for _, invalidation in ipairs({
    {
      "backspace",
      function()
        input("i<BS>i")
      end,
    },
    {
      "cursor movement",
      function()
        input("<Left>")
        wait("return not require('completion_tools').is_menu_visible()")
        input("<Right>i")
      end,
    },
    {
      "edits elsewhere on the same line",
      function()
        lua([[vim.api.nvim_buf_set_text(0,0,0,0,0,{'x'}); vim.api.nvim_buf_set_text(0,0,0,0,1,{})]])
        input("i")
      end,
    },
    {
      "edits on another line",
      function()
        lua([[vim.api.nvim_buf_set_text(0,1,0,1,0,{'x'}); vim.api.nvim_buf_set_text(0,1,0,1,1,{})]])
        input("i")
      end,
    },
    {
      "leaving and reentering insert mode",
      function()
        input("<Esc>ai")
      end,
    },
  }) do
    test("Copilot cache invalidates after " .. invalidation[1], function()
      copilot_cache_fixture()
      invalidation[2]()
      wait("return cache_requests==2 and require('completion_tools')._can('accept')")
      eq(0, lua("return require('completion_tools').get_status().sources.copilot.cache_hits"))
    end)
  end
  test("Copilot cache respects disabled eligibility", function()
    copilot_cache_fixture()
    lua("cache_allowed=false")
    input("i")
    wait(
      "return #require('completion_tools').get_items()==0 and not require('completion_tools')._can('accept')"
    )
    eq(1, lua("return cache_requests"))
    eq(0, lua("return require('completion_tools').get_status().sources.copilot.cache_hits"))
  end)
  test("Copilot provider disable discards cached results", function()
    copilot_cache_fixture()
    lua("cache_enabled=false")
    input("i")
    wait(
      "return #require('completion_tools').get_items()==0 and not require('completion_tools')._can('accept')"
    )
    lua("cache_enabled=true")
    input("n")
    wait("return cache_requests==2 and require('completion_tools')._can('accept')")
    eq(0, lua("return require('completion_tools').get_status().sources.copilot.cache_hits"))
  end)
  test("native Copilot server startup, cached UTF-16 edits and multiline acceptance", function()
    lua([[
      copilot_protocol_log=vim.fn.tempname()
      vim.api.nvim_buf_set_lines(0,0,-1,false,{'中😀 = )'})
      vim.api.nvim_win_set_cursor(0,{1,#'中😀 = '})
      require('completion_tools').setup({sources={'copilot'},
        copilot={debounce_ms=0,command={'python3','tests/fixtures/copilot_server.py',copilot_protocol_log}}})
      assert(not require('completion_tools').get_status().sources.copilot.client.running)
    ]])
    input("ipr")
    wait("return #require('completion_tools').get_items()==3", "native Copilot menu", 3000)
    eq("print(1)", lua("return require('completion_tools').get_selected_item().label"))
    assert(lua("return not package.loaded['copilot.client'] and not package.loaded['copilot.api']"))
    input("int(")
    wait(
      [[return require('completion_tools')._can('accept') and require('completion_tools').get_selected_item().label=='1)']]
    )
    vim.wait(100)
    eq(
      1,
      lua([[local count=0; for _,line in ipairs(vim.fn.readfile(copilot_protocol_log)) do
      if vim.json.decode(line).method=='getCompletionsCycling' then count=count+1 end
    end return count]])
    )
    input("<Tab>!")
    wait(
      [[return vim.deep_equal(vim.api.nvim_buf_get_lines(0,0,-1,false),{'中😀 = print(1)','print("done")!)'})]]
    )
    wait([[for _,line in ipairs(vim.fn.readfile(copilot_protocol_log)) do
      local m=vim.json.decode(line)
      if m.method=='notifyAccepted' and m.params.uuid=='candidate-1' then return true end
    end return false]])
    lua("vim.fn.delete(copilot_protocol_log)")
  end)
  test("renaming a document cancels Copilot and ignores its old URI response", function()
    lua([[
      copilot_rename_log=vim.fn.tempname()
      vim.api.nvim_buf_set_name(0,vim.fn.tempname()..'.lua')
      vim.api.nvim_buf_set_lines(0,0,-1,false,{'中😀 = '})
      vim.api.nvim_win_set_cursor(0,{1,#'中😀 = '})
      require('completion_tools').setup({sources={'copilot'},
        copilot={debounce_ms=0,command={'python3','tests/fixtures/copilot_server.py',copilot_rename_log,'0.2'}}})
    ]])
    input("Apr")
    wait(
      [[for _,line in ipairs(vim.fn.filereadable(copilot_rename_log)==1 and vim.fn.readfile(copilot_rename_log) or {}) do
      if vim.json.decode(line).method=='getCompletionsCycling' then return true end end return false]]
    )
    lua([[vim.cmd('file '..vim.fn.fnameescape(vim.fn.tempname()..'.lua'))]])
    vim.wait(300)
    assert(
      lua(
        "return not require('completion_tools').is_menu_visible() and not require('completion_tools')._can('accept')"
      )
    )
    input("<C-Space>")
    wait("return require('completion_tools')._can('accept')", "completion under new URI", 3000)
    assert(lua([[local requests={}; for _,line in ipairs(vim.fn.readfile(copilot_rename_log)) do
      local m=vim.json.decode(line)
      if m.method=='getCompletionsCycling' then requests[#requests+1]=m end
    end return #requests==2 and requests[1].params.textDocument.uri~=requests[2].params.textDocument.uri
      and requests[2].params.textDocument.uri==vim.uri_from_bufnr(0)]]))
    lua("vim.fn.delete(copilot_rename_log)")
  end)
  test("Copilot status-only pane updates without becoming a completion", function()
    lua([[
      copilot_status_log=vim.fn.tempname()
      require('completion_tools').setup({sources={'copilot'},
        copilot={debounce_ms=80,command={'python3','tests/fixtures/copilot_server.py',copilot_status_log,'0.5'}}})
      vim.api.nvim_buf_set_lines(0,0,-1,false,{'中😀 = )'})
      vim.api.nvim_win_set_cursor(0,{1,#'中😀 = '})
      function fixture_footer()
        for _,win in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='completion-tools-menu' then
            local chunks=vim.api.nvim_win_get_config(win).footer or {}
            local result={}
            for _,chunk in ipairs(chunks) do result[#result+1]=chunk[1] end
            return table.concat(result),win
          end
        end
        return ''
      end
    ]])
    input("ipr")
    wait(
      [[return fixture_footer():find(' ',1,true)~=nil and #require('completion_tools').get_items()==0]],
      "Copilot loading icon"
    )
    assert(
      lua(
        [[local c=require('completion_tools');return #c.get_items()==0 and not c.accept() and not c.select_next() and c._can('show')]]
      )
    )
    local status_win = lua("local _,win=fixture_footer();return win")
    local first_frame = lua("return fixture_footer()")
    assert(
      vim.wait(300, function()
        return lua("return fixture_footer()") ~= first_frame
      end, 5),
      "Copilot spinner did not advance while idle"
    )
    assert(lua("return #require('completion_tools').get_items()==0"))
    wait([[return vim.trim(fixture_footer())=='' and #require('completion_tools').get_items()==3]])
    eq(status_win, lua("local _,win=fixture_footer();return win"))
    local ready_frame = lua("return fixture_footer()")
    local selected_label = lua("return require('completion_tools').get_selected_item().label")
    local menu_tick = lua(
      "local _,win=fixture_footer();return vim.api.nvim_buf_get_changedtick(vim.api.nvim_win_get_buf(win))"
    )
    vim.wait(180)
    eq(ready_frame, lua("return fixture_footer()"))
    eq(selected_label, lua("return require('completion_tools').get_selected_item().label"))
    eq(
      menu_tick,
      lua(
        "local _,win=fixture_footer();return vim.api.nvim_buf_get_changedtick(vim.api.nvim_win_get_buf(win))"
      )
    )
    lua([[
      local native=vim.lsp.get_clients({name='completion-tools-copilot'})[1]
      native.handlers.didChangeStatus(nil,{kind='Warning',message='offline'})
    ]])
    wait([[return vim.trim(fixture_footer())=='']])
    input("<Esc>")
    wait("return not require('completion_tools').is_menu_visible()")
    lua([[local c=vim.lsp.get_clients({name='completion-tools-copilot'})[1]
      c.handlers.didChangeStatus(nil,{kind='Normal'})]])
    vim.wait(60)
    assert(
      not lua("return require('completion_tools').is_menu_visible()"),
      "Status event reopened hidden menu"
    )
    lua("vim.fn.delete(copilot_status_log)")
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
