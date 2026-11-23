-- The colours of the project's labels, by name.
--
-- A label is drawn as a chip in the colour the project gave it, the way
-- the page draws one -- on a merge request's or an issue's own line of
-- labels, where the forge sends the colour along with the name, and in
-- a sentence, `~bug`, where all there is is the name. The second needs
-- the colours from somewhere else, and this is where: every label drawn
-- with its colour is remembered, and so is every list of the project's
-- labels this editor has been sent.
--
-- `~5 minutes` is not a label, and neither is a `~name` the project
-- has none of: the page draws a reference to a label that does not
-- exist as the text that was typed, so only a name known here is drawn
-- as a chip at all.

local M = {}

local known = {}
local asked = {}

local function hex(colour)
  return type(colour) == "string" and colour:match("^#%x%x%x%x%x%x$") or nil
end

--- Remembers the colours of `list` -- labels as the REST API spells
--- them (`name`, `text_color`), as GraphQL does through the cache
--- (`title`), or as a map of name to `{ color, text_color }`. True when
--- one of them was not known before.
function M.know(list)
  local fresh = false
  for k, l in pairs(type(list) == "table" and list or {}) do
    local name = type(k) == "string" and k or (type(l) == "table" and (l.title or l.name))
    local colour = type(l) == "table" and hex(l.color)
    if type(name) == "string" and colour then
      local was = known[name]
      if not was or was.color ~= colour then
        fresh = true
      end
      known[name] = { color = colour, text_color = hex(l.text_color) }
    end
  end
  return fresh
end

--- The colours of the label called `name`, or nil for one not known.
function M.colour(name)
  return known[name]
end

--- The highlight a label is drawn in: its own colours, as a chip, the
--- way the forge draws one. Made the first time a colour is asked for
--- and again after a `:colorscheme`, which clears every group.
function M.hl(l)
  local bg = hex(l.color)
  if not bg then
    return "NemetonLabel"
  end
  M.know({ l })
  local name = "NemetonLabel_" .. bg:sub(2)
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })) then
    vim.api.nvim_set_hl(0, name, { bg = bg, fg = hex(l.text_color) or "#FFFFFF" })
  end
  return name
end

--- Asks the forge for every label of the project at `root`, once an
--- editor session, and calls `cb()` if that taught this anything -- a
--- window that drew `~bug` as words before the answer redraws it as a
--- chip.
function M.ask(root, cb)
  if not root or asked[root] then
    return
  end
  asked[root] = true
  require("nemeton.glab").labels(root, function(data)
    if type(data) == "table" and M.know(data) and cb then
      cb()
    end
  end)
end

return M
