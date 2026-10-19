#!/usr/bin/env bash
# Builds a fresh fixture repo and runs the headless suite against it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURE="${UATIS_FIXTURE:-${TMPDIR:-/tmp}/uatis-fixture}"

"$HERE/fixture.sh" "$FIXTURE" >/dev/null

# A cache of its own: the suite checks out commits (`checkout.lua`,
# `at.lua`) into `stdpath("cache")`, and the reader's is no place for a
# fixture's worktrees.
CACHE="$(mktemp -d)"
trap 'rm -rf "$CACHE"' EXIT

# `packpath=` so this runs against THIS checkout and not against whatever
# copy of the plugin happens to be installed in the user's site packages.
XDG_CACHE_HOME="$CACHE" nvim --headless -u NONE \
  --cmd "set packpath=" \
  --cmd "set rtp+=$ROOT" \
  -l "$HERE/run.lua" "$FIXTURE"
