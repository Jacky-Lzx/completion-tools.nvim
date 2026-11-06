local M = {}

function M.new(opts)
  local uv, cache, closed = vim.uv, {}, false
  local preview = require("completion_tools.path_preview").new(opts.preview)
  local source = { score_offset = 30, resolve = preview.resolve, resolve_on_accept = false }
  function source.complete(ctx, callback)
    -- Whitespace and quoting delimit paths; slash is required to avoid probing
    -- the filesystem for every ordinary identifier.
    local token = ctx.before:match("([^%s\"'`<>|]+)$") or ""
    local directory, name = token:match("^(.*[/\\])([^/\\]*)$")
    if not directory then
      callback({ items = {} })
      return
    end
    if directory:find("://", 1, true) then
      callback({ items = {} })
      return
    end
    local cwd = opts.get_cwd and opts.get_cwd(ctx)
      or (vim.api.nvim_buf_get_name(ctx.bufnr):match("^(.*)/") or vim.fn.getcwd())
    local expanded = directory:gsub("^~/", (vim.uv.os_homedir() or "~") .. "/")
    if expanded:sub(1, 1) ~= "/" then
      expanded = cwd .. "/" .. expanded
    end
    local start_col = ctx.col - #name
    local cancelled = false
    local function deliver(items)
      if not cancelled and not closed then
        local visible = {}
        for _, item in ipairs(items) do
          if opts.show_hidden or name:sub(1, 1) == "." or item.label:sub(1, 1) ~= "." then
            visible[#visible + 1] = item
          end
        end
        callback({ items = visible, start_col = start_col })
      end
    end
    local entry = cache[expanded]
    if entry and uv.now() - entry.time < opts.cache_ms then
      deliver(entry.items)
      return
    end
    -- opendir/readdir are asynchronous (unlike fs_scandir_next's synchronous
    -- consumption). Read in small batches even for very large directories.
    local handle, items, total = nil, {}, 0
    local function finish()
      if handle then
        uv.fs_closedir(handle, function() end)
        handle = nil
      end
      if cancelled or closed then
        return
      end
      if vim.tbl_count(cache) >= 32 then
        cache = {}
      end
      cache[expanded] = { items = items, time = uv.now() }
      deliver(items)
    end
    local read
    read = function()
      if cancelled or closed then
        finish()
        return
      end
      uv.fs_readdir(handle, function(err, entries)
        vim.schedule(function()
          if err or not entries then
            finish()
            return
          end
          for _, file in ipairs(entries) do
            total = total + 1
            if total <= opts.max_entries then
              local folder = file.type == "directory"
              items[#items + 1] = {
                label = file.name .. (folder and "/" or ""),
                kind = folder and 19 or 17,
                data = { path = expanded .. file.name, directory = folder },
              }
            end
          end
          if total >= opts.max_entries then
            finish()
          else
            read()
          end
        end)
      end)
    end
    uv.fs_opendir(expanded, function(err, dir)
      vim.schedule(function()
        if err or not dir then
          deliver({})
          return
        end
        handle = dir
        read()
      end)
    end, 128)
    return function()
      cancelled = true
    end
  end
  function source.dispose()
    closed = true
    cache = {}
    preview.dispose()
  end
  return source
end

return M
