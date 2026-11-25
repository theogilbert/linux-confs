local render = require("render")
local config = require("render.config")
local view = require("render.view")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/docs", "p")
local readme = dir .. "/README.md"
vim.fn.writefile({
  "# Title", --                        1
  "", --                               2
  "Some **prose** with [a link](https://x.test/page).", -- 3
  "", --                               4
  "## Setup", --                       5
  "", --                               6
  "See [the guide](docs/guide.md#install) and [below](#setup).", -- 7
  "", --                               8
  "| a | b |", --                      9
  "|---|---|", --                      10
  "| 1 | 2 |", --                      11
}, readme)
vim.fn.writefile({ "# Guide", "", "## Install", "", "run it" }, dir .. "/docs/guide.md")

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

--- Puts the cursor on the first `text` in the reader.
local function on(text)
  for i, l in ipairs(lines()) do
    local col = l:find(text, 1, true)
    if col then
      vim.api.nvim_win_set_cursor(0, { i, col - 1 })
      return
    end
  end
  error("not in the reader: " .. text)
end

describe("the reader", function()
  local src

  it("is opened in the file's place, on the line the cursor was on", function()
    render.setup({})
    vim.cmd.edit(readme)
    vim.bo.filetype = "markdown"
    src = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    render.toggle()
    local buf = vim.api.nvim_get_current_buf()
    assert.are_not.same(src, buf)
    assert.same(src, view.source_of(buf))
    assert.same("Title", lines()[1])
    assert.same("Setup", vim.api.nvim_get_current_line(), "on the line it was reading")
    assert.is_false(vim.bo.modifiable, "and nothing in it can be typed over")
    assert.truthy(vim.tbl_contains(lines(), "┌───┬───┐"), "a table is ruled")
  end)

  it("draws its colours", function()
    local marks = vim.api.nvim_buf_get_extmarks(0, view.ns, 0, -1, { details = true })
    local groups = {}
    for _, m in ipairs(marks) do
      groups[m[4].hl_group] = true
    end
    assert.truthy(groups.RenderHeading1 and groups.RenderBold and groups.RenderLink)
  end)

  it("says it is a reader, above the page rather than over it", function()
    assert.matches("READER", vim.wo.winbar)
    assert.matches("RenderReader", vim.wo.winbar)
  end)

  it("toggled again, is the file, on the line that was being read", function()
    on("│ 1")
    render.toggle()
    assert.same(src, vim.api.nvim_get_current_buf())
    assert.same(11, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(vim.wo.wrap ~= nil, "and the file's own window options")
    assert.same("", vim.wo.winbar, "and no winbar of the reader's")
  end)

  it("follows what the file says, as it is typed", function()
    render.toggle()
    vim.api.nvim_buf_set_lines(src, 0, 1, false, { "# Renamed" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = src })
    assert.same("Renamed", lines()[1])
  end)

  it("a link to a heading of this page goes to it", function()
    on("below")
    render.follow()
    assert.same("Setup", vim.api.nvim_get_current_line())
  end)

  it("a link to another file is that file, in the reader too", function()
    on("the guide")
    render.follow()
    local buf = vim.api.nvim_get_current_buf()
    assert.truthy(vim.api.nvim_buf_get_name(view.source_of(buf)):find("guide.md$"))
    assert.same("Install", vim.api.nvim_get_current_line(), "at the heading it named")
  end)

  it("a function of yours is handed the link, and the built-in with it", function()
    vim.cmd("buffer " .. view.view_of(src))
    local seen
    config.follow = function(link, ctx)
      seen = { link = link, ctx = ctx }
    end
    on("a link")
    render.follow()
    assert.same({ kind = "url", href = "https://x.test/page", text = "a link" }, seen.link)
    assert.same(src, seen.ctx.source)
    on("below")
    config.follow = function(_, ctx)
      ctx.default()
    end
    render.follow()
    assert.same("Setup", vim.api.nvim_get_current_line(), "which still goes where it went")
    config.follow = nil
  end)

  it("<C-]> is the key that follows", function()
    on("below")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    on("below")
    vim.api.nvim_feedkeys(vim.keycode("<C-]>"), "x", false)
    assert.same("Setup", vim.api.nvim_get_current_line())
  end)

  it("is wrapped again when the window is narrower", function()
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, 20)
    vim.api.nvim_exec_autocmds("WinResized", {})
    for _, l in ipairs(lines()) do
      if not l:find("[┌│├└]") then
        assert.truthy(vim.fn.strdisplaywidth(l) <= 20, l)
      end
    end
    vim.cmd("close")
  end)

  it("a file with unsaved changes is read without 'hidden'", function()
    vim.o.hidden = false
    vim.cmd("buffer " .. src)
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "unsaved" })
    render.toggle()
    assert.same(src, view.source_of(vim.api.nvim_get_current_buf()))
    render.toggle()
    assert.same(src, vim.api.nvim_get_current_buf())
    assert.is_true(vim.bo.modified, "and the changes are still there")
    assert.same("", vim.bo.bufhidden, "and the file has its own 'bufhidden' back")
    vim.o.hidden = true
  end)

  it("a file nothing reads says so", function()
    vim.cmd.enew()
    vim.bo.filetype = "csv"
    local said
    local notify = vim.notify
    vim.notify = function(msg)
      said = msg
    end
    render.toggle()
    vim.notify = notify
    assert.same("render: no reader for a csv file", said)
  end)
end)
