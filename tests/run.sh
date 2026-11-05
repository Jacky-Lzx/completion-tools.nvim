#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
export XDG_STATE_HOME="$task_tmp/state"
export XDG_CACHE_HOME="$task_tmp/cache"
export XDG_CONFIG_HOME="$task_tmp/config"
export TMPDIR="$task_tmp"
export NVIM_LOG_FILE="$task_tmp/nvim.log"
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/unit.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/ranking.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/scheduler.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/insertion.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/diagnostics.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/copilot.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/copilot_edits.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/copilot_requests.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/copilot_client.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/copilot_workspace.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/menu.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/documentation.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/words.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/integration.lua
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/cmdline.lua
python3 tests/tui.py
