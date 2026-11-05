local M = {}

M.config = {
  -- Follow derivations (`c = f(a, b)` -> a, b, f) instead of stopping at them.
  derive = false,
  -- Keep auto-expanding while a node has a single expandable child.
  auto_expand = 4,
  -- Depth limit for recursive opening (zO, zA, zR, zn): nodes resolve lazily,
  -- so unbounded recursion could fan out across the codebase.
  fold_depth = 6,
  width = 60,
  position = "left", -- "left" | "right"
  max_text = 60,
  -- Step markers. Box-drawing junctions keep the chain one unbroken line and
  -- render aligned in any font with box drawing (unlike ●/◆, often missing
  -- from coding fonts and drawn from a fallback font).
  icons = {
    traced = "╋", -- the symbol being traced
    expanded = "┿", -- its upstream is shown above
    collapsed = "┼", -- more upstream, hidden: expand it
    done = "╪", -- end of the chain: nothing further upstream
    loading = "╂",
  },
  keymaps = {
    jump = { "<CR>" },
    preview = { "p" },
    toggle = { "o", "<Tab>", "l" },
    collapse = { "h" },
    reroot = { "R" },
    derive = { "d" },
    refresh = { "r" },
    close = { "q" },
    help = { "g?" },
    hover = { "K" },
    -- Global while the pane is open (restored on close).
    next = { "]s" },
    prev = { "[s" },
    -- Cycle between the paths leading to the selected step.
    next_path = { "]r" },
    prev_path = { "[r" },
  },
}

local HL = {
  SalmonSYM = "Title",
  SalmonDEF = "Function",
  SalmonCND = "DiagnosticWarn",
  SalmonALS = "Identifier",
  SalmonDRV = "Type",
  SalmonUPD = "Type",
  SalmonMUT = "DiagnosticHint",
  SalmonRD = "Comment",
  SalmonPRM = "Special",
  SalmonARG = "Constant",
  SalmonFOR = "Repeat",
  SalmonIMP = "Include",
  SalmonSRC = "Identifier",
  SalmonFN = "Function",
  SalmonRET = "Keyword",
  SalmonLocation = "Comment",
  SalmonOrigin = "CursorLine",
  SalmonSymbol = "Search",
  SalmonSymbolOrigin = "IncSearch",
  SalmonSource = "DiffText",
  SalmonSelected = "Visual",
  SalmonGraph = "Comment",
  SalmonFlow = "Special",
  SalmonFlowStep = "Title",
  SalmonOffPath = "Comment",
}

local function set_highlights()
  for group, link in pairs(HL) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  set_highlights()
end

set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("salmon_hl", { clear = true }),
  callback = set_highlights,
})

local function ui()
  return require("salmon.ui")
end

-- Public API ------------------------------------------------------------------
--
-- Every function works directly as a keymap callback, e.g.
--   vim.keymap.set("n", "<leader>lt", require("salmon").trace)

---@class salmon.TraceOpts
---@field derive? boolean Set derive mode before tracing (persists, like set_derive()).
---@field focus? boolean Move focus to the pane (default: true).

local function apply(opts)
  opts = type(opts) == "table" and opts or {}
  if opts.derive ~= nil then
    M.config.derive = opts.derive
  end
  return opts
end

--- Trace the identifier at a position.
---@param buf integer
---@param row integer 0-based
---@param col integer 0-based byte column
---@param opts? salmon.TraceOpts|{ win?: integer }
function M.trace_at(buf, row, col, opts)
  opts = apply(opts)
  local root = require("salmon.trace").root(buf, row, col)
  if not root then
    vim.notify("salmon: no identifier under cursor (or no tree-sitter parser)", vim.log.levels.WARN)
    return
  end
  ui().open(root, opts.win, opts.focus ~= false)
end

--- Trace the identifier under the cursor.
---@param opts? salmon.TraceOpts
function M.trace(opts)
  local win = vim.api.nvim_get_current_win()
  if ui().is_open() and win == ui().state.win then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(win)
  opts = vim.tbl_extend("force", type(opts) == "table" and opts or {}, { win = win })
  M.trace_at(vim.api.nvim_get_current_buf(), pos[1] - 1, pos[2], opts)
end

--- Close the pane if open, otherwise trace the identifier under the cursor.
---@param opts? salmon.TraceOpts
function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.trace(opts)
  end
end

function M.close()
  ui().close()
end

---@return boolean
function M.is_open()
  return ui().is_open()
end

--- Rebuild the chain from the current root (e.g. after editing).
function M.refresh()
  local root = ui().state.root
  if root and M.is_open() then
    M.trace_at(root.buf, root.row, root.col, { focus = vim.api.nvim_get_current_win() == ui().state.win })
  end
end

--- Step forward along the chain, towards the traced symbol, and show it
--- (no-op if closed).
function M.next()
  ui().step(1)
end

--- Step back along the chain, towards the definition, expanding collapsed
--- steps on the way, and show it (no-op if closed).
function M.prev()
  ui().step(-1)
end

--- Show the next path leading to the selected step: changes the sign column
--- and where `[s` leads (no-op if closed).
function M.next_path()
  ui().cycle_path(1)
end

--- Show the previous path leading to the selected step (no-op if closed).
function M.prev_path()
  ui().cycle_path(-1)
end

---@return boolean
function M.derive()
  return M.config.derive
end

--- Enable/disable derive mode; refreshes an open pane.
---@param enabled boolean
function M.set_derive(enabled)
  M.config.derive = enabled and true or false
  vim.notify("salmon: derive " .. (M.config.derive and "on" or "off"))
  M.refresh()
end

function M.toggle_derive()
  M.set_derive(not M.config.derive)
end

return M
