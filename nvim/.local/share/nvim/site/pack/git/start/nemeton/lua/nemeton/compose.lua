-- The window you write a comment in.
--
-- A real buffer in a real split, not `vim.ui.input`: a review comment is
-- prose with paragraphs and code fences in it, and it deserves the
-- editor you already know how to use -- your own keymaps, undo,
-- completion, `gq`. Markdown filetype, because that is what GitLab will
-- render it as.

local config = require("nemeton.config")

local M = {}

--- opts.title    -- shown in the winbar, says what this comment attaches to
--- opts.body     -- text to start from, for editing something already said
--- opts.on_draft(text)  -- the same, for a comment kept rather than sent
--- opts.on_submit(text) -- called with the body; the window is already gone
--- opts.default  -- "keep" or "post": which of the two the first key and
---                  `:w` do. "keep" where both are given and it is not
---                  said, because a review is written as a whole.
---
--- Two exits from one window, and which of them is the reflex is the
--- caller's to say. A new thread is kept: it is a remark in a review
--- nobody has read yet, and it can still be taken back after the next
--- file. A reply is posted: it is half of a conversation somebody else
--- is already in, and a conversation held one publish at a time is not
--- one. The other exit is always there on the second key.
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "acwrite"
  vim.api.nvim_buf_set_name(buf, "nemeton://compose")

  vim.cmd(("botright %dsplit"):format(config.compose.height))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  local k = config.keys.compose
  -- What the first key does, and what is left for the second. Posting
  -- when the caller asked for it, and when keeping is not on offer at
  -- all -- an edit of something already posted has nowhere to be kept.
  local posts = opts.default == "post" or not opts.on_draft
  local first = (posts and opts.on_submit) or opts.on_draft
  local second = (posts and opts.on_draft) or (opts.on_draft and opts.on_submit) or nil
  vim.wo[win].winbar = ("%%#NemetonAuthor#%s%%*  %%#NemetonHint#%s %s%s · %s cancel%%*"):format(
    opts.title or "comment",
    k.keep,
    posts and "send" or "keep",
    second and (" · " .. k.post .. " " .. (posts and "keep for the review" or "post now")) or "",
    k.cancel
  )
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].spell = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  --- `send` is what to do with the text: posted now, or kept unsent.
  --- Two exits from one window rather than two windows, because the
  --- choice is made at the end of writing it and not before.
  local function finish(send)
    return function()
      local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      if text == "" then
        vim.notify("nemeton: nothing to post", vim.log.levels.WARN)
        return
      end
      -- Closed before the request goes out, not after it comes back:
      -- the window has done its job, and leaving it up during a round
      -- trip makes a slow forge look like a broken keymap.
      close()
      send(text)
    end
  end
  -- This is what <C-s> and `:w` both do.
  local submit = finish(first)

  vim.keymap.set({ "n", "i" }, k.keep, submit, {
    buffer = buf,
    desc = posts and "nemeton: post this comment" or "nemeton: keep this comment for the review",
  })
  vim.keymap.set("n", k.cancel, close, { buffer = buf, desc = "nemeton: discard this comment" })
  if second and k.post ~= "" then
    vim.keymap.set({ "n", "i" }, k.post, finish(second), {
      buffer = buf,
      desc = posts and "nemeton: keep this comment for the review instead"
        or "nemeton: post this comment now",
    })
  end
  -- `:w` too -- writing is what the muscle memory does in a buffer that
  -- looks like this one, and `acwrite` means we get told about it.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = submit,
  })

  -- A new comment starts in insert mode, where you were going anyway.
  -- One that arrives with text in it does not: the cursor belongs at
  -- the end of what is already there, in normal mode, because editing
  -- starts with reading it back.
  if opts.body and opts.body ~= "" then
    local lines = vim.split(opts.body, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  else
    vim.cmd("startinsert")
  end
  return buf
end

return M
