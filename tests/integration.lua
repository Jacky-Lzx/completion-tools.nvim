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
