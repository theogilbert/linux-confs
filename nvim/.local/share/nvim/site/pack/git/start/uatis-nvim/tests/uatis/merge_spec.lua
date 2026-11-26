-- `merge.lua`: conflict blocks read, and merged three ways by the word.
require("helpers")
local merge = require("uatis.merge")

-- What git leaves in a file: markers around ours and theirs, and with
-- `merge.conflictStyle` diff3 or zdiff3 the base between them. Read
-- from lines alone -- no buffer, no git -- so the list can count a
-- file's blocks off disk and the annotator off the buffer with one
-- reader.
describe("merge.blocks", function()
  local blocks = merge.blocks({
    "keep",
    "<<<<<<< HEAD",
    "ours 1",
    "ours 2",
    "=======",
    "theirs",
    ">>>>>>> feature/x",
    "between",
    "<<<<<<< HEAD",
    "o",
    "||||||| merged common ancestors",
    "b",
    "=======",
    "t",
    ">>>>>>> feature/x",
    "<<<<<<< HEAD",
    "never closed",
  })

  it("reads two blocks, and a run of markers that never closes as none", function()
    assert.are.equal(2, #blocks)
  end)

  it("says where a block's marker rows are", function()
    assert.are.same({ 2, 5, 7 }, { blocks[1].top, blocks[1].sep, blocks[1].bottom })
  end)

  it("reads both sides, and no base where the markers carry none", function()
    assert.are.same({ "ours 1", "ours 2" }, blocks[1].ours)
    assert.are.same({ "theirs" }, blocks[1].theirs)
    assert.is_nil(blocks[1].base)
  end)

  it("keeps the labels git wrote on the markers", function()
    assert.are.same({ "HEAD", "feature/x" }, { blocks[1].label_ours, blocks[1].label_theirs })
  end)

  it("reads a diff3 base, and where its `|||||||` row is", function()
    assert.are.same({ 11, { "b" } }, { blocks[2].mid, blocks[2].base })
  end)
end)

-- git merges by the line, and a conflict is two branches touching the
-- same line. Inside the block the question is asked again by the word:
-- base against ours, base against theirs, both applied where the two
-- sets of changes touch no common token. Touching is by closed ranges
-- -- adjacent words, or two insertions at one point -- and that is a
-- conflict here as it is a conflict for git one level up.
describe("merge.merge3", function()
  local function merges(base, ours, theirs, want)
    assert.are.same(want, (merge.merge3(base, ours, theirs)))
  end

  it("applies different words of adjacent lines both", function()
    merges("function add(a, b)\n  return a + b",
      "function add(a, b)\n  return (a or 0) + (b or 0)",
      "function add(a, b)  -- sum\n  return a + b",
      "function add(a, b)  -- sum\n  return (a or 0) + (b or 0)")
  end)

  it("applies different words of one line both", function()
    merges("return a + b", "return (a or 0) + b", "return a + b -- sum",
      "return (a or 0) + b -- sum")
  end)

  it("refuses the same word changed two ways", function()
    merges("x = 1", "x = 2", "x = 3", nil)
  end)

  it("applies the same change on both sides once", function()
    merges("x = 1", "x = 2", "x = 2", "x = 2")
  end)

  it("takes the other side where one changed nothing", function()
    merges("x = 1", "x = 1", "y = 1", "y = 1")
  end)

  it("applies two insertions at different points", function()
    merges("a b c", "a X b c", "a b Y c", "a X b Y c")
  end)

  it("refuses two insertions at the same point", function()
    merges("a b c", "a X b c", "a Y b c", nil)
  end)

  it("refuses edits to adjacent tokens", function()
    merges("f(x)", "g(x)", "f[x]", nil)
  end)

  it("treats the blank between two words as a token of context", function()
    merges("a b", "A b", "a B", "A B")
  end)

  it("keeps a changed blank byte for byte", function()
    merges("a b", "A  b", "a b", "A  b")
  end)

  it("refuses two sides filling an empty base differently", function()
    merges("", "a", "b", nil)
  end)

  it("applies two sides filling an empty base alike", function()
    merges("", "a", "a", "a")
  end)

  it("treats a multi-byte character as one word", function()
    merges("d = 'é'\nx = 1", "d = 'è'\nx = 1", "d = 'é'\nx = 2", "d = 'è'\nx = 2")
  end)

  it("says why it refused", function()
    local _, why = merge.merge3("x = 1", "x = 2", "x = 3")
    assert.matches("same words", why, 1, true)
  end)
end)
