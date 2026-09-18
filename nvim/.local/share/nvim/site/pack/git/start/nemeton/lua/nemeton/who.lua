-- Who gave a reaction, in a float over it.
--
-- The names are not drawn under the note: a row of pictures with a
-- count beside each is what the page shows, and a review is read for
-- what people wrote. But "who" is a question asked of a row -- three
-- thumbs from three maintainers is an argument being over, and three
-- from the author's friends is not -- and on the page the answer is a
-- hover. This is the hover here: the cursor resting on a reaction, or
-- `K` on it, and a float beside it that the next move takes away. No
-- state, no key to close it, nothing to leave open over the prose.

local config = require("nemeton.config")
local follow = require("nemeton.follow")
local threads = require("nemeton.threads")

local M = {}

M.win = nil
-- Where the float was opened for, so that the hold that fires after
-- `K` on the same reaction does not take it down to put it back up.
local shown = nil

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, shown = nil, nil
end

--- The names as one line: whoever gave it, in the order the forge
--- listed them, and "you" for the reader -- which is what the colour of
--- the row already said, so the float agrees with it.
local function names(ref)
  local session = require("nemeton.session")
  local me = session.current and session.current.me
  local out = {}
  for _, user in ipairs(ref.who or {}) do
    table.insert(out, (me and user == me) and "you" or user)
  end
  return table.concat(out, ", ")
end

--- Says who gave the reaction under the cursor. Nothing at all on
--- anything else: this runs on every rest of the cursor in a window of
--- prose, and a window that says "no" every time the cursor stops was
--- a window to read past.
function M.show()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local ref = follow.under(buf, pos[1] - 1, pos[2])
  if not (ref and ref.kind == "reaction") then
    M.close()
    return nil
  end
  if M.win and vim.api.nvim_win_is_valid(M.win) and shown == ref then
    return M.win
  end
  M.close()

  local picture = threads.emoji(":" .. ref.name .. ":")
  local text = picture .. "  " .. names(ref)
  local most = math.max(math.min(vim.o.columns - 10, 60), 20)
  local width = math.min(vim.fn.strdisplaywidth(text), most)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { text })
  require("nemeton.marks").paint(fbuf, {
    {
      row = 0,
      col = 0,
      end_col = #picture,
      hl = ref.mine and "NemetonReactionMine" or "NemetonReaction",
    },
  })
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden = "wipe"
  M.win = vim.api.nvim_open_win(fbuf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = math.ceil(vim.fn.strdisplaywidth(text) / width),
    style = "minimal",
    border = "rounded",
    focusable = false,
  })
  vim.wo[M.win].winhighlight = "NormalFloat:Normal"
  vim.wo[M.win].wrap = true
  shown = ref
  -- Dismissed by moving, like the hover it is. Once, and on this
  -- buffer: a float over a window that has just been left is a float
  -- over nothing.
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    buffer = buf,
    once = true,
    callback = M.close,
  })
  return M.win
end

--- Puts the hover on `buf`: `CursorHold`, which is the cursor resting
--- for `updatetime` -- four seconds as Neovim ships, and a few hundred
--- milliseconds in most configs, where it is what makes a hover a
--- hover. `comments.hover = false` leaves only the key.
function M.attach(buf)
  if not config.comments.hover then
    return
  end
  vim.api.nvim_create_autocmd("CursorHold", {
    buffer = buf,
    callback = function()
      M.show()
    end,
  })
end

return M
