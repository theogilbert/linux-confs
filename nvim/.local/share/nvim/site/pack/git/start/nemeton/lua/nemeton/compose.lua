-- The window you write a comment in.
--
-- A real buffer in a real split, not `vim.ui.input`: a review comment is
-- prose with paragraphs and code fences in it, and it deserves the
-- editor you already know how to use -- your own keymaps, undo,
-- completion, `gq`. Markdown filetype, because that is what GitLab will
-- render it as.

local config = require("nemeton.config")
local win = require("nemeton.win")

local M = {}

-- How many composers this editor has opened, which is where their
-- names come from.
--
-- A name apiece rather than one name, because two can be open at once:
-- rewriting what you said last week and then writing something new on
-- the line under it is one movement, and Neovim refuses a second
-- buffer called what the first is called -- with an E95 out of its own
-- guts, in the middle of a keypress that had nothing wrong with it.
local opened = 0

-- What a half-written word can turn into: the `@name` of somebody on
-- the project, and the `:name:` of an emoji. Each says for itself
-- whether the cursor is in one of its words, and each is switched off
-- by its own setting.
local SOURCES = {
  { module = "nemeton.mentions", on = "mentions", menu = "mention_menu" },
  { module = "nemeton.emoji", on = "emoji", menu = "emoji_menu" },
}

--- The sources switched on, in the order they are asked.
local function sources()
  local out = {}
  for _, source in ipairs(SOURCES) do
    if config.compose[source.on] then
      table.insert(out, vim.tbl_extend("keep", { it = require(source.module) }, source))
    end
  end
  return out
end

--- Whichever source the cursor is inside a word of, and where that word
--- starts. Nothing where it is inside none.
local function starts_here()
  for _, source in ipairs(sources()) do
    local at = source.it.omnifunc(1, nil)
    if at >= 0 then
      return source, at
    end
  end
  return nil, -3
end

--- Completion for `@name` and `:name:`, on this buffer alone.
---
--- `omnifunc` rather than a completion engine: this plugin has no
--- dependencies and is not about to grow one over a menu. `<C-x><C-o>`
--- is where a Vim user looks for a list of what fits here, and anybody
--- with an engine can point it at `nemeton.mentions.candidates` or
--- `nemeton.emoji.candidates` -- which is why those are functions and
--- not closures in this file.
---
--- One `omnifunc` for the two of them, because there is one
--- `omnifunc`. Which is being typed is the sigil in front of the
--- cursor, and no word begins with both.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local _, at = starts_here()
    return at
  end
  for _, source in ipairs(sources()) do
    if (base or ""):sub(1, 1) == source.it.sigil then
      return source.it.omnifunc(0, base)
    end
  end
  return {}
end

--- Hangs it on the buffer.
---
--- The menu comes up on its own only where `completeopt` can be held
--- for one buffer, which is Neovim 0.11. Older, setting it globally
--- would change how completion behaves in every other buffer of the
--- editor for the length of a comment, and a menu that picks the first
--- name for you is worse than no menu at all.
local function completion_on(buf, window)
  local on = sources()
  if #on == 0 then
    return
  end
  for _, source in ipairs(on) do
    if source.it.prefetch then
      source.it.prefetch(require("nemeton.session").root())
    end
  end
  vim.bo[buf].omnifunc = "v:lua.require'nemeton.compose'.omnifunc"
  local wanted = false
  for _, source in ipairs(on) do
    wanted = wanted or config.compose[source.menu]
  end
  local held = wanted
    and pcall(function()
      vim.bo[buf].completeopt = "menu,menuone,noselect"
    end)
  if not held then
    return
  end
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    desc = "nemeton: what an @ or a : can turn into",
    callback = function()
      if vim.fn.pumvisible() == 1 or vim.api.nvim_get_current_win() ~= window then
        return
      end
      -- Asked of the same function the menu is filled from, so there is
      -- one answer to "is this an @ that means somebody": a mention
      -- that would not complete does not put a menu up either.
      local source = starts_here()
      if source and config.compose[source.menu] then
        vim.api.nvim_feedkeys(vim.keycode("<C-x><C-o>"), "n", false)
      end
    end,
  })
end

--- opts.title    -- shown in the winbar, says what this comment attaches to
--- opts.body     -- text to start from, for editing something already said
--- opts.on_draft(text)  -- the same, for a comment kept rather than sent
--- opts.on_submit(text) -- called with the body; the window is already gone
--- opts.default  -- "keep" or "post": which of the two the first key and
---                  `:w` do. "keep" where both are given and it is not
---                  said, because a review is written as a whole.
--- opts.lang     -- the treesitter language of the code in a
---                  `suggestion` fence, for the one comment that has
---                  code in it. See `nemeton.syntax`.
--- opts.empty    -- whether an empty buffer is an answer. It is not for
---                  a comment, which is why the default is no; it is
---                  for a merge request's description, which has to be
---                  able to go away again once it is written.
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
  opened = opened + 1
  vim.api.nvim_buf_set_name(buf, ("nemeton://compose/%d"):format(opened))

  local back = win.came_from()
  vim.cmd(("botright %dsplit"):format(config.compose.height))
  local window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(window, buf)
  local k = config.keys.compose
  -- What the first key does, and what is left for the second. Posting
  -- when the caller asked for it, and when keeping is not on offer at
  -- all -- an edit of something already posted has nowhere to be kept.
  local posts = opts.default == "post" or not opts.on_draft
  local first = (posts and opts.on_submit) or opts.on_draft
  local second = (posts and opts.on_draft) or (opts.on_draft and opts.on_submit) or nil
  vim.wo[window].winbar = ("%%#NemetonAuthor#%s%%*  %%#NemetonHint#%s %s%s · %s cancel%%*"):format(
    opts.title or "comment",
    k.keep,
    posts and "send" or "keep",
    second and (" · " .. k.post .. " " .. (posts and "keep for the review" or "post now")) or "",
    k.cancel
  )
  completion_on(buf, window)
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].spell = true

  local function close()
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
    -- Every way out of this window ends in the same place: the line the
    -- comment is about, which is where you were reading.
    back()
  end

  -- ...including the ways out that are not this plugin's. `:q`,
  -- `<C-w>c`, `:close` -- a split is a split and people close one the
  -- way they close any other, and none of those goes through `close`
  -- above. Neovim then hands the cursor to the first window of the
  -- layout, which is the top left one and not where the composer was
  -- opened from: writing a merge request's description and being put
  -- back in a file three windows away is a window that lets go of you.
  --
  -- Scheduled, because this runs while the window is still being taken
  -- down and a cursor moved in the middle of that does not stay moved.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(window),
    once = true,
    desc = "nemeton: back to where the composer was opened from",
    callback = function()
      vim.schedule(back)
    end,
  })

  --- `send` is what to do with the text: posted now, or kept unsent.
  --- Two exits from one window rather than two windows, because the
  --- choice is made at the end of writing it and not before.
  local function finish(send)
    return function()
      local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      if text == "" and not opts.empty then
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
    vim.api.nvim_win_set_cursor(window, { #lines, #lines[#lines] })
  else
    vim.cmd("startinsert")
  end
  -- After the text is in, not before: the first paint is of what is
  -- there, and what is there arrives on the line above.
  if opts.lang then
    require("nemeton.syntax").attach(buf, opts.lang)
  end
  return buf
end

return M
