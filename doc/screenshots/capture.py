"""Capture an actual embedded Neovim UI grid as PNG, without a desktop session.

Requires Python 3, Neovim, lua-language-server and rsvg-convert on PATH.
No candidate lists or menu layouts are manufactured by this script.
"""
import html
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
COLS, ROWS = 120, 30


def pack(value):
    if value is None:
        return b"\xc0"
    if isinstance(value, bool):
        return b"\xc3" if value else b"\xc2"
    if isinstance(value, int):
        return b"\xd3" + struct.pack(">q", value)
    if isinstance(value, str):
        data = value.encode()
        return b"\xdb" + struct.pack(">I", len(data)) + data
    if isinstance(value, (list, tuple)):
        return b"\xdd" + struct.pack(">I", len(value)) + b"".join(map(pack, value))
    if isinstance(value, dict):
        return b"\xdf" + struct.pack(">I", len(value)) + b"".join(pack(k) + pack(v) for k, v in value.items())
    raise TypeError(value)


def unpack(data, pos=0):
    def take(size):
        nonlocal pos
        end = pos + size
        if end > len(data):
            raise IndexError
        result = data[pos:end]
        pos = end
        return result

    tag = take(1)[0]
    if tag < 128:
        return tag, pos
    if tag >= 224:
        return tag - 256, pos
    if tag in (192, 194, 195):
        return {192: None, 194: False, 195: True}[tag], pos
    if tag in (202, 203):
        return struct.unpack(">f" if tag == 202 else ">d", take(4 if tag == 202 else 8))[0], pos
    if tag in (204, 205, 206, 207, 208, 209, 210, 211):
        fmt = {204: "B", 205: "H", 206: "I", 207: "Q", 208: "b", 209: "h", 210: "i", 211: "q"}[tag]
        return struct.unpack(">" + fmt, take(struct.calcsize(fmt)))[0], pos
    if 160 <= tag <= 191 or tag in (196, 197, 198, 217, 218, 219):
        size = tag - 160 if tag <= 191 else int.from_bytes(take({196: 1, 197: 2, 198: 4, 217: 1, 218: 2, 219: 4}[tag]), "big")
        raw = take(size)
        return (raw if tag in (196, 197, 198) else raw.decode()), pos
    if 144 <= tag <= 159 or tag in (220, 221):
        size = tag - 144 if tag <= 159 else int.from_bytes(take(2 if tag == 220 else 4), "big")
        result = []
        for _ in range(size):
            value, pos = unpack(data, pos)
            result.append(value)
        return result, pos
    if 128 <= tag <= 143 or tag in (222, 223):
        size = tag - 128 if tag <= 143 else int.from_bytes(take(2 if tag == 222 else 4), "big")
        result = {}
        for _ in range(size):
            key, pos = unpack(data, pos)
            value, pos = unpack(data, pos)
            result[key] = value
        return result, pos
    if tag in (199, 200, 201, 212, 213, 214, 215, 216):
        size = 2 ** (tag - 212) if tag >= 212 else int.from_bytes(take({199: 1, 200: 2, 201: 4}[tag]), "big")
        take(1)
        return take(size), pos
    raise ValueError(tag)


class UI:
    def __init__(self, temporary):
        env = dict(os.environ, XDG_STATE_HOME=temporary + "/state", XDG_CACHE_HOME=temporary + "/cache",
                   XDG_CONFIG_HOME=temporary + "/config", NVIM_LOG_FILE=temporary + "/nvim.log")
        self.child = subprocess.Popen([shutil.which("nvim"), "--embed", "-u", "NONE", "-i", "NONE", "-n"],
                                      cwd=temporary, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.buffer = b""
        self.seq = 0
        self.grid = [[[" ", 0] for _ in range(COLS)] for _ in range(ROWS)]
        self.attrs = {0: {}}
        self.colors = [0xc0caf5, 0x1a1b26, 0xc0caf5]
        self.cursor = (0, 0)

    def event(self, message):
        if message[:2] != [2, "redraw"]:
            return
        for event in message[2]:
            name = event[0]
            for args in event[1:]:
                if name == "default_colors_set":
                    self.colors = args[:3]
                elif name == "hl_attr_define":
                    self.attrs[args[0]] = args[1]
                elif name == "grid_resize":
                    assert args == [1, COLS, ROWS], args
                elif name == "grid_clear":
                    self.grid = [[[" ", 0] for _ in range(COLS)] for _ in range(ROWS)]
                elif name == "grid_line":
                    _, row, col, cells = args[:4]
                    attr = 0
                    for cell in cells:
                        if len(cell) > 1:
                            attr = cell[1]
                        for _ in range(cell[2] if len(cell) > 2 else 1):
                            self.grid[row][col] = [cell[0], attr]
                            col += 1
                elif name == "grid_scroll":
                    _, top, bottom, left, right, rows, cols = args
                    assert cols == 0
                    old = [[cell[:] for cell in row] for row in self.grid]
                    for row in range(top, bottom):
                        for col in range(left, right):
                            self.grid[row][col] = old[row + rows][col] if top <= row + rows < bottom else [" ", 0]
                elif name == "grid_cursor_goto":
                    self.cursor = tuple(args[1:])

    def message(self, deadline):
        while time.monotonic() < deadline:
            try:
                message, used = unpack(self.buffer)
                self.buffer = self.buffer[used:]
                return message
            except IndexError:
                if select.select([self.child.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    chunk = os.read(self.child.stdout.fileno(), 1048576)
                    if not chunk:
                        raise RuntimeError("Neovim exited")
                    self.buffer += chunk
        raise TimeoutError("Neovim RPC timed out")

    def rpc(self, method, *args):
        self.seq += 1
        self.child.stdin.write(pack([0, self.seq, method, args]))
        self.child.stdin.flush()
        deadline = time.monotonic() + 20
        while True:
            message = self.message(deadline)
            if message[0] == 1 and message[1] == self.seq:
                if message[2]:
                    raise RuntimeError(message[2])
                return message[3]
            self.event(message)

    def lua(self, code):
        return self.rpc("nvim_exec_lua", code, [])

    def wait(self, code):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.lua(code):
                return
            time.sleep(0.05)
        raise TimeoutError(code + "\n" + str(self.lua("return {mode=vim.api.nvim_get_mode().mode, line=vim.api.nvim_get_current_line(), error=vim.v.errmsg, items=require('completion-tools').get_items(), clients=vim.tbl_map(function(c) return {name=c.name, initialized=c.initialized} end, vim.lsp.get_clients())}")))

    def capture(self, name):
        self.rpc("nvim_command", "redraw!")
        self.rpc("nvim_eval", "1")
        fg, bg, _ = self.colors
        color = lambda n: f"#{n:06x}"
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="720" viewBox="0 0 1440 720">',
               f'<rect width="1440" height="720" fill="{color(bg)}"/>',
               '<g font-family="Menlo, monospace" font-size="20" xml:space="preserve">']
        for row, cells in enumerate(self.grid):
            for col, (text, attr) in enumerate(cells):
                a = self.attrs.get(attr, {})
                front, back = a.get("foreground", fg), a.get("background", bg)
                if a.get("reverse"):
                    front, back = back, front
                x, y = col * 12, row * 24
                if back != bg:
                    svg.append(f'<rect x="{x}" y="{y}" width="12" height="24" fill="{color(back)}"/>')
                if text.strip():
                    style = (' font-weight="bold"' if a.get("bold") else '') + (' font-style="italic"' if a.get("italic") else '')
                    svg.append(f'<text x="{x}" y="{y + 19}" fill="{color(front)}"{style}>{html.escape(text)}</text>')
                if a.get("underline") or a.get("undercurl"):
                    svg.append(f'<path d="M{x} {y+21}h12" stroke="{color(front)}"/>')
        row, col = self.cursor
        svg.append(f'<rect x="{col*12}" y="{row*24}" width="2" height="24" fill="{color(fg)}"/></g></svg>')
        path = OUT / (name + ".png")
        subprocess.run(["rsvg-convert", "-o", str(path)], input="".join(svg).encode(), check=True,
                       env=dict(os.environ, XDG_CACHE_HOME=str(Path(tempfile.gettempdir()) / "completion-capture-cache")))
        assert any("LSP" in "".join(c[0] for c in row) for row in self.grid) if name == "completion" else True
        print(f"Captured {path.name}: {COLS}x{ROWS} Neovim UI cells")

    def close(self):
        try:
            self.lua("for _, client in ipairs(vim.lsp.get_clients()) do client:stop(true) end")
            self.child.stdin.write(pack([2, "nvim_command", ["qa!"]]))
            self.child.stdin.flush()
            self.child.wait(timeout=5)
        finally:
            if self.child.poll() is None:
                self.child.kill()
                self.child.wait()


with tempfile.TemporaryDirectory(prefix="completion-screenshots-") as temporary:
    demo = Path(temporary)
    (demo / "client.lua").write_text('''local client = {}
---@class Options
---@field timeout? integer Timeout in milliseconds (default: 5000).
---@field headers? table<string, string> Additional HTTP headers.

---Send an HTTP request and return its body.
---
---Uses a five-second timeout. Pass `opts.headers` to
---attach authentication or custom headers.
---@param url string Request URL.
---@param opts? Options Request configuration.
---@return string body Response body.
function client.request(url, opts) return "" end

---Send a request without blocking the caller.
---@param url string
---@param callback fun(body: string)
function client.request_async(url, callback) end

---Reset the connection pool.
function client.reset() end

---Retry a failed request.
---@param attempts integer
---@return boolean success
function client.retry(attempts) return true end
return client
''')
    (demo / "demo.lua").write_text('''-- A small client. A clear completion menu.
local client = require("client")

local options = {
  timeout = 3000,
  headers = { Accept = "application/json" },
}

-- Explore the API without leaving your code.
client.

''')
    ui = UI(temporary)
    try:
        ui.rpc("nvim_ui_attach", COLS, ROWS, {"rgb": True, "ext_linegrid": True})
        ui.lua(f"vim.opt.runtimepath:prepend({json.dumps(str(ROOT))}); dofile({json.dumps(str(OUT / 'theme.lua'))})")
        ui.rpc("nvim_command", "edit " + str(demo / "demo.lua"))
        ui.lua('''vim.bo.filetype = "lua"
require("completion-tools").setup({
  sources = { "lsp" },
  menu = { kind_icons = { Function = "ƒ", Field = "·", Property = "·" }, max_width = 68 },
  documentation = { delay_ms = 50, max_width = 58, max_height = 16 },
  cmdline = { enabled = true },
})
vim.lsp.start({ name = "screenshot-lua", cmd = { "lua-language-server" },
  root_dir = vim.fn.getcwd(),
  capabilities = require("completion-tools").get_lsp_capabilities(),
  settings = { Lua = { runtime = { version = "LuaJIT" },
    workspace = { checkThirdParty = false }, telemetry = { enable = false },
    completion = { callSnippet = "Disable" } } },
  handlers = { ["textDocument/publishDiagnostics"] = function() screenshot_analyzed = true end },
})''')
        ui.wait("return #vim.lsp.get_clients({bufnr=0}) > 0 and vim.lsp.get_clients({bufnr=0})[1].initialized")
        ui.wait("return screenshot_analyzed == true")
        ui.lua("vim.api.nvim_win_set_cursor(0, {10, 6})")
        ui.rpc("nvim_input", "Are")
        ui.wait("return require('completion-tools').is_menu_visible() and #(require('completion-tools').get_items()) >= 4")
        ui.wait("for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'markdown' then return true end end return false")
        ui.rpc("nvim_input", "<C-n><C-n>")
        ui.wait("return (require('completion-tools').get_selected_item() or {}).insertText == 'request'")
        ui.wait("for _,w in ipairs(vim.api.nvim_list_wins()) do local b=vim.api.nvim_win_get_buf(w); if vim.bo[b].filetype == 'markdown' and table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false), ' '):find('five%-second') then return true end end return false")
        ui.capture("completion")
        ui.rpc("nvim_input", "<Tab><Esc>:set cursor")
        ui.wait("return vim.fn.getcmdline() == 'set cursor' and require('completion-tools').is_menu_visible()")
        ui.capture("cmdline")
    finally:
        ui.close()
