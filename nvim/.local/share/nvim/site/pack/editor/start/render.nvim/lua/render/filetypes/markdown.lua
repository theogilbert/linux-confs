-- A markdown file, as it reads.

local config = require("render.config")
local markdown = require("render.markdown")
local draw = require("render.draw")

local M = {}

--- `lines` as lines of chunks (`render.draw.blocks`). `opts.width` is
--- the most a line of prose may reach.
function M.render(lines, opts)
  local c = config.markdown
  local read = {
    links = c.links,
    styles = c.styles,
    math = c.math,
    headings = c.headings,
    tables = c.tables,
    citations = c.citations,
    lists = c.lists,
  }
  local emoji = c.emoji and require("render.emoji").render or function(text)
    return text
  end
  -- A file's paragraphs are wrapped by hand, and read here at the
  -- window's width.
  read.join = true
  read.definitions = markdown.definitions(lines)
  local syntax = require("render.syntax")
  return draw.blocks(markdown.blocks(lines, read), {
    width = opts.width,
    -- A window scrolls sideways; a fence folded at its edge is not the
    -- code any more.
    code = false,
    glyphs = { bullets = c.bullets, tasks = c.tasks, citation = c.citation },
    headings = c.headings and c.heading or nil,
    inline = function(text)
      return markdown.inline(emoji(text), read)
    end,
    paint = c.syntax and function(code, word)
      return syntax.paint(code, syntax.of_fence(word))
    end or nil,
  })
end

return M
