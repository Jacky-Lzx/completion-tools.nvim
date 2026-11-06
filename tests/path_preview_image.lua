-- Optional acceptance test: real image-tools preparation/conversion and embedded
-- views, with only terminal acknowledgements simulated (no graphics terminal needed).
local image_root = vim.env.IMAGE_TOOLS_PATH
if not image_root or image_root == "" then
  print("path preview image-tools: skipped (set IMAGE_TOOLS_PATH)")
  return
end
vim.opt.runtimepath:prepend(image_root)
local commands = {}
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(command)
    commands[#commands + 1] = command
  end,
  request = function(_, command, _, callback)
    commands[#commands + 1] = command
    vim.schedule(function()
      callback(nil)
    end)
    return function() end
  end,
}
local image = require("image_tools")
image.setup({ auto_preview = false, transport = "direct" })
local views, prepared = {}, {}
local render = image.render
image.render = function(request)
  local view, err = render(request)
  assert(view, err)
  views[#views + 1] = view
  return view
end
local media = require("image_tools.media")
local prepare = media.prepare
media.prepare = function(path, opts, callback)
  return prepare(path, opts, function(err, pixels, timing)
    assert(not err, err)
    prepared[path] = { pixels = pixels, raster = opts._raster_size, page = opts.page }
    callback(err, pixels, timing)
  end)
end
local cfg = require("completion_tools.config").validate({})
local source = require("completion_tools.sources.path").new(cfg.path)
local ui = require("completion_tools.ui")
ui.highlights()
local owner = vim.api.nvim_get_current_win()
local ctx = {
  winid = owner,
  bufnr = 0,
  row = 0,
  col = 0,
  start_col = 0,
  mode = "insert",
  before = "",
  line = "",
  filetype = "lua",
}
local menu = { { item = { label = "fixture", kind = 17 }, source_id = "path", start_col = 0 } }
ui.render(menu, 1, ctx, cfg)
local function show(extension)
  local path = image_root .. "/tests/fixtures/fixture." .. extension
  local item
  source.resolve({ item = { label = "fixture." .. extension, data = { path = path } } }, function(resolved)
    item = resolved
  end)
  assert(ui.documentation(item, cfg))
  local view = views[#views]
  assert(vim.wait(10000, function()
    return view.error or view.session and view.session.stage == "ready"
  end, 5))
  assert(not view.error, view.error)
  assert(view.grid and view.width <= vim.api.nvim_win_get_width(view.win))
  assert(view.height <= vim.api.nvim_win_get_height(view.win))
  assert(#vim.api.nvim_list_wins() == 3 and vim.api.nvim_get_current_win() == owner)
  assert(image.status().terminal_cache.placements == 1)
  return view, prepared[path]
end
local png, pixels = show("png")
assert(pixels.pixels.width > 0 and pixels.pixels.height > 0 and not pixels.raster)
local pdf, raster = show("pdf")
assert(png.closed and raster.page == 1 and raster.raster.width > 0 and raster.raster.height > 0)
assert(raster.pixels.width > 0 and raster.pixels.height > 0)
ui.hide()
assert(pdf.closed and image.status().terminal_cache.placements == 0)
assert(#vim.api.nvim_list_wins() == 1 and #commands > 0)
ui.dispose()
source.dispose()
image.dispose()
print(
  "path preview image-tools: real PNG, viewport-rasterized PDF, embedded placeholders and lease cleanup passed"
)
