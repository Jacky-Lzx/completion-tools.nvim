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
        raise AssertionError(f"{description}: {latest}, child exit={child.poll()}")

    try:
        wait(lambda s: s["mode"] == "n", "startup")
        os.write(primary, b"i")
        wait(lambda s: s["mode"] == "i", "enter insert")
        idle_until = time.monotonic() + 0.1
        while time.monotonic() < idle_until:
            snapshot = wait(lambda s: s["mode"] == "i", "idle insert")
            assert not snapshot["visible"], "Idle insert opened a menu"
        os.write(primary, b"al")
        snapshot = wait(lambda s: s["visible"] and s.get("selected") == "alpha" and s.get("prefix") == "al",
                        "terminal menu")
        assert snapshot["menu"]["row"] + snapshot["menu"]["height"] + 1 < snapshot["input_row"], snapshot
        wait(lambda s: s.get("screen_word") == "al", "input row remains visible above the terminal menu")
        os.write(primary, b"\x0e\t!")
        wait(lambda s: s["line"] == "alphabet!" and s["mode"] == "i", "accept and continue typing")
        os.write(primary, b"\x1b")
        wait(lambda s: not s["visible"] and s["mode"] == "n", "Escape cleanup")
        assert b"alpha" in output, "Menu text was not rendered to the terminal"
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
        print("tui: idle insert stays closed; upper menu leaves input visible; selection, acceptance and Escape passed")
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        os.close(primary)
