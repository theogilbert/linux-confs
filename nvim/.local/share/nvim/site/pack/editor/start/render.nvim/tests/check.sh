#!/usr/bin/env bash
# Everything CI asks of a push, asked here first: luacheck, stylua, and
# the suite on this nvim and on the oldest one CI runs. The last is the
# one that gets missed -- nobody develops on the floor -- so its binary
# is fetched once and kept.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"

# The floor is read off CI's matrix rather than written down twice.
FLOOR="$(sed -nE 's/^ *neovim: \[([^,]+),.*/\1/p' .github/workflows/ci.yml)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/render/nvim-$FLOOR"

failed=()

step() {
  local name="$1"
  shift
  printf '%-24s' "$name"
  local out
  if out="$("$@" 2>&1)"; then
    echo ok
  else
    echo FAILED
    printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' |
      grep -E -A4 '^Fail\s|^error|\([WE][0-9]+\)|E[0-9]+:|FAILED TO LOAD' | head -60 ||
      printf '%s\n' "$out" | tail -20
    failed+=("$name")
  fi
}

luacheck_() {
  if command -v luacheck >/dev/null; then
    luacheck --formatter plain lua plugin tests
  else
    local engine
    engine="$(command -v docker || command -v podman)" || {
      echo "error: neither luacheck nor docker/podman is installed"
      return 1
    }
    "$engine" run --rm -v "$ROOT:/data:Z" -w /data \
      ghcr.io/lunarmodules/luacheck:latest --formatter plain lua plugin tests
  fi
}

# CI pins the stylua it formats against; a different one here can pass
# what CI fails, so say so rather than trust it.
stylua_() {
  local want have
  want="$(sed -nE 's/^ *version: *"?([0-9][^" ]*)"?.*/\1/p' .github/workflows/ci.yml | head -1)"
  have="$(stylua --version | awk '{ print $2 }')"
  if [[ -n "$want" && "$have" != "$want" ]]; then
    echo "warning: stylua $have here, CI runs $want"
  fi
  stylua --check lua plugin tests
}

floor_nvim() {
  if [[ ! -x "$CACHE/bin/nvim" ]]; then
    mkdir -p "$CACHE"
    curl -fsSL "https://github.com/neovim/neovim/releases/download/$FLOOR/nvim-linux-x86_64.tar.gz" |
      tar xz -C "$CACHE" --strip-components=1 || return 1
  fi
  echo "$CACHE/bin/nvim"
}

suite() {
  PATH="$1:$PATH" ./tests/run.sh
}

step luacheck luacheck_
step stylua stylua_
step "suite ($(nvim --version | head -1 | awk '{ print $2 }'))" suite "$(dirname "$(command -v nvim)")"
if nvim_floor="$(floor_nvim)"; then
  step "suite ($FLOOR)" suite "$(dirname "$nvim_floor")"
else
  echo "suite ($FLOOR)          FAILED: could not fetch it"
  failed+=("fetch $FLOOR")
fi

if ((${#failed[@]})); then
  echo "failed: ${failed[*]}"
  exit 1
fi
