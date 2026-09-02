-- What CI actually did, job by job.
--
-- "failed" on the heading is where the question starts, not where it
-- ends: which job, in which stage, and for how long it ran before it
-- gave up. That is a table, and a table wants a window.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil
-- Line number (1-based) -> the job drawn on it.
local rows = {}

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows = nil, nil, {}
end

--- "1m12s", "8s", "—". Seconds as GitLab sends them: a float, and null
--- for a job that has not run.
local function duration(secs)
  if type(secs) ~= "number" then
    return "—"
  end
  secs = math.floor(secs + 0.5)
  if secs < 60 then
    return ("%ds"):format(secs)
  end
  return ("%dm%02ds"):format(math.floor(secs / 60), secs % 60)
end

--- The jobs as lines, grouped under their stages.
---
--- Grouped in the order the stages first appear rather than sorted:
--- that order is the pipeline's own, and a reviewer reading down the
--- window is reading the build in the order it happened.
function M.lines(jobs)
  local out, hls, map = {}, {}, {}
  local seen, order = {}, {}
  for _, job in ipairs(jobs or {}) do
    local stage = job.stage or "?"
    if not seen[stage] then
      seen[stage] = {}
      table.insert(order, stage)
    end
    table.insert(seen[stage], job)
  end

  for _, stage in ipairs(order) do
    if #out > 0 then
      table.insert(out, "")
    end
    table.insert(hls, { row = #out, col = 0, end_col = #stage, hl = "NemetonAuthor" })
    table.insert(out, stage)
    for _, job in ipairs(seen[stage]) do
      local status = detail.status(job.status) or { glyph = "•", hl = "NemetonMeta" }
      local prefix = "  " .. status.glyph .. " "
      local line = ("%s%-34s %8s  %s"):format(
        prefix,
        (job.name or "?"):sub(1, 34),
        duration(job.duration),
        job.allow_failure and "(allowed to fail)" or ""
      )
      table.insert(hls, {
        row = #out,
        col = 2,
        end_col = 2 + #status.glyph,
        hl = status.hl,
      })
      table.insert(out, (line:gsub("%s+$", "")))
      map[#out] = job
    end
  end
  if #out == 0 then
    out = { "this pipeline has no jobs" }
  end
  return out, hls, map
end

local function job_at()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  return rows[vim.api.nvim_win_get_cursor(M.win)[1]]
end

local function draw(jobs, pipeline)
  local lines, hls, map = M.lines(jobs)
  rows = map
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_config(M.win, {
      title = (" pipeline #%s · %s "):format(pipeline.id or "?", pipeline.word or "?"),
      title_pos = "center",
    })
  end
end

--- The jobs of the open merge request's head pipeline, in a float.
function M.open()
  local mr = session.current
  if not mr then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  local pipeline = detail.ci(mr)
  if not pipeline or not pipeline.id then
    session.notify(("!%d has no pipeline"):format(mr.iid), vim.log.levels.WARN)
    return
  end

  M.close()
  local width = math.min(math.floor(vim.o.columns * 0.6), 76)
  local height = math.max(4, math.floor(vim.o.lines * 0.5))
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  local back = win.came_from()
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" pipeline #%s "):format(pipeline.id),
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true

  local k = config.keys.jobs
  vim.wo[M.win].winbar = detail.hint({
    { k.log, "log" },
    { k.browser, "browser" },
    { k.refresh, "refresh" },
    { k.quit, "quit" },
  })

  local function load()
    glab.pipeline_jobs(mr.root, pipeline.id, function(data, err)
      if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        return
      end
      if not data then
        draw({}, pipeline)
        session.notify("could not read the jobs: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      draw(data, pipeline)
    end)
  end

  local bindings = {
    -- `q` puts the cursor back where it was; the keys below that
    -- close this window are on their way somewhere and must not.
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close",
    },
    { k.refresh, load, "refetch" },
    -- In a tab, and this window is left standing in the one it was
    -- opened from: a log is read against the list of jobs it came out
    -- of, and closing the tab is how you get back to it.
    {
      k.log,
      function()
        local job = job_at()
        if job then
          require("nemeton.trace").open(job)
        end
      end,
      "what this job printed",
    },
    {
      k.browser,
      function()
        local job = job_at()
        local url = (job and job.web_url) or pipeline.url
        if url then
          vim.ui.open(url)
        end
      end,
      "open the job under the cursor on GitLab",
    },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set("n", b[1], b[2], { buffer = M.buf, nowait = true, desc = "nemeton: " .. b[3] })
    end
  end

  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { "…" })
  vim.bo[M.buf].modifiable = false
  load()
  return M.win
end

return M
