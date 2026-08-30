-- Mapping lifecycle. Knows nothing about which pane calls it.
--
-- The side pane's buffer is a scratch one, created and thrown away with
-- the pane, so nothing pre-existing is at risk there. The diff view is a
-- different matter: it maps over a buffer you are working in, and the
-- pane lends its own keys to buffers it does not own -- both have to
-- leave them exactly as they were found.

local M = {}

--- Applies `mappings` (a list of { lhs, rhs, opts }) to `bufnr`, saving
--- whatever was mapped to each lhs first. Returns the saved table for
--- restore().
---
--- Only a mapping that was already buffer-local to THIS buffer is worth
--- saving. `maparg` reports the mapping in EFFECT, so a global one comes
--- back here too -- and putting that one "back" would re-create it
--- globally while our buffer-local mapping still shadowed it, leaving the
--- buffer permanently bound to us. A global mapping needs nothing doing:
--- deleting ours re-exposes it, which is what restore does.
function M.apply(bufnr, mode, mappings)
  local saved = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return saved
  end
  -- maparg and mapset both read and write the CURRENT buffer's mappings,
  -- so both have to run with the target buffer current.
  vim.api.nvim_buf_call(bufnr, function()
    for _, m in ipairs(mappings) do
      if m.lhs and m.lhs ~= "" then
        local prev = vim.fn.maparg(m.lhs, mode, false, true)
        saved[m.lhs] = (prev.lhs and prev.lhs ~= "" and prev.buffer == 1) and prev or false
        vim.keymap.set(mode, m.lhs, m.rhs, vim.tbl_extend("force", {
          buffer = bufnr,
          nowait = true,
          silent = true,
        }, m.opts or {}))
      end
    end
  end)
  return saved
end

--- Puts back whatever apply() found: ours goes first, then any
--- buffer-local mapping that was there before. Uses mapset with the dict
--- form so a previous Lua callback survives the round trip.
function M.restore(bufnr, mode, saved)
  if not saved or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_call(bufnr, function()
    for lhs, prev in pairs(saved) do
      pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
      if prev then
        pcall(vim.fn.mapset, mode, false, prev)
      end
    end
  end)
end

return M
