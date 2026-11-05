-- Command-line tests need a real input loop and attached UI, not feedkeys in -l.
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
  vim.rpcnotify(child, "nvim_input", keys)
end
local function wait(code, message, ...)
  local args = { ... }
  assert(
    vim.wait(3000, function()
      return lua(code, unpack(args)) == true
    end, 5),
    (message or code)
      .. "\n"
      .. vim.inspect(lua([[return {mode=vim.api.nvim_get_mode().mode,
      line=vim.fn.getcmdline(),error=vim.v.errmsg,context=require('completion_tools').get_context()}]]))
  )
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect({ expected = a, actual = b }))
end
local count = 0
local function test(name, run)
  input("<Esc><Esc>")
  wait("return vim.api.nvim_get_mode().mode=='n'")
  lua(
    [[require('completion_tools').dispose();vim.cmd('enew!');vim.bo.filetype='lua'
    cmd_errors={};vim.notify=function(message,level) if level and level>=vim.log.levels.ERROR then table.insert(cmd_errors,message) end end]]
  )
  local ok, err = xpcall(run, debug.traceback)
  assert(ok, name .. ": " .. tostring(err))
  eq({}, lua("return cmd_errors"))
  count = count + 1
  print("cmdline: " .. name)
end
local ok, err = xpcall(function()
  rpc("nvim_ui_attach", 120, 36, { rgb = true })
  lua([[
    cmdroot=vim.fn.tempname();vim.fn.mkdir(cmdroot..'/dir space','p')
    vim.fn.writefile({},cmdroot..'/alpha beta.lua')
    vim.fn.writefile({},cmdroot..'/dir space/file name.lua')
    vim.api.nvim_create_user_command('FixtureAlpha',function() executed='alpha' end,{})
    vim.api.nvim_create_user_command('FixtureAlpine',function() executed='alpine' end,{})
  ]])
  test("idle stays closed, selection never inserts, Tab accepts and Enter executes", function()
    lua([[executed=nil;wrong_enter=false;require('completion_tools').setup({
      cmdline={enabled=true},keymap={['<CR>']={function() wrong_enter=true;return true end}}})]])
    input(":")
    wait("return vim.api.nvim_get_mode().mode=='c'")
    vim.wait(50)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    input("FixtureAl")
    wait("return require('completion_tools').is_menu_visible()")
    eq("FixtureAl", lua("return vim.fn.getcmdline()"))
    lua([[
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then
          local lines=vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,-1,false)
          assert(lines[#lines]:find('FixtureAlpha',1,true))
          assert(vim.api.nvim_win_get_cursor(w)[1]==#lines)
        end
      end
    ]])
    input("<Down>")
    wait("return require('completion_tools').get_selected_item().label=='FixtureAlpine'")
    eq("FixtureAl", lua("return vim.fn.getcmdline()"))
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='FixtureAlpine'")
    assert(lua("return executed==nil and not wrong_enter"))
    input("<CR>")
    wait("return vim.api.nvim_get_mode().mode=='n' and executed=='alpine'")
    assert(not lua("return wrong_enter or require('completion_tools').is_menu_visible()"))
  end)
  test("asynchronous updates follow automatic selection and clear missing manual selections", function()
    lua([[cmd_reply=nil;require('completion_tools').setup({cmdline={enabled=true},providers={
      cmdline={complete=function(ctx,cb)
        cmd_reply=cb
        cb({items={{label='FixtureAlpha',filterText=ctx.prefix,sortText='10'},
          {label='FixtureAlpine',filterText=ctx.prefix,sortText='20'}}})
      end}
    }})]])
    input(":FixtureAl")
    wait("return require('completion_tools')._can('accept')")
    eq("FixtureAlpha", lua("return require('completion_tools').get_selected_item().label"))
    lua([[cmd_reply({items={{label='FixtureAlphaNew',filterText='FixtureAl',sortText='00'},
      {label='FixtureAlpha',filterText='FixtureAl',sortText='10'},
      {label='FixtureAlpine',filterText='FixtureAl',sortText='20'}}})]])
    wait("return require('completion_tools').get_items()[1].label=='FixtureAlphaNew'")
    eq("FixtureAlphaNew", lua("return require('completion_tools').get_selected_item().label"))
    input("<Up>")
    wait("return require('completion_tools').get_selected_item().label=='FixtureAlpha'")
    lua([[cmd_reply({items={{label='FixtureAlphaNew',filterText='FixtureAl',sortText='00'},
      {label='FixtureAlpine',filterText='FixtureAl',sortText='20'}}})]])
    wait("return #require('completion_tools').get_items()==2")
    lua([[local c=require('completion_tools')
      assert(c.is_menu_visible() and c.get_selected_item()==nil and not c.accept())]])
    input("<Down>")
    wait("return require('completion_tools')._can('accept')")
    eq("FixtureAlpine", lua("return require('completion_tools').get_selected_item().label"))
    input("<BS>")
    wait(
      "return require('completion_tools').get_context().prefix=='FixtureA' and require('completion_tools')._can('accept')"
    )
    eq("FixtureAlpha", lua("return require('completion_tools').get_selected_item().label"))
  end)
  test("command-line shrink clears old rows immediately and paints after the delay", function()
    lua([[require('completion_tools').setup({cmdline={enabled=true},documentation={auto_show=false},
      menu={shrink_delay_ms=200},providers={cmdline={complete=function(ctx,cb)
        local items={};for i=1,(ctx.prefix=='Fixture' and 8 or 2) do
          items[i]={label=ctx.prefix..'Value'..i}
        end
        cb({items=items})
      end}}})
      function cmd_height()
        for _,w in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then
            return vim.api.nvim_win_get_height(w),w
          end
        end
      end
    ]])
    input(":Fixture")
    wait("return cmd_height()==8")
    input("A")
    wait("return #require('completion_tools').get_items()==2")
    lua([[
      local height,w=cmd_height();assert(height==8)
      local lines=vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w),0,-1,false)
      for i=1,6 do assert(lines[i]=='') end
      assert(lines[8]:find('FixtureAValue1',1,true))
    ]])
    wait("return cmd_height()==2")
    lua([[
      local _,w=cmd_height();local at=vim.fn.screenpos(w,1,1)
      local screen='';for col=at.col,at.col+vim.api.nvim_win_get_width(w)-1 do
        screen=screen..vim.fn.screenstring(at.row,col)
      end
      assert(screen:find('FixtureAValue',1,true),screen)
    ]])
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='FixtureAValue1'")
  end)
  test("Alt paging clamps at command-line candidate boundaries and consumes the keys", function()
    lua([[paging_calls=0;paging_fallback=0
      for i=1,8 do vim.api.nvim_create_user_command(string.format('FixturePaging%02d',i),function() end,{}) end
      require('completion_tools').setup({cmdline={enabled=true,keymap={
        ['<A-d>']={function(c) paging_calls=paging_calls+1;return c.select_next({count=5,wrap=false}) end,
          function() paging_fallback=paging_fallback+1 end},
        ['<A-u>']={function(c) paging_calls=paging_calls+1;return c.select_prev({count=5,wrap=false}) end,
          function() paging_fallback=paging_fallback+1 end}
      }}})]])
    input(":FixturePaging")
    wait("return require('completion_tools')._can('accept')")
    for i, step in ipairs({
      { "<A-d>", "FixturePaging01" },
      { "<A-u>", "FixturePaging06" },
      { "<A-u>", "FixturePaging08" },
      { "<A-u>", "FixturePaging08" },
      { "<A-d>", "FixturePaging03" },
      { "<A-d>", "FixturePaging01" },
      { "<A-d>", "FixturePaging01" },
    }) do
      input(step[1])
      wait(
        "return paging_calls=="
          .. i
          .. " and require('completion_tools').get_selected_item().label=='"
          .. step[2]
          .. "'"
      )
    end
    eq(0, lua("return paging_fallback"))
    eq("FixturePaging", lua("return vim.fn.getcmdline()"))
  end)
  test("fuzzy command completion is enabled by default without changing wildoptions", function()
    lua([[saved_wildoptions=vim.o.wildoptions;vim.o.wildoptions='tagfile'
      require('completion_tools').setup({cmdline={enabled=true}})]])
    input(":FxAp")
    wait("return require('completion_tools').is_menu_visible()")
    eq("FixtureAlpha", lua("return require('completion_tools').get_selected_item().label"))
    eq("tagfile", lua("return vim.o.wildoptions"))
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='FixtureAlpha'")
    eq("tagfile", lua("return vim.o.wildoptions"))
    lua("vim.o.wildoptions=saved_wildoptions")
  end)
  test("native argument boundaries preserve modifiers, no/inv prefixes and suffix", function()
    lua("require('completion_tools').setup({cmdline={enabled=true}})")
    input(":silent! keepalt set noig")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='silent! keepalt set noignorecase'")
    input("<Esc>:set invnu")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='set invnumber'")
    lua(
      [[vim.fn.setcmdline('set noig number',9);require('completion_tools').hide();require('completion_tools').show()]]
    )
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='set noignorecase number'")
  end)
  test("help tag colors stay uniform with only the query emphasized", function()
    lua("require('completion_tools').setup({cmdline={enabled=true}})")
    input(":help write-local-")
    wait("return require('completion_tools').is_menu_visible()")
    lua([[assert(require('completion_tools').get_context().completion_type=='help')
      assert(require('completion_tools').get_selected_item().label=='write-local-help')
      local seen={}
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=='completion-tools-menu' then
          for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(w),
            vim.api.nvim_create_namespace('completion-tools-menu'),0,-1,{details=true})) do
            local group=mark[4].hl_group
            assert(group:sub(1,1)~='@','help tag picked up code syntax: '..group)
            seen[group]=true
          end
        end
      end
      assert(seen.CompletionToolsKindReference and seen.CompletionToolsMatch)
    ]])
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='help write-local-help'")
  end)
  test("Lua member completion retains its namespace", function()
    lua([[require('completion_tools').setup({cmdline={enabled=true},
      sources=function() error('Insert-only source selector ran in cmdline mode') end})]])
    input(":lua vim.ap")
    wait("return require('completion_tools').is_menu_visible()")
    eq("ap", lua("return require('completion_tools').get_context().prefix"))
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='lua vim.api'")
    input("<Esc>:lua vim.api")
    wait(
      "local c=require('completion_tools');return c.get_context() and c.get_context().before=='lua vim.api' and c._can('accept')"
    )
  end)
  test("native filename matching accepts escaped spaces and wildcards", function()
    lua("require('completion_tools').setup({cmdline={enabled=true}})")
    input(":edit ")
    lua("vim.fn.setcmdline('edit '..vim.fn.fnameescape(cmdroot)..'/al')")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='edit '..vim.fn.fnameescape(cmdroot..'/alpha beta.lua')")
    lua([[local prefix='edit '..vim.fn.fnameescape(cmdroot..'/dir space')..'/fi'
      vim.fn.setcmdline(prefix..' suffix',#prefix+1)
      require('completion_tools').hide();require('completion_tools').show()]])
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait(
      "return vim.fn.getcmdline()=='edit '..vim.fn.fnameescape(cmdroot..'/dir space/file name.lua')..' suffix'"
    )
    lua("vim.fn.setcmdline('edit '..vim.fn.fnameescape(cmdroot)..'/a*.lua')")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='edit '..vim.fn.fnameescape(cmdroot..'/alpha beta.lua')")
    lua("vim.fn.setcmdline('set path='..cmdroot..'/di')")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    local ours = lua("return vim.fn.getcmdline()")
    lua("require('completion_tools').dispose();vim.fn.setcmdline('set path='..cmdroot..'/di')")
    input("<Tab>")
    wait("return vim.fn.getcmdline():find('dir',1,true)~=nil")
    eq(ours, lua("return vim.fn.getcmdline()"))
  end)
  test("custom command callbacks keep native candidate order", function()
    lua([=[
      vim.cmd([[function! CompletionFixture(lead,line,pos)
        return ['zeta','alpha']
      endfunction]])
      vim.api.nvim_create_user_command('FixtureCustom',function() end,{nargs='*',complete='customlist,CompletionFixture'})
      require('completion_tools').setup({cmdline={enabled=true}})
    ]=])
    input(":FixtureCustom ")
    wait("return require('completion_tools').is_menu_visible()")
    eq(
      { "zeta", "alpha" },
      lua("return vim.tbl_map(function(i) return i.label end,require('completion_tools').get_items())")
    )
  end)
  test("search completion preserves regexp flags and reverse-search semantics", function()
    lua([[vim.api.nvim_buf_set_lines(0,0,-1,false,{'alpha alphabet','bravo'})
      require('completion_tools').setup({sources={},cmdline={enabled=true}})]])
    input("/\\val")
    wait("return require('completion_tools').is_menu_visible()")
    eq("al", lua("return require('completion_tools').get_context().prefix"))
    input("<Down><Tab>")
    wait([[return vim.fn.getcmdline()==string.char(92)..'valphabet']])
    input("<Esc>?br")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab><CR>")
    wait("return vim.api.nvim_get_mode().mode=='n' and vim.fn.getreg('/')=='bravo'")
  end)
  test("delayed search candidates paint while typing is paused", function()
    lua([[
      vim.o.hlsearch,vim.o.incsearch=true,true
      vim.api.nvim_buf_set_lines(0,0,-1,false,{'normalized'})
      require('completion_tools').setup({sources={},cmdline={enabled=true},documentation={auto_show=false},
        providers={buffer={complete=function(_,cb)
          vim.defer_fn(function() cb({items={{label='normDeferred'}}}) end,60)
        end}}})
    ]])
    input("/norm")
    wait("return require('completion_tools').is_menu_visible()")
    wait(
      [[
      for _,win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='completion-tools-menu' then
          local p=vim.fn.screenpos(win,1,1);local text=''
          for col=p.col,p.col+vim.api.nvim_win_get_width(win)-1 do text=text..vim.fn.screenstring(p.row,col) end
          return text:find('normDeferred',1,true)~=nil
        end
      end
      return false
    ]],
      "delayed search candidate is visible without another key"
    )
  end)
  test("native search leaves menu selection, match styling and documentation colors intact", function()
    lua([[
      vim.o.hlsearch=true
      vim.api.nvim_buf_set_lines(0,0,-1,false,{'FixtureNormalized'})
      vim.fn.setreg('/','unmatched-search-pattern');vim.v.hlsearch=1
      require('completion_tools').setup({cmdline={enabled=true},documentation={auto_show=false},
        providers={cmdline={complete=function(_,cb)
          cb({items={{label='FixtureNormalized',documentation='FixtureNormalized documentation'},
            {label='FixtureNormalizer'}}})
        end}}})
      function fixture_colors()
        vim.cmd.redraw()
        local result={}
        for _,win in ipairs(vim.api.nvim_list_wins()) do
          local buf=vim.api.nvim_win_get_buf(win)
          local ft=vim.bo[buf].filetype
          if ft=='completion-tools-menu' or ft=='markdown' then
            local colors={}
            for row,line in ipairs(vim.api.nvim_buf_get_lines(buf,0,-1,false)) do
              local start=line:find('FixtureNorm',1,true)
              if start then
                for col=start,start+#'FixtureNorm'-1 do
                  local p=vim.fn.screenpos(win,row,col)
                  colors[#colors+1]=vim.fn.screenattr(p.row,p.col)
                end
              end
            end
            if #colors>0 then result[ft]=colors end
          end
        end
        return result
      end
    ]])
    input(":FixtureNorm")
    wait("return require('completion_tools').is_menu_visible()")
    lua("assert(require('completion_tools').show_documentation())")
    wait("return fixture_colors().markdown~=nil")
    local before = lua("return fixture_colors()")
    assert(before["completion-tools-menu"] and before.markdown)
    local source = lua("local p=vim.fn.screenpos(0,1,1);return vim.fn.screenattr(p.row,p.col)")
    lua("vim.fn.setreg('/','FixtureNorm');vim.v.hlsearch=1")
    eq(before, lua("return fixture_colors()"))
    assert(
      source ~= lua("local p=vim.fn.screenpos(0,1,1);return vim.fn.screenattr(p.row,p.col)"),
      "fixture did not enable native source search highlighting"
    )
  end)
  test("shell commands and input prompts preserve previous command-line mappings", function()
    lua([[
      fallback_hits=0
      vim.keymap.set('c','<C-Space>',function() fallback_hits=fallback_hits+1 end)
      original_getcompletion=vim.fn.getcompletion;lookup_count=0
      vim.fn.getcompletion=function(...) lookup_count=lookup_count+1;return original_getcompletion(...) end
      require('completion_tools').setup({cmdline={enabled=true}})
    ]])
    input(":silent !echo hello")
    wait("return vim.fn.getcmdline()=='silent !echo hello'")
    vim.wait(40)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    eq(0, lua("return lookup_count"))
    input("<C-Space>")
    wait("return fallback_hits==1")
    input("<Esc>")
    wait("return vim.api.nvim_get_mode().mode=='n'")
    vim.rpcnotify(child, "nvim_exec_lua", "prompt_value=vim.fn.input('Name: ')", {})
    wait("return vim.fn.getcmdtype()=='@'")
    input("typed<C-Space><CR>")
    wait("return prompt_value=='typed' and fallback_hits==2")
    lua(
      "vim.fn.getcompletion=original_getcompletion;require('completion_tools').dispose();vim.keymap.del('c','<C-Space>')"
    )
  end)
  test("manual trigger, type filtering and command-line keymap restoration", function()
    lua([[require('completion_tools').setup({cmdline={enabled=true,auto_show=false,types={':'}}})]])
    input(":set nu")
    wait("return vim.fn.getcmdline()=='set nu'")
    vim.wait(30)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    input("<C-Space>")
    wait("return require('completion_tools').is_menu_visible()")
    input("<Tab>")
    wait("return vim.fn.getcmdline()=='set number'")
    input("<Esc>/al")
    wait("return vim.fn.getcmdline()=='al'")
    vim.wait(30)
    assert(not lua("return require('completion_tools').is_menu_visible()"))
    input("<Esc>")
    wait("return vim.api.nvim_get_mode().mode=='n'")
    lua([[require('completion_tools').dispose();vim.keymap.set('c','<Tab>','old-tab',{desc='original-tab'})
      require('completion_tools').setup({cmdline={enabled=true}});require('completion_tools').dispose()
      assert(vim.fn.maparg('<Tab>','c',false,true).desc=='original-tab');vim.keymap.del('c','<Tab>')
      require('completion_tools').setup({cmdline={enabled=true,keymap={}}})
      assert(vim.fn.maparg('<Tab>','c')=='')
    ]])
  end)
  if vim.env.INPUT_TOOLS_PATH then
    test("external command frame, upper/lower placement and resize never overlap input", function()
      for _, row in ipairs({ 3, 29 }) do
        lua(
          [[
          local path,row=...
          vim.opt.runtimepath:prepend(path)
          require('input-tools').setup({window={row=row}})
          require('completion_tools').setup({cmdline={enabled=true,get_anchor=function()
            local box=require('input-tools').get_layout()
            return box and {row=box.row,col=box.col,height=box.outer_height}
          end}})
          vim.api.nvim_create_autocmd('User',{group=vim.api.nvim_create_augroup('CompletionCmdlineFixture',{clear=true}),
            pattern={'InputToolsOpen','InputToolsLayoutChanged','InputToolsClose'},
            callback=function() require('completion_tools').refresh_cmdline() end})
        ]],
          vim.env.INPUT_TOOLS_PATH,
          row
        )
        input(":set ")
        wait(
          "return require('completion_tools').is_menu_visible() and require('input-tools').get_layout()~=nil"
        )
        local check = [[
          local box=require('input-tools').get_layout()
          for _,win in ipairs(vim.api.nvim_list_wins()) do
            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='completion-tools-menu' then
              local wc=vim.api.nvim_win_get_config(win)
              assert(wc.col==box.col)
              assert(wc.row>=box.row+box.outer_height or wc.row+wc.height+2<=box.row,vim.inspect({menu=wc,input=box}))
              assert(wc.row+wc.height+2<=vim.o.lines)
              vim.cmd.redraw()
              local p=vim.fn.screenpos(box.win,1,1);local line=''
              for col=p.col,p.col+box.width-1 do line=line..vim.fn.screenstring(p.row,col) end
              assert(line:find('set ',1,true),line)
              return true
            end
          end
          return false
        ]]
        wait(check)
        rpc("nvim_ui_try_resize", 100, 34)
        wait(check, "external menu after resize")
        local accepted = lua("return 'set '..require('completion_tools').get_selected_item().label")
        input("<Tab>")
        wait("return vim.fn.getcmdline()==...", "accepted native command line", accepted)
        wait(
          [[
          local box=require('input-tools').get_layout()
          if not box then return false end
          local expected=...
          if not table.concat(vim.api.nvim_buf_get_lines(box.buf,0,-1,false),'\n'):find(expected,1,true) then return false end
          local p=vim.fn.screenpos(box.win,1,1);local screen=''
          for col=p.col,p.col+box.width-1 do screen=screen..vim.fn.screenstring(p.row,col) end
          return screen:find(expected,1,true)~=nil and not require('completion_tools').is_menu_visible()
        ]],
          "accepted command is visible without another key",
          accepted
        )
        input("<Esc>")
        wait("return vim.api.nvim_get_mode().mode=='n' and not require('completion_tools').is_menu_visible()")
        lua("require('input-tools').teardown();vim.api.nvim_del_augroup_by_name('CompletionCmdlineFixture')")
        rpc("nvim_ui_try_resize", 120, 36)
      end
    end)
  end
end, debug.traceback)
pcall(lua, "vim.fn.delete(cmdroot,'rf')")
pcall(rpc, "nvim_command", "qa!")
vim.fn.jobwait({ child }, 1000)
assert(ok, err)
print("cmdline: " .. count .. " attached-UI cases passed")
vim.cmd("qa!")
