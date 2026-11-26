-- `scope.lua`: base and subtree, put on one panel and applied together.
--
-- What a review IS has two parts -- the revision it measures against,
-- and how much of the tree it is about -- and they are one statement.
-- "main, under util" is a sentence; "main", and then, later, "util", is
-- two decisions that happen to have been taken in a row. Asked in
-- sequence the first is already in force by the time the second is put,
-- so changing the base and thinking better of the subtree has
-- re-pointed every view in the repository on the way past, and there is
-- never a moment where both answers are on the screen to be read
-- together.
local h = require("helpers")
local base = require("uatis.base")
local scope = require("uatis.scope")
local prompt = require("uatis.prompt")
local fixture = h.repo()

h.git("switch", "-q", "feature/math")
local root = fixture

-- The panel's rows, whitespace squeezed.
local function rows(p)
  return vim.tbl_map(function(l)
    return (vim.trim(l):gsub("%s+", " "))
  end, vim.api.nvim_buf_get_lines(p.buf, 0, -1, false))
end

describe("the scope panel", function()
  local real_open, real_select = prompt.open, vim.ui.select
  local answer, saved, p
  -- The prompt answers whatever the test set; the picker always picks
  -- the last row, which is the one that asks.
  prompt.open = function(_, cb) cb(answer) end
  vim.ui.select = function(list, _, on_choice) on_choice(list[#list]) end

  local function open()
    saved = nil
    scope.open({ on_save = function(r) saved = r end })
    h.wait_for(function() return scope.get() ~= nil end, "the panel to open")
    return scope.get()
  end

  local function answer_row(row, with, field)
    scope.move(row)
    answer = with
    scope.edit()
    h.wait_for(function() return scope.get().pending[field] == with end, "the " .. field .. " to be taken")
  end

  it("opens on what is in force, the whole repository spelled out", function()
    base.forget(root)
    base.set(root, "main")
    base.set_dir(root, "")
    p = open()
    assert.is_true(h.contains(rows(p), "base main"))
    -- Not left blank: all of it is an answer.
    assert.is_true(h.contains(rows(p), "subtree (the whole repository)"))
  end)

  -- `q` puts every other float here away without doing anything, so it
  -- must not be the key that commits this one.
  it("discards on q and saves on <C-s>", function()
    local bound = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.buf, "n")) do
      bound[m.lhs] = m.callback
    end
    assert.are.equal(scope.close, bound["q"])
    assert.are.equal(scope.save, bound["<C-S>"] or bound["<C-s>"])
  end)

  -- This is the whole reason it is a panel: two answers are held
  -- together until the reader has looked at the pair, and a mind changed
  -- about the second must not have to undo the first.
  it("applies neither answer while the panel is open", function()
    answer_row(0, "feature/math", "base")
    answer_row(1, "util", "dir")
    assert.are.equal("main", base.current(root))
    assert.are.equal("", base.dir(root))
  end)

  it("shows what it is holding", function()
    assert.is_true(h.contains(rows(p), "base feature/math"))
    assert.is_true(h.contains(rows(p), "subtree util/"))
  end)

  it("lands both answers at once on save, and closes", function()
    scope.save()
    assert.is_nil(scope.get())
    assert.are.equal("feature/math", base.current(root))
    assert.are.equal("util", base.dir(root))
    -- Whatever is on screen is told to follow.
    assert.are.equal(root, saved)
  end)

  it("leaves what is in force alone when discarded", function()
    open()
    answer_row(1, "", "dir")
    scope.close()
    assert.are.equal("util", base.dir(root))
    assert.is_nil(saved)
  end)

  prompt.open, vim.ui.select = real_open, real_select
  base.forget(root)
  base.set(root, "main")
  base.set_dir(root, "")
end)
