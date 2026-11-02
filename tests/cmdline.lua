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
    input("<Down>")
    wait("return require('completion_tools').get_selected_item().label=='FixtureAlpha'")
    lua([[cmd_reply({items={{label='FixtureAlphaNew',filterText='FixtureAl',sortText='00'},
      {label='FixtureAlpine',filterText='FixtureAl',sortText='20'}}})]])
    wait("return #require('completion_tools').get_items()==2")
    lua([[local c=require('completion_tools')
      assert(c.is_menu_visible() and c.get_selected_item()==nil and not c.accept())]])
    input("<Up>")
    wait("return require('completion_tools')._can('accept')")
    eq("FixtureAlpine", lua("return require('completion_tools').get_selected_item().label"))
    input("<BS>")
    wait(
      "return require('completion_tools').get_context().prefix=='FixtureA' and require('completion_tools')._can('accept')"
    )
    eq("FixtureAlpha", lua("return require('completion_tools').get_selected_item().label"))
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
