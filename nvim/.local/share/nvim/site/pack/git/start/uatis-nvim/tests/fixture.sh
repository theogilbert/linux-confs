#!/usr/bin/env bash
# Builds a throwaway repo covering the cases that actually break a review
# renderer: a plain modification, a file added by the branch, a file
# deleted by the branch, a rename, a comment-only commit, and -- most
# importantly -- a commit landing on the target branch AFTER the fork, which
# is what tells a three-dot diff apart from a two-dot one.
#
# Usage: fixture.sh <dir>
set -euo pipefail

DIR="${1:?usage: fixture.sh <dir>}"
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

git init -q -b main
git config user.email fixture@example.com
git config user.name 'Fixture Author'
git config commit.gpgsign false

cat > calc.lua <<'EOF'
local M = {}

function M.add(a, b)
  return a + b
end

function M.sub(a, b)
  return a - b
end

return M
EOF

cat > doomed.lua <<'EOF'
-- This file does not survive the branch.
return { gone = true }
EOF

cat > renamed_from.lua <<'EOF'
return { name = "original" }
EOF

# A file the branch never touches. Nothing is drawn on it, and that is the
# case worth having: a review annotates the files it lists as you open
# them, and this is the one it must leave alone.
cat > stable.lua <<'EOF'
return { untouched = true }
EOF

git add -A
git commit -qm 'initial'
# A tag to compare against. The base need not be a branch: "what has
# changed since the release" is the same question with a different answer.
# Annotated and dated, because the whole fixture is built inside one
# second: lightweight tags would fall back to their commit's date, tie, and
# come back in alphabetical order, which would make the ordering the picker
# relies on untestable here.
GIT_COMMITTER_DATE='2020-01-01T00:00:00' git tag -a v0.1 -m 'first release'

git switch -qc feature/math

# 1. plain modification: two changes far enough apart to be separate
#    chunks, so chunk navigation has somewhere to navigate to
cat > calc.lua <<'EOF'
local M = {}

function M.add(a, b)
  return (a or 0) + (b or 0)
end

function M.sub(a, b)
  return b - a
end

function M.mul(a, b)
  return a * b
end

return M
EOF
git commit -qam 'fix sub argument order and add mul'

# 2. new files, one of them nested, so the file list has a tree to draw
cat > helper.lua <<'EOF'
local M = {}

function M.clamp(v, lo, hi)
  return math.max(lo, math.min(v, hi))
end

return M
EOF
mkdir -p util
cat > util/strings.lua <<'EOF'
local M = {}

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

return M
EOF
git add helper.lua util/strings.lua
git commit -qm 'add clamp helper'

# 3. a deletion and a rename in one commit
git rm -q doomed.lua
git mv renamed_from.lua renamed_to.lua
git commit -qm 'drop doomed, rename module'

# 4. comment-only: nothing structural changed
cat > helper.lua <<'EOF'
local M = {}

-- Clamps v into [lo, hi].
function M.clamp(v, lo, hi)
  return math.max(lo, math.min(v, hi))
end

return M
EOF
git commit -qam 'document clamp'

# 5. target branch moves on after the fork. A two-dot diff would report
#    this file as deleted by the branch; a three-dot diff ignores it.
git switch -q main
cat > unrelated.lua <<'EOF'
return { landed_on_main_after_fork = true }
EOF
git add unrelated.lua
git commit -qm 'unrelated work on main'
# ...and a second one, later, so the order tags come back in can be asserted.
GIT_COMMITTER_DATE='2021-01-01T00:00:00' git tag -a v0.2 -m 'second release'

# 6. a branch that collides with feature/math, for the conflict review.
#    Merged into feature/math it stops on two files. In calc.lua the two
#    branches changed DIFFERENT words of adjacent lines -- this one the
#    comments on the signatures, feature/math the bodies under them --
#    which git cannot merge by the line and the wand can by the word.
#    helper.lua both branches ADDED, one word apart: there is no base to
#    merge against, and nothing can take that block but the reader.
git switch -qc feature/clash v0.1
cat > calc.lua <<'EOF'
local M = {}

function M.add(a, b)  -- sum
  return a + b
end

function M.sub(a, b)  -- difference
  return a - b
end

return M
EOF
cat > helper.lua <<'EOF'
local M = {}

-- Clamps v into [lo, hi].
function M.clamp(v, lo, hi)
  return math.min(hi, math.max(v, lo))
end

return M
EOF
git add calc.lua helper.lua
git commit -qm 'document calc, add clamp the other way round'
git switch -q main

# Left on main deliberately: `:Uatis review feature/math` with no target
# is the common case, and it only means anything from the branch being
# merged into.
echo "$DIR"
