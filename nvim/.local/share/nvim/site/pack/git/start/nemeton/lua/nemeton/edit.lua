-- Acting on a thread that is already there: answering it, rewriting one
-- of its comments, deleting one.
--
-- Its own module because every surface that shows a conversation needs
-- these and none of them owns the others -- a thread on a line is
-- answered from the buffer, the same thread from the window that lists
-- them all, and the part in the middle is the same every time.

local compose = require("nemeton.compose")
local glab = require("nemeton.glab")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

--- `after` is what the window this was pressed in does with itself
--- once the forge has been asked again: the comments window stays open
--- over the list it just changed, and a list that still has the note
--- in it is a window that has to be refetched by hand to be believed.
local function rewrite(thread, note, after)
  local mr = session.current
  compose.open({
    title = ("!%d  edit %s"):format(
      mr.iid,
      (note.draft or thread.draft) and "the comment you have not sent"
        or (note.author .. "'s comment")
    ),
    body = note.body,
    on_submit = function(body)
      if body == vim.trim(note.body) then
        session.notify("unchanged")
        return
      end
      local function done(data, err)
        if not data then
          session.notify("could not edit: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify("edited")
        session.refresh(after)
      end
      -- An unsent comment lives at its own endpoint until it is sent --
      -- a whole thread of one, or a reply folded into somebody else's --
      -- and the line it was written against goes back with the new
      -- text, because GitLab keeps only the position the update
      -- carries. A posted note keeps its own.
      if note.draft or thread.draft then
        glab.update_draft(mr.root, mr.iid, note.id, body, note.position, done)
      else
        glab.update_note(mr.root, mr.iid, note.id, body, done)
      end
    end,
  })
end

--- The confirmation, as one replaceable function: deleting a comment
--- is the only thing in this plugin that cannot be undone -- GitLab
--- keeps no copy and neither do we -- and the suite has to be able to
--- answer a prompt that a headless Neovim cannot see.
---
--- `vim.ui.select` rather than `vim.fn.confirm`, and for the same
--- reason the note is chosen with one: whatever the user has put in
--- front of `vim.ui.select` is the picker they answer questions in
--- every day, and a modal on the command line is the one window in
--- this plugin that would not look like the rest of their editor.
--- "Cancel" is first, so the reflex answer is the harmless one.
function M.confirm(question, done)
  vim.ui.select({ "Cancel", "Delete" }, { prompt = question }, function(choice)
    done(choice == "Delete")
  end)
end

local function remove(thread, note, after)
  local mr = session.current
  local first = vim.split(threads.drawn(note.body), "\n", { plain = true })[1] or ""
  M.confirm(
    ("Delete %s: %s"):format(
      (note.draft or thread.draft) and "the comment you have not sent"
        or (note.author .. "'s comment"),
      first:sub(1, 60)
    ),
    function(yes)
      if not yes then
        return
      end
      local drop = (note.draft or thread.draft) and glab.delete_draft or glab.delete_note
      drop(mr.root, mr.iid, note.id, function(ok, err)
        if not ok then
          session.notify("could not delete: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify("deleted")
        session.refresh(after)
      end)
    end
  )
end

--- Picks one note out of a thread and hands it to `fn`, asking which
--- when there is more than one to ask about.
local function pick(thread, prompt, fn, after)
  if not session.current or not thread then
    session.notify("no thread here", vim.log.levels.WARN)
    return
  end
  local notes = thread.notes or {}
  if #notes == 0 then
    return
  end
  if #notes == 1 then
    return fn(thread, notes[1], after)
  end
  vim.ui.select(notes, {
    prompt = prompt,
    format_item = function(note)
      return ("%s: %s"):format(
        note.author,
        vim.split(threads.drawn(note.body), "\n", { plain = true })[1]
      )
    end,
  }, function(choice)
    if choice then
      fn(thread, choice, after)
    end
  end)
end

--- A reply into `thread`: posted on the spot, or kept for the review by
--- the composer's other key.
---
--- Posted by default, unlike a new thread. A reply is half of a
--- conversation somebody else is already in: kept, it is invisible to
--- them and invisible in the thread it answers -- GitLab files an
--- unsent reply with your other drafts rather than under the note it
--- was written against -- until the review is published. A remark of
--- your own can wait for the whole review; an answer to a question
--- cannot.
function M.reply(thread)
  local mr = session.current
  if not mr or not thread then
    session.notify("no thread here", vim.log.levels.WARN)
    return
  end
  if thread.draft then
    session.notify("that comment has not been sent yet — edit it instead", vim.log.levels.WARN)
    return
  end
  local to = thread.notes[1].author
  compose.open({
    title = ("!%d  reply to %s"):format(mr.iid, to),
    default = "post",
    on_draft = function(body)
      glab.create_draft(mr.root, mr.iid, body, nil, thread.id, function(data, err)
        if not data then
          session.notify("could not keep: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify("kept a reply to " .. to)
        session.refresh()
      end)
    end,
    on_submit = function(body)
      glab.reply(mr.root, mr.iid, thread.id, body, function(data, err)
        if not data then
          session.notify("could not reply: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify("replied")
        session.refresh()
      end)
    end,
  })
end

--- Deletes one note of `thread`, after asking. A thread whose only note
--- goes is gone with it -- that is GitLab's rule, not ours.
function M.delete(thread, after)
  pick(thread, "delete which comment", remove, after)
end

--- Edits one note of `thread`, asking which when the thread has more
--- than one. Not filtered to your own: this plugin does not know who
--- you are without another call, and GitLab already refuses the ones
--- that are not yours -- with a message that says so.
function M.thread(thread, after)
  pick(thread, "edit which comment", rewrite, after)
end

return M
