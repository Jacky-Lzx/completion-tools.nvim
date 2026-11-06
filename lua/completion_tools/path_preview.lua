local M = {}
local media = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  avif = true,
  heic = true,
  bmp = true,
  tif = true,
  tiff = true,
  svg = true,
  pdf = true,
}

function M.new(opts)
  opts = vim.tbl_extend("force", { enabled = true, max_bytes = 64 * 1024, max_lines = 100 }, opts or {})
  local uv, pending, closed = vim.uv, {}, false
  local function resolve(entry, callback)
    local item = vim.deepcopy(entry.item)
    local data = item.data
    if not data or not data.path then
      callback(item)
      return
    end
    item.detail = data.path
    if not opts.enabled or data.directory then
      callback(item)
      return
    end
    local extension = data.path:match("%.([^./]+)$")
    if extension and media[extension:lower()] then
      item._path_preview = { kind = "media", path = data.path }
      callback(item)
      return
    end
    local token = {}
    pending[token] = true
    local function finish(message, preview)
      vim.schedule(function()
        if closed or not pending[token] then
          return
        end
        pending[token] = nil
        item.documentation = message and { kind = "plaintext", value = message } or nil
        item._path_preview = preview
        callback(item)
      end)
    end
    -- Never block the editor on a FIFO/device or read an entire large file.
    uv.fs_open(data.path, uv.constants.O_RDONLY + uv.constants.O_NONBLOCK, 438, function(err, fd)
      if not fd then
        finish("Cannot preview: " .. tostring(err))
        return
      end
      uv.fs_fstat(fd, function(stat_err, stat)
        if closed or not pending[token] then
          uv.fs_close(fd)
        elseif not stat or stat.type ~= "file" then
          uv.fs_close(fd)
          finish("Cannot preview: " .. tostring(stat_err or "not a regular file"))
        else
          uv.fs_read(fd, math.min(stat.size, opts.max_bytes), 0, function(read_err, text)
            uv.fs_close(fd)
            vim.schedule(function()
              if closed or not pending[token] then
                return
              end
              if not text then
                finish("Cannot preview: " .. tostring(read_err))
              elseif text:find("\0", 1, true) then
                finish("Binary file — no text preview")
              else
                local lines = vim.split(text, "\n", { plain = true })
                if lines[#lines] == "" and #lines > 1 then
                  table.remove(lines)
                end
                local truncated = stat.size > #text or #lines > opts.max_lines
                local preview = {}
                for index = 1, math.min(#lines, opts.max_lines) do
                  local line = lines[index]:gsub("\r$", "")
                  truncated = truncated or #line > 2000
                  local ending = math.min(#line, 2000)
                  while ending > 0 and (line:byte(ending + 1) or 0) >= 128 and line:byte(ending + 1) < 192 do
                    ending = ending - 1
                  end
                  local clipped = line:sub(1, ending):gsub("[\1-\8\11-\31\127]", " ")
                  -- A byte-limited read may end in the middle of a UTF-8 character.
                  clipped = clipped:gsub("[\194-\244][\128-\191]*$", function(char)
                    local first = char:byte()
                    local bytes = first < 224 and 2 or first < 240 and 3 or 4
                    return #char < bytes and "" or char
                  end)
                  preview[index] = clipped
                end
                finish(nil, {
                  kind = "text",
                  path = data.path,
                  lines = preview,
                  truncated = truncated,
                  filetype = vim.filetype.match({ filename = data.path }) or "",
                })
              end
            end)
          end)
        end
      end)
    end)
    return function()
      pending[token] = nil
    end
  end
  return {
    resolve = resolve,
    dispose = function()
      closed, pending = true, {}
    end,
  }
end

-- Borrow the documentation pane; image-tools owns conversions and terminal leases.
function M.render(preview, buf, win, current)
  local function fail(message)
    if current() then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        preview.path,
        "",
        "Preview: " .. tostring(message):gsub("[\r\n]", " "),
      })
    end
  end
  local loaded, image = pcall(require, "image_tools")
  if not loaded or type(image.render) ~= "function" then
    fail("Image/PDF preview requires image-tools.nvim with the embedded render API")
    return
  end
  local ok, view, err = pcall(image.render, {
    path = preview.path,
    buf = buf,
    win = win,
    page = 1,
    fit_pixels = true,
    is_valid = current,
    on_error = fail,
  })
  if not ok or not view then
    fail(ok and err or view)
    return
  end
  return view
end

return M
