"""Exercise a real terminal without a Python Neovim or terminal dependency."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="completion-tools-tui-") as temporary:
    state = Path(temporary) / "state.json"
    env = dict(os.environ, TERM="xterm-256color", COMPLETION_TUI_STATE=str(state),
               XDG_CONFIG_HOME=temporary + "/config",
               XDG_STATE_HOME=temporary + "/state", XDG_CACHE_HOME=temporary + "/cache",
               NVIM_LOG_FILE=temporary + "/nvim.log")
    primary, secondary = pty.openpty()
    fcntl.ioctl(secondary, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 120, 0, 0))
    child = subprocess.Popen([os.environ.get("NVIM", shutil.which("nvim")), "-u", "tests/tui_init.lua",
                              "-i", "NONE", "-n"], cwd=root, env=env,
                             stdin=secondary, stdout=secondary, stderr=secondary, start_new_session=True)
    os.close(secondary)
    output = bytearray()

    def wait(predicate, description):
        deadline = time.monotonic() + 4
        latest = None
        while time.monotonic() < deadline:
            if select.select([primary], [], [], 0.01)[0]:
                try:
                    output.extend(os.read(primary, 65536))
                except OSError:
                    break
            try:
                latest = json.loads(state.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                continue
            if predicate(latest):
                return latest
        raise AssertionError(f"{description}: {latest}, child exit={child.poll()}, terminal tail={output[-1600:]!r}")

    try:
        wait(lambda s: s["mode"] == "n", "startup")
        os.write(primary, b"i")
        wait(lambda s: s["mode"] == "i", "enter insert")
        idle_until = time.monotonic() + 0.1
        while time.monotonic() < idle_until:
            snapshot = wait(lambda s: s["mode"] == "i", "idle insert")
            assert not snapshot["visible"], "Idle insert opened a menu"
        os.write(primary, b"al")
        snapshot = wait(lambda s: s["visible"] and s.get("selected") == "alpha" and s.get("prefix") == "al"
                        and "Buffer" in s.get("menu_screen", "") and "Text" in s.get("menu_screen", ""),
                        "terminal menu")
        assert snapshot["menu"]["row"] + snapshot["menu"]["height"] + 1 < snapshot["input_row"], snapshot
        wait(lambda s: s.get("screen_word") == "al", "input row remains visible above the terminal menu")
        attrs = snapshot["menu_attrs"]
        assert "Text" in snapshot["menu_screen"] and "Buffer" in snapshot["menu_screen"], snapshot
        assert attrs["alpha"] != attrs["pha"] == attrs["Text"], snapshot
        assert b"38;2;160;160;160" in output, "Text candidates must use gray"
        os.write(primary, b"\x0e\t!")
        wait(lambda s: s["line"] == "alphabet!" and s["mode"] == "i", "accept and continue typing")
        os.write(primary, b"\x1b")
        wait(lambda s: not s["visible"] and s["mode"] == "n", "Escape cleanup")
        assert b"alpha" in output, "Menu text was not rendered to the terminal"
        os.write(primary, b":lua completion_tui_flicker()\r")
        wait(lambda s: s["mode"] == "n" and s["line"] == "", "flicker fixture")
        os.write(primary, b"ia")
        snapshot = wait(lambda s: s.get("flicker") and s["flicker"]["samples"] > 0, "initial ready frame")
        window = snapshot["menu"]["win"]
        prefix = "a"
        for char in "bcdef":
            prefix += char
            os.write(primary, char.encode())
            snapshot = wait(lambda s: s.get("prefix") == prefix and not s["can_accept"], "pending replacement")
            assert snapshot["visible"] and snapshot["menu"]["win"] == window, snapshot
        wait(lambda s: s["can_accept"], "latest ready result")
        os.write(primary, b"\x7f")
        snapshot = wait(lambda s: s.get("prefix") == "abcde" and not s["can_accept"], "pending backspace")
        snapshot = wait(lambda s: s["can_accept"], "ready after backspace")
        stats = snapshot["flicker"]
        assert stats["samples"] >= 6 and stats["hidden"] == stats["blank"] == stats["closed"] == 0, snapshot
        os.write(primary, b"\x1b")
        wait(lambda s: s["mode"] == "n" and not s["visible"], "flicker fixture cleanup")
        os.write(primary, b":lua completion_tui_selection()\r")
        wait(lambda s: s["mode"] == "n" and s["line"] == "", "selection fixture")
        os.write(primary, b"ial")
        snapshot = wait(lambda s: s.get("selected") == "alpha", "fast automatic selection")
        window = snapshot["menu"]["win"]
        snapshot = wait(lambda s: s.get("first") == "alphaLsp" and s.get("selected") == "alphaLsp",
                        "automatic selection follows slow-source ranking")
        assert snapshot["menu"]["win"] == window, snapshot
        os.write(primary, b"\t!\x1b")
        wait(lambda s: s["mode"] == "n" and s["line"] == "alphaLsp!", "accept latest first candidate")
        os.write(primary, b":lua completion_tui_selection()\r")
        wait(lambda s: s["mode"] == "n" and s["line"] == "", "manual selection fixture")
        os.write(primary, b"ial")
        wait(lambda s: s.get("selected") == "alpha", "fast ready candidate")
        os.write(primary, b"\x0e")
        wait(lambda s: s.get("selected") == "alphaZ", "explicit candidate navigation")
        wait(lambda s: s.get("first") == "alphaLsp" and s.get("selected") == "alphaZ",
             "manual selection survives slow-source ranking")
        os.write(primary, b"p")
        wait(lambda s: s.get("prefix") == "alp" and s["can_accept"] and s.get("selected") == "alpha",
             "typing resets manual selection")
        wait(lambda s: s.get("first") == "alphaLsp" and s.get("selected") == "alphaLsp",
             "new query follows latest ranking")
        os.write(primary, b"\x1b")
        wait(lambda s: s["mode"] == "n" and not s["visible"], "selection fixture cleanup")
        os.write(primary, b":lua completion_tui_paging()\r")
        wait(lambda s: s["mode"] == "n" and s["line"] == "" and s.get("paging_calls") == 0,
             "paging fixture")
        calls = 0
        for trigger, stem in ((b"ial", "alpha"), (b":CompletionPaging", "CompletionPaging")):
            os.write(primary, trigger)
            wait(lambda s: s.get("selected") == stem + "01", "initial paging candidate")
            for key, index in ((b"\x1bd", 6), (b"\x1bd", 8), (b"\x1bd", 8),
                               (b"\x1bu", 3), (b"\x1bu", 1), (b"\x1bu", 1)):
                os.write(primary, key)
                calls += 1
                wait(lambda s: s.get("paging_calls") == calls and s.get("selected") == f"{stem}{index:02d}",
                     "Alt paging stops at list boundaries")
            os.write(primary, b"\x1b")
            wait(lambda s: s["mode"] == "n" and not s["visible"], "paging cleanup")
        os.write(primary, b":lua completion_tui_semantic()\r")
        wait(lambda s: s["line"] == "" and s["mode"] == "n", "semantic fixture")
        os.write(primary, b"ide")
        snapshot = wait(lambda s: s["visible"] and "decode(value: string): number" in s.get("menu_screen", ""),
                        "semantic terminal menu")
        assert "Function" in snapshot["menu_screen"], snapshot
        attrs = snapshot["menu_attrs"]
        assert attrs["decode"] != attrs["code"] != attrs["string"], snapshot
        rgb_colors = (b"38;2;239;69;69", b"38;2;52;211;153", b"48;2;18;52;86")
        wait(lambda s: all(rgb in output for rgb in rgb_colors), "terminal RGB highlights flushed")
        os.write(primary, b"\t!\x1b")
        wait(lambda s: s["line"] == "decode!" and s["mode"] == "n" and not s["visible"],
             "display-only signature acceptance")
        os.write(primary, b":lua completion_tui_snippet()\r")
        wait(lambda s: s["line"] == "" and s["mode"] == "n", "snippet fixture")
        os.write(primary, b"iign")
        snapshot = wait(lambda s: s["visible"] and "\\input" in s.get("doc_screen", ""),
                        "snippet menu and code documentation")
        assert "Snippet" in snapshot["menu_screen"], snapshot
        attrs = snapshot["menu_attrs"]
        assert attrs["ignore"] != attrs["ore"] == attrs["Snippet"], snapshot
        assert "`" not in snapshot["doc_screen"] and "Use path." in snapshot["doc_screen"], snapshot
        for rgb in (b"38;2;198;120;221", b"38;2;86;182;194"):
            assert rgb in output, f"Missing snippet/documentation RGB highlight {rgb!r}"
        os.write(primary, b"\t!\x1b")
        wait(lambda s: s["line"] == "ignore!" and s["mode"] == "n" and not s["visible"],
             "snippet candidate acceptance")
        os.write(primary, b":lua completion_tui_dictionary()\r")
        wait(lambda s: s["line"] == "" and s["mode"] == "n", "dictionary fixture")
        os.write(primary, b"iAPP")
        wait(lambda s: s.get("selected") == "APPLE" and "Meaning of apple." in s.get("doc_screen", ""),
             "dictionary meaning rendered in the terminal")
        os.write(primary, b"\t!\x1b")
        wait(lambda s: s["line"] == "APPLE!" and s["mode"] == "n" and not s["visible"],
             "dictionary meaning is display-only")
        os.write(primary, b":lua completion_tui_cmdline()\r")
        wait(lambda s: s["mode"] == "n", "command-line setup")
        os.write(primary, b":help CompletionTui")
        snapshot = wait(lambda s: s.get("selected") == "CompletionTui-local-Help"
                        and "CompletionTui-local-Help" in s.get("menu_screen", "")
                        and s.get("menu_attrs", {}).get("local", 0) != 0,
                        "literal help tag colors in the terminal")
        attrs = snapshot["menu_attrs"]
        assert attrs["local"] == attrs["-"] == attrs["Help"] == attrs["Reference"], snapshot
        assert attrs["CompletionTui"] != attrs["local"], snapshot
        os.write(primary, b"\x1b")
        wait(lambda s: s["mode"] == "n" and not s["visible"], "help completion cleanup")
        os.write(primary, b":")
        snapshot = wait(lambda s: s["mode"] == "c" and s["cmdline"] == "", "idle command line")
        assert not snapshot["visible"], snapshot
        os.write(primary, b"CompletionTui")
        snapshot = wait(lambda s: s["visible"] and s.get("selected") == "CompletionTuiAlpha",
                        "terminal command menu")
        assert snapshot["menu"]["row"] + snapshot["menu"]["height"] + 1 < snapshot["input_row"], snapshot
        os.write(primary, b"\x0e")
        snapshot = wait(lambda s: s.get("selected") == "CompletionTuiAlpine", "command selection")
        assert snapshot["cmdline"] == "CompletionTui", snapshot
        os.write(primary, b"\t")
        snapshot = wait(lambda s: s["cmdline"] == "CompletionTuiAlpine"
                        and "CompletionTuiAlpine" in s.get("cmdline_screen", ""),
                        "accepted command is immediately visible")
        assert snapshot["mode"] == "c" and not snapshot.get("executed"), snapshot
        os.write(primary, b"\r")
        wait(lambda s: s["mode"] == "n" and s.get("executed") == "alpine" and not s["visible"],
             "native Enter executes accepted command")
        os.write(primary, b":qa!\r")
        deadline = time.monotonic() + 4
        while child.poll() is None and time.monotonic() < deadline:
            if select.select([primary], [], [], 0.02)[0]:
                try:
                    output.extend(os.read(primary, 65536))
                except OSError:
                    break
        if child.poll() is None:
            raise AssertionError(f"quit timed out: {state.read_text()}, terminal tail={output[-1800:]!r}")
        assert child.returncode == 0
        print("tui: async selection, continuous typing/backspace, highlights, dictionary meanings and command-line acceptance passed")
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        os.close(primary)
