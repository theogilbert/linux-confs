#!/usr/bin/env bash
# Builds a fresh fixture repo and runs the spec files against it, each in a
# headless nvim of its own and several at once.
#
#   tests/run.sh                            every spec under tests/
#   tests/run.sh tests/uatis/diff_spec.lua  just the ones named
#
# UATIS_FIXTURE places the fixture, PLENARY_DIR names a plenary.nvim
# checkout (cloned into .tests/ when absent), UATIS_COMMON a common.nvim
# checkout (../common.nvim by default), UATIS_JOBS caps parallelism,
# UATIS_TIMEOUT is how many seconds one file may take (an error inside an
# async callback can leave nvim waiting on nothing, forever).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
export UATIS_FIXTURE="${UATIS_FIXTURE:-${TMPDIR:-/tmp}/uatis-fixture}"
export PLENARY_DIR="${PLENARY_DIR:-$ROOT/.tests/plenary.nvim}"

if [ ! -d "$PLENARY_DIR" ]; then
  git clone -q --depth 1 https://github.com/nvim-lua/plenary.nvim "$PLENARY_DIR"
fi

# Built once; every spec file copies it before touching it (`helpers.repo`),
# since they run side by side and several of them merge, commit and switch
# branches.
"$HERE/fixture.sh" "$UATIS_FIXTURE" >/dev/null

if [ $# -gt 0 ]; then
  SPECS=("$@")
else
  mapfile -t SPECS < <(find "$HERE" -name '*_spec.lua' -not -path '*/.tests/*' | sort)
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export OUT HERE UATIS_TIMEOUT

# A cache of its own per file: `checkout.lua` and `at.lua` check commits
# out under `stdpath("cache")` and clear the ones no live review holds,
# which in a shared cache would be the review running next door. And a
# ShaDa file of its own: not the reader's, and not none -- with ShaDa off
# the commit walk's date float never opens (the list cursor is moved
# under it), which the suite has always run with on.
run_one() {
  local spec="$1" log
  log="$OUT/$(echo "$spec" | tr '/' '_').log"
  local cache
  cache="$(mktemp -d)"
  if XDG_CACHE_HOME="$cache" timeout "${UATIS_TIMEOUT:-300}" nvim --headless --noplugin -i "$cache/shada" -u "$HERE/minimal_init.lua" \
    -c "lua require('plenary.busted').run([[$spec]])" >"$log" 2>&1; then
    echo ok >"$log.status"
  else
    echo fail >"$log.status"
  fi
  rm -rf "$cache"
}
export -f run_one

printf '%s\0' "${SPECS[@]}" |
  xargs -0 -n1 -P "${UATIS_JOBS:-$(nproc)}" bash -c 'run_one "$0"'

failed=()
pass=0 fail=0
for spec in "${SPECS[@]}"; do
  log="$OUT/$(echo "$spec" | tr '/' '_').log"
  cat "$log"
  pass=$((pass + $(grep -c 'Success.*||' "$log" || true)))
  fail=$((fail + $(grep -c 'Fail.*||' "$log" || true)))
  if [ "$(cat "$log.status")" != ok ]; then
    failed+=("$spec")
  fi
done

echo
echo "$pass passed, $fail failed, ${#SPECS[@]} files"
if [ ${#failed[@]} -gt 0 ]; then
  printf 'failing: %s\n' "${failed[@]}"
  exit 1
fi
