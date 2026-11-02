-- Full rich-menu rendering through an attached UI, with native Lua queries.
-- Measures render work only; source, matching, input latency and terminal paint
-- are deliberately excluded. Use bench_input for the end-to-end input path.
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
local ok, err = xpcall(function()
  rpc("nvim_ui_attach", 120, 36, { rgb = true })
  lua([[
    vim.bo.filetype='lua'
    local items={}
    for i=1,50 do items[i]={label=string.format('complete%02d',i),kind=3,
      labelDetails={detail='(value, "中文", 12)',description='module'}} end
    require('completion_tools').setup({sources={'bench'},keymap={},documentation={auto_show=false},
      providers={bench={complete=function(_,cb) cb({items=items}) end}}})
  ]])
  rpc("nvim_input", "icomp")
  assert(vim.wait(2000, function()
    return lua("return require('completion_tools').is_menu_visible()")
  end, 5))
  local result = lua([[
    local cmp,ui=require('completion_tools'),require('completion_tools.ui')
    local config=require('completion_tools.config').validate({})
    local ctx,items=cmp.get_context(),{}
    for i,item in ipairs(cmp.get_items()) do items[i]={item=item,source_id='bench',start_col=0} end
    local spans=require('completion_tools.highlight').get('complete00(value, "中文", 12)',10,items[1],ctx,config.menu.highlight)
    assert(vim.tbl_contains(vim.tbl_map(function(span) return span[3] end,spans),'@string.lua'),
      'bench_menu requires the native Lua parser and highlights query')
    for i=1,100 do ui.render(items,(i-1)%50+1,ctx,config) end
    local samples={}
    for i=1,1000 do
      local start=vim.uv.hrtime()
      ui.render(items,(i-1)%50+1,ctx,config)
      samples[i]=(vim.uv.hrtime()-start)/1e6
    end
    table.sort(samples)
    return {benchmark='warm rich-menu render; attached UI; 50 candidates; 12 visible; native Lua queries',
      samples=#samples,p95_ms=samples[950],neovim=tostring(vim.version())}
  ]])
  print(vim.json.encode(result))
  if vim.env.BENCH_OUTPUT then
    vim.fn.writefile({ vim.json.encode(result) }, vim.env.BENCH_OUTPUT)
  end
end, debug.traceback)
pcall(rpc, "nvim_command", "qa!")
vim.fn.jobwait({ child }, 1000)
assert(ok, err)
vim.cmd("qa!")
