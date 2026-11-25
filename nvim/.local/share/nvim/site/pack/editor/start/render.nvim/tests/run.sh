#!/usr/bin/env bash
# Runs the specs under tests/spec, each in a headless nvim of its own.
# A file or directory given as an argument runs only that:
# `./tests/run.sh tests/spec/view_spec.lua`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"

# plenary is the one thing the suite needs that is not this checkout:
# where it was asked for, else an installed copy, else a pinned clone
# kept beside the floor nvim.
PLENARY_REV=74b06c6c75e4eeb3108ec01852001636d85a932b
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/render"
find_plenary() {
  if [[ -n "${RENDER_PLENARY:-}" ]]; then
    echo "$RENDER_PLENARY"
    return
  fi
  local data="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
  for p in "$data"/site/pack/*/*/plenary.nvim "$data"/lazy/plenary.nvim; do
    if [[ -f "$p/lua/plenary/busted.lua" ]]; then
      echo "$p"
      return
    fi
  done
  local pinned="$CACHE/plenary-$PLENARY_REV"
  if [[ ! -f "$pinned/lua/plenary/busted.lua" ]]; then
    rm -rf "$pinned"
    git clone -q --filter=blob:none https://github.com/nvim-lua/plenary.nvim "$pinned" >&2
    git -C "$pinned" checkout -q "$PLENARY_REV" >&2
  fi
  echo "$pinned"
}
RENDER_PLENARY="$(find_plenary)"
export RENDER_PLENARY

TARGET="${1:-tests/spec}"
exec nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('$TARGET', {
        minimal_init = 'tests/minimal_init.lua',
        sequential = true,
        timeout = 120000,
      })"
