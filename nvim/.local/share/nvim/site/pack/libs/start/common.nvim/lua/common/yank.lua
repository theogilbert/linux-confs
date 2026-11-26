-- Text put where `p` and the system's paste will find it.
--
-- The unnamed register always, `+` where the editor has a clipboard,
-- and OSC 52 -- the terminal's own clipboard escape -- where asked:
-- the editor at the far end of an ssh session has no clipboard of its
-- own, and the terminal the reader is sitting at does.
--
-- `osc52` is one of
--   "auto"  -- only where the editor has no clipboard (the default)
--   true    -- always as well
--   false   -- never
-- per call, or for every call through `vim.g.common_yank_osc52`.

local M = {}

--- Sends `text` to the terminal's clipboard; false where there is no
--- terminal to send it to (headless, where the escape would be noise on
--- whatever stderr is). Replaceable, for specs.
function M.send(text)
  if #vim.api.nvim_list_uis() == 0 then
    return false
  end
  local ok, osc52 = pcall(require, "vim.ui.clipboard.osc52")
  if ok and osc52.copy then
    osc52.copy("+")(vim.split(text, "\n", { plain = true }), "v")
    return true
  end
  local b64 = vim.base64 and vim.base64.encode(text)
  if not b64 then
    return false
  end
  vim.api.nvim_chan_send(2, ("\027]52;c;%s\027\\"):format(b64))
  return true
end

local function has_clipboard()
  return vim.fn.has("clipboard") == 1
end

--- Copies `text` (a string, or a list of lines) and returns where it
--- went: a list out of `'"'`, `"+"` and `"osc52"`.
---
--- `opts.osc52`    -- see above
--- `opts.register` -- one more register to set, `a` say
--- `opts.notify`   -- a name for what was copied: "copied <it>" is said
function M.copy(text, opts)
  opts = opts or {}
  if type(text) == "table" then
    text = table.concat(text, "\n")
  end
  text = tostring(text)
  local went = {}
  vim.fn.setreg('"', text)
  table.insert(went, '"')
  if opts.register and opts.register ~= '"' then
    pcall(vim.fn.setreg, opts.register, text)
    table.insert(went, opts.register)
  end
  local clip = has_clipboard()
  if clip and pcall(vim.fn.setreg, "+", text) then
    table.insert(went, "+")
  end
  local osc52 = opts.osc52
  if osc52 == nil then
    osc52 = vim.g.common_yank_osc52
  end
  if osc52 == nil then
    osc52 = "auto"
  end
  if osc52 == true or (osc52 == "auto" and not clip) then
    if M.send(text) then
      table.insert(went, "osc52")
    end
  end
  if opts.notify then
    local where = #went > 1 and "" or ' (to the " register only)'
    vim.notify(("copied %s%s"):format(opts.notify, where), vim.log.levels.INFO)
  end
  return went
end

return M
