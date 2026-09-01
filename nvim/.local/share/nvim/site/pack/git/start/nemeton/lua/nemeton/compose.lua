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
---
--- Where both are given, keeping it is what the window does by default
--- and posting is the second key; where only `on_submit` is -- a reply
--- into somebody's thread, an edit of something already posted -- the
--- default key posts.
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
  vim.wo[win].winbar = ("%%#NemetonAuthor#%s%%*  %%#NemetonHint#%s %s%s · %s cancel%%*"):format(
    opts.title or "comment",
    k.keep,
    opts.on_draft and "keep" or "submit",
    opts.on_draft and (" · " .. k.post .. " post now") or "",
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
  -- The default: kept where keeping is possible, posted where it is
  -- not. This is what <C-s> and `:w` both do.
  local submit = finish(opts.on_draft or opts.on_submit)

  vim.keymap.set({ "n", "i" }, k.keep, submit, {
    buffer = buf,
    desc = opts.on_draft and "nemeton: keep this comment for the review"
      or "nemeton: post this comment",
  })
  vim.keymap.set("n", k.cancel, close, { buffer = buf, desc = "nemeton: discard this comment" })
  if opts.on_draft and k.post ~= "" then
    vim.keymap.set(
      { "n", "i" },
      k.post,
      finish(opts.on_submit),
      { buffer = buf, desc = "nemeton: post this comment now" }
    )
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
