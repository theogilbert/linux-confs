local M = {}
local H = {}

---Clipboard backend selection.
---
---Inside tmux we deliberately avoid nvim's automatic provider: it picks
---`tmux load-buffer -w`, and that `-w` tells tmux to forward every yank to the
---outer terminal over OSC 52.  Combined with `clipboard=unnamedplus` that is
---one escape sequence per delete, so a held `x` floods the terminal emulator
---until one of the writes stalls for several seconds.
---
---  - "tmux"  : yanks stay on the tmux server.  Shared by every nvim running
---              in the same tmux server, nothing crosses the ssh link.
---  - "osc52" : yanks are pushed to the terminal emulator, i.e. to the
---              physical machine's clipboard.  Opt-in, because of the above.
---
---Outside of tmux the "tmux" backend means "let nvim autodetect", which picks
---wl-copy / xsel on a local desktop.

M.TMUX = "tmux"
M.OSC52 = "osc52"

---Backend currently applied, one of M.TMUX / M.OSC52.
M.backend = M.OSC52

---Backend used when neither the caller nor an override has an opinion.
local FALLBACK = M.OSC52

---Machine-local default, deliberately outside of the dotfiles repo so that
---each machine can disagree with M.DEFAULT.  Written by M.toggle().
local STATE_FILE = vim.fs.joinpath(vim.fn.stdpath("state"), "clipboard-backend")

local TMUX_COPY = { "tmux", "load-buffer", "-" }
-- nvim's builtin tmux provider pastes with `tmux refresh-client -l && sleep
-- 0.05 && tmux save-buffer -`.  The `-l` asks the terminal for its clipboard
-- over OSC 52, which write-only terminals (Windows Terminal) never answer, so
-- we read tmux's own buffer directly instead.
local TMUX_PASTE = { "tmux", "save-buffer", "-" }

---@return boolean # True when this nvim runs inside a usable tmux server
function H.in_tmux()
    return vim.env.TMUX ~= nil and vim.env.TMUX ~= "" and vim.fn.executable("tmux") == 1
end

---Build the `g:clipboard` value for a backend.
---
---@param backend string One of M.TMUX / M.OSC52
---@return table|nil # `g:clipboard` value, or nil to fall back on autodetection
function H.build(backend)
    if backend == M.TMUX then
        if not H.in_tmux() then
            return nil -- Local desktop: nvim autodetection (wl-copy, xsel, ...)
        end

        return {
            name = "tmux-local",
            copy = { ["+"] = TMUX_COPY, ["*"] = TMUX_COPY },
            paste = { ["+"] = TMUX_PASTE, ["*"] = TMUX_PASTE },
            cache_enabled = 1,
        }
    end

    local osc52 = require("vim.ui.clipboard.osc52")

    -- Only the copy direction goes out to the physical machine.  Terminals
    -- that implement OSC 52 writes commonly refuse OSC 52 reads, and nvim then
    -- blocks up to 10s waiting for an answer that never comes, so reads keep
    -- using the local buffer whenever there is one.
    local paste = H.in_tmux() and { ["+"] = TMUX_PASTE, ["*"] = TMUX_PASTE }
        or { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") }

    return {
        name = "osc52",
        copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
        paste = paste,
        cache_enabled = 1,
    }
end

---Switch the clipboard provider over to a backend, right now.
---
---@param backend string One of M.TMUX / M.OSC52
function H.apply(backend)
    M.backend = backend
    vim.g.clipboard = H.build(backend)

    -- Reload recipe documented at the top of autoload/provider/clipboard.vim:
    -- the provider caches its commands, so g:clipboard alone is not enough.
    vim.g.loaded_clipboard_provider = nil
    vim.cmd("runtime autoload/provider/clipboard.vim")
end

---@return string # Name of the provider nvim actually ended up using
function M.provider_name()
    local name = vim.fn["provider#clipboard#Executable"]()
    return name ~= "" and name or "none"
end

---@param backend string|nil
---@return string|nil # The backend, if it is one we know about
function H.valid(backend)
    if backend == M.TMUX or backend == M.OSC52 then
        return backend
    end
    return nil
end

---@return string|nil # Backend remembered on this machine, if any
function H.persisted()
    local ok, lines = pcall(vim.fn.readfile, STATE_FILE)
    if not ok then
        return nil
    end
    return H.valid(vim.trim(lines[1] or ""))
end

---@class ClipboardOptions
---@field default string|nil Backend to use when nothing overrides it,
---                          "tmux" or "osc52".  Defaults to "osc52".

---Apply the effective backend.  Called from settings.lua.
---
---In order of priority: $NVIM_CLIPBOARD, the machine-local default remembered
---by M.toggle(), `opts.default`, then FALLBACK.
---
---@param opts ClipboardOptions|nil
function M.setup(opts)
    local configured = H.valid(opts and opts.default) or FALLBACK
    H.apply(H.valid(vim.env.NVIM_CLIPBOARD) or H.persisted() or configured)
end

---Toggle between the tmux-local and the OSC 52 backend, and remember the
---choice as this machine's default.
function M.toggle()
    H.apply(M.backend == M.TMUX and M.OSC52 or M.TMUX)

    local ok, err = pcall(vim.fn.writefile, { M.backend }, STATE_FILE)
    local remembered = ok and "remembered on this machine" or ("not remembered: " .. tostring(err))

    vim.notify(("Clipboard: %s (%s)"):format(M.provider_name(), remembered), vim.log.levels.INFO)
end

return M
