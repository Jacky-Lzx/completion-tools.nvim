"""Exercise a real terminal without a Python Neovim or terminal dependency."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
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
        assert snapshot["menu"]["cursor"] == snapshot["menu"]["height"], snapshot
        assert "alpha" in snapshot["menu_rows"][-1] and "alphanumeric" in snapshot["menu_rows"][0], snapshot
        wait(lambda s: s.get("screen_word") == "al", "input row remains visible above the terminal menu")
        attrs = snapshot["menu_attrs"]
        assert "Text" in snapshot["menu_screen"] and "Buffer" in snapshot["menu_screen"], snapshot
        assert attrs["alpha"] != attrs["pha"] == attrs["Text"], snapshot
        assert b"38;2;160;160;160" in output, "Text candidates must use gray"
        os.write(primary, b"\x10")
        moved = wait(lambda s: s.get("selected") == "alphabet", "Ctrl-P moves up in the reversed menu")
        assert moved["menu"]["cursor"] == snapshot["menu"]["cursor"] - 1, moved
        os.write(primary, b"\t!")
        wait(lambda s: s["line"] == "alphabet!" and s["mode"] == "i", "accept and continue typing")
        os.write(primary, b"\x1b")
        wait(lambda s: not s["visible"] and s["mode"] == "n", "Escape cleanup")
        # Match highlighting can split the label across terminal escape sequences.
        assert "alpha" in snapshot["menu_screen"], "Menu text was not rendered to the terminal"
        os.write(primary, b":lua completion_tui_triggers()\r")
        wait(lambda s: s["mode"] == "n" and s["line"] == "", "symbol trigger fixture")
        os.write(primary, b"ia")
        wait(lambda s: s["visible"], "word completion before punctuation")
        for char in (" ", "(", ")", "[", "]", "{", "}", ",", ";", ":", "/", "\\", "，", "。"):
            os.write(primary, char.encode())
            wait(lambda s: s["line"] == "a" + char and not s["visible"], "symbol closes terminal menu")
            # Wait beyond a frame to catch a delayed automatic reopen.
            until = time.monotonic() + 0.06
            while time.monotonic() < until:
                snapshot = wait(lambda s: s["line"] == "a" + char, "blocked symbol remains inserted")
                assert not snapshot["visible"], snapshot
            os.write(primary, b"\x7f")
            wait(lambda s: s["line"] == "a" and s["visible"], "backspace restores word completion")
        os.write(primary, b".")
        wait(lambda s: s["line"] == "a." and s["visible"], "dot opens terminal menu")
        os.write(primary, b"(")
        wait(lambda s: s["line"] == "a.(" and not s["visible"], "bracket closes dot completion")
        os.write(primary, b"\x00")
        wait(lambda s: s["line"] == "a.(" and s["visible"], "manual completion after a blocked symbol")
        os.write(primary, b"\x1b:lua vim.bo.filetype='tex'\rA{")
        wait(lambda s: s["line"] == "a.({" and s["visible"], "filetype-specific brace trigger")
        os.write(primary, b" \x1b")
        wait(lambda s: s["mode"] == "n" and not s["visible"], "symbol trigger cleanup")
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
        os.write(primary, b":lua completion_tui_height()\r")
        wait(lambda s: s["mode"] == "n" and s["line"] == "", "height fixture")
        os.write(primary, b"ia")
        snapshot = wait(lambda s: s.get("prefix") == "a" and s.get("menu", {}).get("height") == 12,
                        "initial tall menu")
        window = snapshot["menu"]["win"]
        assert snapshot["menu"]["row"] < snapshot["input_row"], snapshot
        prefix = "a"
        steps = []
        for char in b"bcdefgh":
            prefix += chr(char)
            steps.append((bytes([char]), prefix))
        steps.extend([(b"\x7f", "abcdefg"), (b"h", "abcdefgh")])
        for key, expected in steps:
            os.write(primary, key)
            snapshot = wait(lambda s: s.get("prefix") == expected and s["can_accept"]
                            and expected + "Fast" in s.get("menu_screen", ""), "fresh contents while typing")
            deadline = time.monotonic() + 0.045
            while time.monotonic() < deadline:
                snapshot = wait(lambda s: s.get("prefix") == expected, "continuous height sampling")
                assert snapshot["menu"]["win"] == window and snapshot["menu"]["height"] == 12, snapshot
                assert snapshot["menu"]["row"] < snapshot["input_row"], snapshot
                if expected + "Slow" not in "".join(snapshot["menu_rows"]):
                    assert all(row == "" for row in snapshot["menu_rows"][:-2]), snapshot
                    assert not snapshot["menu_blank_screen"].strip(), snapshot
        snapshot = wait(lambda s: s.get("menu", {}).get("height") == 2, "height shrinks after quiet input")
        assert snapshot["menu"]["win"] == window and snapshot["menu"]["row"] < snapshot["input_row"], snapshot
        os.write(primary, b"\x0e\t!\x1b")
        wait(lambda s: s["mode"] == "n" and s["line"] == "abcdefghFast2!" and not s["visible"],
             "accept current candidate after delayed shrink")
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
            steps = (((b"\x1bd", 1), (b"\x1bu", 6), (b"\x1bu", 8), (b"\x1bu", 8),
                      (b"\x1bd", 3), (b"\x1bd", 1), (b"\x1bd", 1))
                     if trigger.startswith(b":") else
                     ((b"\x1bd", 6), (b"\x1bd", 8), (b"\x1bd", 8),
                      (b"\x1bu", 3), (b"\x1bu", 1), (b"\x1bu", 1)))
            for key, index in steps:
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
        assert "*" not in snapshot["doc_screen"] and "---" not in snapshot["doc_screen"], snapshot
        assert "@param path" in snapshot["doc_screen"] and "──" in snapshot["doc_screen"], snapshot
        assert any(b"3" in codes.split(b";") for codes in re.findall(rb"\x1b\[([0-9;]*)m", output)), \
            "Markdown italics were not emitted to the terminal"
        for rgb in (b"38;2;198;120;221", b"38;2;86;182;194"):
            assert rgb in output, f"Missing snippet/documentation RGB highlight {rgb!r}"
        os.write(primary, b"\t!\x1b")
        wait(lambda s: s["line"] == "ignore!" and s["mode"] == "n" and not s["visible"],
             "snippet candidate acceptance")
        os.write(primary, b":lua completion_tui_files()\r")
        wait(lambda s: s["line"] == "" and s["mode"] == "n", "file fixture")
        os.write(primary, b"iTe")
        path = "/Users/test/Research/Papers/Very_Long_Project/TeX/0_Abstract.tex"
        snapshot = wait(lambda s: s.get("doc_lines") == [path]
                        and "0_Abstract.tex" in s.get("menu_screen", "")
                        and path in s.get("doc_screen", "").replace("\n", "").replace(" ", ""),
                        "file path detail painted on screen")
        assert "TeX/4_Experimental_Results.tex" in snapshot["menu_rows"][1], snapshot
        assert "…" in snapshot["menu_screen"], snapshot
        attrs = snapshot["menu_attrs"]
        assert attrs["Abstract"] == attrs[".tex"], snapshot
        assert snapshot["menu_source_attrs"][0] != attrs["Abstract"], snapshot
        assert path in snapshot["doc_screen"].replace("\n", "").replace(" ", ""), snapshot
        os.write(primary, b"\x0e")
        path = "/Users/test/Research/Papers/Very_Long_Project/TeX/4_Experimental_Results.tex"
        wait(lambda s: s.get("selected") == "TeX/4_Experimental_Results.tex"
             and s.get("doc_lines") == [path], "labelDetails metadata remains complete after selection")
        fcntl.ioctl(primary, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 90, 0, 0))
        child.send_signal(signal.SIGWINCH)
        # Resizing intentionally dismisses completion; reopen at the new width.
        wait(lambda s: s.get("columns") == 90 and not s["visible"], "terminal resized")
        os.write(primary, b"\x00")
        wait(lambda s: s.get("selected") == "TeX/0_Abstract.tex", "reopen after resize")
        os.write(primary, b"\x0e")
        wait(lambda s: s.get("columns") == 90 and s.get("doc_lines") == [path]
             and "Results.tex" in s.get("menu_rows", [""])[1],
             "narrow terminal keeps the distinguishing path suffix")
        os.write(primary, b"\t!\x1b")
        wait(lambda s: s["line"] == "TeX/4_Experimental_Results.tex!" and s["mode"] == "n",
             "file metadata does not enter accepted text")
        fcntl.ioctl(primary, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 120, 0, 0))
        child.send_signal(signal.SIGWINCH)
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
        os.write(primary, b":lua completion_tui_copilot()\r")
        wait(lambda s: s["mode"] == "n" and s.get("copilot", {}).get("requests") == 0,
             "Copilot fixture")
        os.write(primary, b"ipr")
        wait(lambda s: s.get("copilot", {}).get("requests") == 1, "initial Copilot request")
        os.write(primary, b"i")
        snapshot = wait(lambda s: s.get("selected") == 'print("fresh")'
                        and "Copilot" in s.get("menu_screen", "")
                        and s.get("copilot", {}).get("cancelled") == 1,
                        "latest Copilot suggestion after cancelling old request")
        rows = [row for row in snapshot["menu_rows"] if "Copilot" in row]
        assert len(rows) == 3 and all("print_more" not in row for row in rows), snapshot
        assert len(snapshot["copilot_marks"]) == 3 and all(
            count == 4 for count in snapshot["copilot_marks"].values()), snapshot
        wait(lambda s: b"38;2;203;166;247" in output, "purple Copilot RGB emitted to terminal")
        os.write(primary, b"\x0e")
        wait(lambda s: s.get("selected") == 'printf("fresh")', "Copilot candidate navigation")
        # The cancelled response deliberately arrives late; it must not replace selection.
        until = time.monotonic() + 0.35
        while time.monotonic() < until:
            snapshot = wait(lambda s: s.get("selected") == 'printf("fresh")', "late Copilot reply ignored")
            assert "stale" not in snapshot.get("menu_screen", ""), snapshot
        os.write(primary, b"\t!\x1b")
        snapshot = wait(lambda s: s["mode"] == "n" and s.get("lines") ==
                        ['中😀 = printf("fresh")', 'print("$1")!)'],
                        "Unicode multiline Copilot acceptance and continued typing")
        assert snapshot["copilot"]["accepted"] == ["2:printf"], snapshot
        assert not snapshot["visible"], snapshot
        for attempt in range(5):
            os.write(primary, b":lua completion_tui_manual()\r")
            wait(lambda s: s["mode"] == "n" and s.get("manual", {}).get("calls") == 0,
                 "manual race fixture")
            # Type the punctuation and manual trigger in one terminal input batch.
            os.write(primary, b"i(\x00")
            snapshot = wait(lambda s: s["visible"] and s.get("selected") == "alpha",
                            "manual completion after blocked symbol")
            window = snapshot["menu"]["win"]
            selected = "alpha" if attempt % 2 == 0 else "alpine"
            if selected == "alpine":
                os.write(primary, b"\x0e")
                wait(lambda s: s.get("selected") == selected, "manual selection before LSP attach")
            until = time.monotonic() + 0.3
            while time.monotonic() < until:
                snapshot = wait(lambda s: s.get("manual", {}).get("calls", 0) > 0, "sample manual session")
                assert snapshot["visible"] and snapshot["menu"]["win"] == window, snapshot
                assert snapshot.get("selected") == selected, snapshot
            assert snapshot["manual"]["calls"] == 2 and snapshot["can_accept"], snapshot
            os.write(primary, b"\t!\x1b")
            wait(lambda s: s["mode"] == "n" and s["line"] == "(" + selected + "!" and not s["visible"],
                 "accept refreshed manual candidate and continue typing")
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
        print("tui: stable height, async selection, continuous input, highlights, dictionary, command-line and Copilot multiline acceptance passed")
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        os.close(primary)
