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
${NVIM:-nvim} --headless -u tests/minimal_init.lua -i NONE -n -l tests/integration.lua
python3 tests/tui.py
