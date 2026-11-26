-- `prompt.lua`: the one-line input that completes revisions.
--
-- One line, in a float, completing the list it was handed. Asserted
-- through the mappings it binds rather than by feeding keys -- headless
-- has no insert mode to press them in.
local h = require("helpers")
local prompt = require("uatis.prompt")

local items = {
  { word = "main", kind = "branch" },
  { word = "feature/math", kind = "branch" },
  { word = "origin/feature/math", kind = "remote" },
  { word = "v0.1", kind = "tag" },
  { word = "a1b2c3d", kind = "commit", menu = "widen the pane on a narrow window" },
}

local function words(typed)
  return vim.tbl_map(function(item) return item.word end, prompt.omnifunc(0, typed))
end

local function mapped(lhs)
  return vim.fn.maparg(lhs, "n", false, true)
end

describe("the prompt", function()
  local answer, win, buf
  local function open()
    answer = "unset"
    win = prompt.open({ prompt = "uatis: base revision", items = items },
      function(text) answer = text end)
    buf = vim.api.nvim_win_get_buf(win)
  end

  it("is a one-line float", function()
    open()
    assert.are.equal("editor", vim.api.nvim_win_get_config(win).relative)
    assert.are.equal(1, vim.api.nvim_buf_line_count(buf))
  end)

  -- Completion is `omnifunc`, so it answers the two questions the
  -- completion machinery asks: where the word starts, and what matches.
  it("completes through omnifunc", function()
    assert.are.equal("v:lua.require'uatis.prompt'.omnifunc", vim.bo[buf].omnifunc)
  end)

  it("completes the whole line, since a revision holds slashes", function()
    assert.are.equal(0, prompt.omnifunc(1, ""))
  end)

  it("matches a name anywhere in a ref, tags too", function()
    assert.are.same({ "feature/math", "origin/feature/math" }, words("math"))
    assert.are.same({ "v0.1" }, words("v0"))
    assert.are.same({}, words("nothing-like-this"))
  end)

  -- When what is typed does start a name, that is the name being typed
  -- towards.
  it("offers a ref the text starts before one that merely contains it", function()
    assert.are.equal("feature/math", words("feature")[1])
  end)

  -- A sha nobody has memorised, so it is found by what it did -- and it
  -- says so in the menu beside it.
  it("matches a commit on its subject line, and says it is a commit", function()
    assert.are.same({ "a1b2c3d" }, words("narrow window"))
    assert.are.equal("commit", prompt.omnifunc(0, "narrow window")[1].kind)
  end)

  -- A flat list of the first N in a repository with three hundred
  -- branches is three hundred branches, and the tags may as well not be
  -- offered.
  it("offers every kind with nothing typed", function()
    local kinds = {}
    for _, item in ipairs(prompt.omnifunc(0, "")) do
      kinds[item.kind] = true
    end
    assert.are.same({ branch = true, tag = true, remote = true, commit = true }, kinds)
  end)

  -- `<Tab>` in insert mode belongs to whichever completion engine the
  -- reader installed, and a prompt that completes only when it wins
  -- that race is a prompt that silently does not complete.
  it("opens the menu as the line changes, choosing nothing", function()
    assert.is_true(#vim.api.nvim_get_autocmds({ event = "TextChangedI", buffer = buf }) > 0)
    assert.are.equal("menu,menuone,noselect", vim.bo[buf].completeopt)
  end)

  it("tells the engines that watch every buffer to stay out of this one", function()
    assert.is_false(vim.b[buf].completion)
  end)

  it("answers what was typed on <CR>, trimmed, and closes", function()
    local cr = mapped("<CR>")
    assert.are.equal(1, cr.buffer)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  v0.1  " })
    cr.callback()
    h.wait_for(function() return answer ~= "unset" end, "the prompt to answer")
    assert.are.equal("v0.1", answer)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("answers nothing on <Esc>, and closes", function()
    open()
    mapped("<Esc>").callback()
    h.wait_for(function() return answer ~= "unset" end, "the prompt to answer")
    assert.is_nil(answer)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)
