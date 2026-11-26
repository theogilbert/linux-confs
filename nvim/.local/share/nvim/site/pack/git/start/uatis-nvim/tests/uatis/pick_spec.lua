-- `pick.lua`: a file of the review chosen by name, through fzf-lua with
-- the list's colours or `vim.ui.select` without them.
local h = require("helpers")
local uatis = require("uatis")
local pick = require("uatis.pick")
local pane_mod = require("uatis.pane")
local config = require("uatis.config")
local ok, eq = h.ok, h.eq
local fixture = h.repo()

h.git("switch", "-q", "feature/math")
config.pane.auto_open = false

local function texts(row)
  return table.concat(vim.tbl_map(function(s) return s.text end, row.segments))
end

local function seg(row, text)
  for _, s in ipairs(row.segments) do
    if s.text == text then
      return s
    end
  end
end

local pane
describe("the file picker", function()
  it("says there is no review where there is none", function()
    local notes = h.notes(function() uatis.pick_file() end)
    ok(h.contains(notes, "no review"), "names why nothing opened")
  end)

  it("offers every file of the review, path, name and count", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    uatis.toggle_diff()
    h.wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and #p.files > 0 and (p.renders or 0) > 0
    end, "the review's list")
    pane = pane_mod.get()
    local rows = pick.rows(pane, 80)
    eq(#rows, #pane.files, "one row per file")
    for _, r in ipairs(rows) do
      local f = pane.files[r.idx]
      local name = f.path:match("[^/]*$")
      ok(seg(r, name), "the name whole: " .. f.path)
      if not f.binary then
        local add = seg(r, "+" .. f.added)
        ok(add and add.hl == "UatisStatAdd", "the additions green: " .. f.path)
        local del = seg(r, "-" .. f.removed)
        ok(del and del.hl == "UatisStatDel", "the removals red: " .. f.path)
      end
    end
  end)

  it("lines the counts up in one column, and cuts long directories from the left", function()
    local rows = pick.rows(pane, 80)
    local cols = {}
    for _, r in ipairs(rows) do
      local t = texts(r)
      cols[t:find("[+-]%d") or t:find("bin")] = true
    end
    eq(vim.tbl_count(cols), 1, "every count starts in the same column")
    local nested
    for _, r in ipairs(rows) do
      if pane.files[r.idx].path:find("/") then
        nested = r
      end
    end
    if ok(nested, "the fixture has a nested file") then
      local narrow = pick.rows(pane, 14)
      for _, r in ipairs(narrow) do
        if r.idx == nested.idx then
          ok(r.segments[1].text:sub(1, #"…") == "…", "the directory cut with …")
          eq(r.segments[2].text, nested.segments[2].text, "the name kept whole")
        end
      end
    end
  end)

  it("draws a file read through receded, as the list does", function()
    pane_mod.toggle_read(pane, 1, true)
    local r = pick.rows(pane, 80)[1]
    eq(r.segments[1].hl, "UatisRead", "the directory")
    eq(r.segments[2].hl, "UatisRead", "and the name")
    local other = pick.rows(pane, 80)[2]
    if other then
      ok(other.segments[2].hl ~= "UatisRead", "a file not read keeps its colour")
    end
    pane_mod.toggle_read(pane, 1, false)
  end)

  it("opens the file chosen through vim.ui.select, as its row would", function()
    local target = pane.files[#pane.files]
    local select = vim.ui.select
    local offered
    vim.ui.select = function(items, opts, cb)
      offered = vim.tbl_map(opts.format_item, items)
      for _, it in ipairs(items) do
        if pane.files[it.idx].path == target.path then
          cb(it)
        end
      end
    end
    uatis.pick_file()
    vim.ui.select = select
    eq(#offered, #pane.files, "every file offered as plain text")
    h.wait_for(function()
      return vim.api.nvim_buf_get_name(0):sub(-#target.path) == target.path
    end, "the chosen file to open")
  end)

  it("hands fzf-lua coloured entries that name their file by index", function()
    local got, ansi = {}, {}
    package.loaded["fzf-lua"] = {
      utils = { ansi_from_hl = function(hl, text)
        table.insert(ansi, hl)
        return "<" .. hl .. ">" .. text
      end },
      fzf_exec = function(entries, opts)
        got.entries, got.opts = entries, opts
      end,
    }
    uatis.pick_file()
    package.loaded["fzf-lua"] = nil
    eq(#got.entries, #pane.files, "one entry per file")
    ok(got.entries[1]:match("^1\t"), "led by the index, hidden from the reader")
    eq(got.opts.fzf_opts["--with-nth"], "2..", "which --with-nth hides")
    ok(vim.tbl_contains(ansi, "UatisStatAdd"), "the counts coloured")
    got.opts.actions.enter({ got.entries[1] })
    local first = pane.files[1].path
    h.wait_for(function()
      return vim.api.nvim_buf_get_name(0):sub(-#first) == first
    end, "the file fzf chose to open")
  end)

  it("is offered under g? in the list", function()
    ok(h.offered(pane):find("pick a file", 1, true), "named among the keys")
  end)
end)
