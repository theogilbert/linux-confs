-- What one CI job printed, in a tab of its own.
--
-- A tab rather than a float, which is what every other window here is: a
-- build log is thousands of lines and is read by searching it -- `/
-- error`, `n`, `G` -- and a float over the middle of the editor is the
-- wrong shape for that. It is also the one thing this plugin shows that
-- you want to keep open while you go back to the code and look at what
-- it is complaining about, which is what tabs are.
--
-- The jobs window is left standing in the tab it was opened in, so
-- closing this one puts you back in front of the list of jobs.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local glab = require("nemeton.glab")
local session = require("nemeton.session")

local M = {}

M.buf = nil

--- A trace as lines a buffer can hold.
---
--- A runner's output is a terminal's: SGR escapes for the colours, `\r`
--- to rewrite a line in place, and GitLab's own `section_start:` markers
--- around each step. None of it means anything in a buffer, and the
--- escapes are not even printable -- left in, they are drawn as `<89>`
--- soup with the log somewhere inside it.
---
--- The carriage returns are a progress bar: each one rewrote the line,
--- so what the line ended up saying is the piece after the last of them
--- and the pieces before it are frames of an animation nobody is
--- watching. Keeping only the last is what a terminal would have shown.
---
--- Pure, and public, because it is the half of this module that can be
--- tested without a forge or a window.
function M.log_lines(text)
  local out = {}
  for _, line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    -- Escapes first: a section marker ends in one, and the `\r` this
    -- splits on is inside it.
    line = line:gsub("\27%[[%d;?]*%a", "")
    line = line:gsub("\27%][^\7\27]*[\7\27]?", "")
    line = line:gsub("\r+$", "")
    line = line:match("[^\r]*$") or line
    -- `section_start:1699999999:step_script` and its `section_end`
    -- twin: machine-readable, and written in front of the heading a
    -- person actually wants. The marker goes, the heading stays.
    line = line:gsub("section_%a+:%d+:[%w_%-%.]+", "")
    -- Anything else that is not text: a bell, a backspace, an escape
    -- with nothing this knows how to read after it.
    line = line:gsub("[%z\1-\8\11\12\14-\31\127]", "")
    table.insert(out, line)
  end
  -- A trace ends in a newline, and splitting on it leaves one empty
  -- string past the end that is not a line of anything.
  if out[#out] == "" then
    table.remove(out)
  end
  if #out == 0 then
    out = { "(this job printed nothing)" }
  end
  return out
end

local function draw(lines)
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
end

--- The tab this opened, closed. Only the tab: the buffer goes with it,
--- and the jobs window it was opened from is in another one.
local function close()
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose")
  else
    -- The one tab there is cannot be closed. Wiping the buffer is the
    -- same gesture in a window that has nowhere to go.
    vim.cmd("bwipeout")
  end
  M.buf = nil
end

--- `job` is one of the objects `pipeline_jobs` returned: its id is what
--- the trace is asked for, and its name and status are what the tab is
--- called.
function M.open(job)
  local mr = session.current
  if not mr then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  if not (job and job.id) then
    return
  end

  vim.cmd("tabnew")
  M.buf = vim.api.nvim_get_current_buf()
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "wipe"
  vim.bo[M.buf].swapfile = false
  -- Named after the job rather than after the plugin: this is what the
  -- tabline has room to say, and "unit" is the answer to "which of
  -- these tabs is the failing one".
  vim.api.nvim_buf_set_name(M.buf, ("nemeton://job/%s/%s"):format(job.id, job.name or "job"))
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].spell = false

  local k = config.keys.log
  local status = detail.status(job.status)
  vim.wo[win].winbar = ("%%#NemetonAuthor#%s%%*  %%#%s#%s %s%%*  %s"):format(
    job.name or "job",
    status and status.hl or "NemetonMeta",
    status and status.glyph or "",
    status and status.word or "",
    detail.hint({ { k.refresh, "refresh" }, { k.browser, "browser" }, { k.quit, "quit" } })
  )

  local function load()
    draw({ "…" })
    glab.job_trace(mr.root, job.id, function(text, err)
      if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        return
      end
      if not text then
        draw({ "could not read the log: " .. tostring(err) })
        return
      end
      draw(M.log_lines(text))
      -- At the end of it, where a failure is. A log is read backwards
      -- from what went wrong far more often than forwards from the
      -- runner picking the job up.
      local w = vim.fn.bufwinid(M.buf)
      if w ~= -1 then
        vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(M.buf), 0 })
      end
    end)
  end

  local bindings = {
    { k.quit, close, "close this log" },
    -- A running job has more of it every second, and this is the one
    -- window here whose subject is still being written.
    { k.refresh, load, "refetch the log" },
    {
      k.browser,
      function()
        if job.web_url then
          vim.ui.open(job.web_url)
        end
      end,
      "open this job on GitLab",
    },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set("n", b[1], b[2], { buffer = M.buf, nowait = true, desc = "nemeton: " .. b[3] })
    end
  end

  load()
  return M.buf
end

return M
