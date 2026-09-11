-- Acting on a thread that is already there: answering it, rewriting one
-- of its comments, deleting one.
--
-- Its own module because every surface that shows a conversation needs
-- these and none of them owns the others -- a thread on a line is
-- answered from the buffer, the same thread from the window that lists
-- them all, and the part in the middle is the same every time.

local compose = require("nemeton.compose")
local config = require("nemeton.config")
local emoji = require("nemeton.emoji")
local glab = require("nemeton.glab")
local prompt = require("nemeton.prompt")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

--- Whether the thing a key was pressed on is still on its way to the
--- forge, said out loud.
---
--- A comment drawn while it is being posted |nemeton-sending| is a
--- comment the forge has never heard of: there is no id to reply to,
--- resolve, rewrite, delete or react to, and a call built out of the
--- one this plugin invented would come back a 404 with a confusing
--- message on it. The answer is a second's wait, so that is what it
--- says.
local function in_flight(thread, note)
  if not ((note and note.sending) or (thread and thread.sending)) then
    return false
  end
  session.notify("that comment is still on its way to the forge", vim.log.levels.WARN)
  return true
end

--- `after` is what the window this was pressed in does with itself
--- once the forge has been asked again: the comments window stays open
--- over the list it just changed, and a list that still has the note
--- in it is a window that has to be refetched by hand to be believed.
local function rewrite(thread, note, after)
  local mr = session.current
  if in_flight(thread, note) then
    return
  end
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
      -- The new words on the note straight away, marked as not yet the
      -- forge's: a rewrite is a round trip, and a comment that goes on
      -- saying the old thing for half a second is a keypress you cannot
      -- tell worked.
      local sent = session.sending({ body = body, note_id = note.id, author = note.author })
      local function done(data, err)
        if not data then
          sent(false)
          session.refused("could not edit", err)
          return
        end
        session.notify("edited")
        sent(true)
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
  if in_flight(thread, note) then
    return
  end
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
          session.refused("could not delete", err)
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
---
--- The ones still on their way are not among them: there is nothing on
--- the forge to act on yet, and a list that offers one is a list with a
--- wrong answer in it.
local function pick(thread, question, fn, after)
  if not session.current or not thread then
    session.notify("no thread here", vim.log.levels.WARN)
    return
  end
  if in_flight(thread, nil) then
    return
  end
  local notes = vim.tbl_filter(function(note)
    return not note.sending
  end, thread.notes or {})
  if #notes == 0 then
    return
  end
  if #notes == 1 then
    return fn(thread, notes[1], after)
  end
  vim.ui.select(notes, {
    prompt = question,
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
  if in_flight(thread, nil) then
    return
  end
  if thread.draft then
    session.notify("that comment has not been sent yet — edit it instead", vim.log.levels.WARN)
    return
  end
  local to = thread.notes[1].author
  compose.open({
    title = ("!%d  reply to %s"):format(mr.iid, to),
    -- Filed under the thread it answers: an unfinished reply is one
    -- reply to one conversation, wherever in the review you go and
    -- whenever you come back. See `nemeton.kept`.
    remember = ("!%d reply %s"):format(mr.iid, thread.id),
    default = "post",
    on_draft = function(body)
      local sent = session.sending({ body = body, discussion_id = thread.id })
      glab.create_draft(mr.root, mr.iid, body, nil, thread.id, function(data, err)
        if not data then
          sent(false)
          session.refused("could not keep", err)
          return
        end
        session.notify("kept a reply to " .. to)
        sent(true)
        session.refresh()
      end)
    end,
    on_submit = function(body)
      local sent = session.sending({ body = body, discussion_id = thread.id })
      glab.reply(mr.root, mr.iid, thread.id, body, function(data, err)
        if not data then
          sent(false)
          session.refused("could not reply", err)
          return
        end
        session.notify("replied")
        sent(true)
        session.refresh()
      end)
    end,
  })
end

--- Resolves `thread`, or reopens it: whichever it is not.
---
--- Here rather than beside the key that used to be the only way to
--- press it, because it is the same verb from the pane, and a thread is
--- settled from wherever it is being read.
function M.resolve(thread)
  local mr = session.current
  if not mr or not thread then
    session.notify("no thread here", vim.log.levels.WARN)
    return
  end
  if in_flight(thread, nil) then
    return
  end
  if not thread.resolvable then
    session.notify("that thread cannot be resolved", vim.log.levels.WARN)
    return
  end
  local want = not thread.resolved
  glab.resolve(mr.root, mr.iid, thread.id, want, function(data, err)
    if not data then
      session.refused("could not resolve", err)
      return
    end
    session.notify(want and "resolved" or "reopened")
    session.refresh()
  end)
end

--- Reacts to one note of `thread`, or takes the reaction back.
---
--- One key and one gesture, because GitLab has one: picking an emoji
--- you have already given is how a reaction is removed there, and a
--- second key for "un-react" would be a second key for the same
--- button. The picker says which are already yours, so the gesture is
--- visible before it is made.
---
--- Removing costs a second call. The reactions this plugin draws come
--- from GraphQL, in one request for the whole review, and GraphQL does
--- not name a reaction with the id REST needs to delete it -- so the
--- one note is asked over REST at the moment a reaction is taken back,
--- which is rare and is one call.
-- The last row of the picker below, and not a name: the list it is at
-- the end of is short on purpose, and this is the way past it. A table
-- rather than a string so it cannot be confused with an emoji called
-- something unlucky.
local MORE = {}

local function react_to(thread, note, after)
  local mr = session.current
  if in_flight(thread, note) then
    return
  end
  if note.draft or thread.draft then
    session.notify(
      "that comment has not been sent yet — nothing to react to",
      vim.log.levels.WARN
    )
    return
  end

  -- What is offered: the names configured, and then anything already on
  -- the note that is not among them -- a reaction from the web page is
  -- one to join or, if it is yours, to take back.
  local given = {}
  for _, r in ipairs(note.reactions or {}) do
    given[r.name] = r
  end
  local names = vim.list_slice(config.comments.reaction_names or {})
  local offered = {}
  for _, name in ipairs(names) do
    offered[name] = true
  end
  for _, r in ipairs(note.reactions or {}) do
    if not offered[r.name] then
      table.insert(names, r.name)
    end
  end

  -- ...and the way past the list, which is short on purpose: the forge
  -- takes any name gemoji has, this plugin can draw the 258 it knows,
  -- and `vim.ui.select` is a numbered list for most people -- 258 rows
  -- of one is a wall rather than a picker. So the ten are the picker
  -- and this is the tail, on a prompt that completes over all of them
  -- |nemeton-prompt|.
  table.insert(names, MORE)

  --- Given, or -- where it is already yours -- taken back. One key and
  --- one gesture, because GitLab has one.
  local function toggle(name)
    if not (given[name] and given[name].mine) then
      glab.award(mr.root, mr.iid, note.id, name, function(data, err)
        if not data then
          session.refused("could not react", err)
          return
        end
        session.refresh(after)
      end)
      return
    end
    glab.note_awards(mr.root, mr.iid, note.id, function(awards, err)
      local id = nil
      for _, award in ipairs(type(awards) == "table" and awards or {}) do
        if award.name == name and vim.tbl_get(award, "user", "username") == mr.me then
          id = award.id
        end
      end
      if not id then
        session.notify(
          "could not find that reaction to take back: " .. tostring(err or "it is not there"),
          vim.log.levels.ERROR
        )
        return
      end
      glab.unaward(mr.root, mr.iid, note.id, id, function(ok, why)
        if not ok then
          session.refused("could not take it back", why)
          return
        end
        session.refresh(after)
      end)
    end)
  end

  --- ...and the other 248, asked for by name.
  ---
  --- A prompt rather than a longer list, and this plugin's own prompt
  --- rather than `vim.ui.input` |nemeton-prompt|: the menu is the whole
  --- of what this window is for, and `completion` is the half of the
  --- `input` contract that half its replacements drop. So a float with
  --- the names behind it, coming up as they are typed and each with its
  --- picture beside it.
  ---
  --- What comes back is taken at its word. A name this plugin knows is
  --- the reaction; a prefix that only one name answers is that name,
  --- since the reader who typed it saw the menu say so; and anything
  --- else goes to the forge as it was typed, because gemoji is eighteen
  --- hundred names and this knows two hundred and fifty of them.
  local function ask()
    prompt.open({
      title = "react with",
      omnifunc = "v:lua.require'nemeton.emoji'.name_omnifunc",
      items = function(line)
        return emoji.name_omnifunc(0, line)
      end,
    }, function(answer)
      -- The name off the front, so a candidate chosen out of the menu
      -- and a name typed over it are one answer -- and `:tada:`, which
      -- is how it is written in a comment and so how it arrives pasted
      -- from one.
      local name = vim.trim(answer or ""):match("^:?([%w_+%-]+)")
      if not name then
        return
      end
      if not emoji.by_name[name] then
        local could_be = emoji.candidates(name)
        if #could_be == 1 then
          name = could_be[1]
        end
      end
      toggle(name)
    end)
  end

  vim.ui.select(names, {
    prompt = "react to " .. note.author,
    format_item = function(name)
      if name == MORE then
        return "…  another emoji"
      end
      local mine = given[name] and given[name].mine
      return ("%s  %s%s"):format(
        threads.emoji(":" .. name .. ":"),
        name,
        mine and "  (yours — take it back)" or ""
      )
    end,
  }, function(name)
    if not name then
      return
    end
    if name == MORE then
      return ask()
    end
    toggle(name)
  end)
end

--- ...and the same, asking which note when the caller does not say.
function M.react(thread, after, note)
  if not config.comments.reactions then
    session.notify("reactions are off — comments.reactions", vim.log.levels.WARN)
    return
  end
  if note then
    return react_to(thread, note, after)
  end
  pick(thread, "react to which comment", react_to, after)
end

--- Deletes one note of `thread`, after asking. A thread whose only note
--- goes is gone with it -- that is GitLab's rule, not ours.
---
--- `note` is the one to act on where the caller knows which: a window
--- that draws the whole conversation knows which comment the cursor is
--- standing on, and asking a reader to pick out of a list what they are
--- already pointing at is a question with the answer in it. Without
--- one -- a summary, a marker in the gutter -- the thread is asked
--- about instead.
function M.delete(thread, after, note)
  if note then
    return remove(thread, note, after)
  end
  pick(thread, "delete which comment", remove, after)
end

--- Edits one note of `thread`, asking which when the caller does not
--- say and the thread has more than one. Not filtered to your own: this
--- plugin does not know who you are without another call, and GitLab
--- already refuses the ones that are not yours -- with a message that
--- says so.
function M.thread(thread, after, note)
  if note then
    return rewrite(thread, note, after)
  end
  pick(thread, "edit which comment", rewrite, after)
end

return M
