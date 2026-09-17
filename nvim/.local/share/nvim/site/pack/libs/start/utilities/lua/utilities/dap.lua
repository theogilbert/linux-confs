local M = {}

local buffer = require("utilities.buffer")

local function strip_python_quotes(value)
    local stripped = value
    local prefix = stripped:match("^[bBrRfFuU]+")
    if prefix then
        stripped = stripped:sub(#prefix + 1)
    end
    local first = stripped:sub(1, 1)
    local last = stripped:sub(-1)
    if #stripped >= 2 and (first == "'" or first == '"') and first == last then
        return stripped:sub(2, -2)
    end
    return nil
end

local function unescape_python_string(body)
    return (body:gsub("\\(.)", function(c)
        if c == "n" then return "\n" end
        if c == "t" then return "\t" end
        if c == "r" then return "\r" end
        if c == "0" then return "\0" end
        if c == "'" then return "'" end
        if c == '"' then return '"' end
        if c == "\\" then return "\\" end
        return "\\" .. c
    end))
end

local function get_eval_expression()
    if buffer.is_in_visual_mode() then
        return buffer.get_selection()
    end
    return vim.fn.expand("<cexpr>")
end

local function open_string_float(expr, content)
    local lines = vim.split(content, "\n", { plain = true })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local max_width = 0
    for _, line in ipairs(lines) do
        max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
    end
    local width = math.max(math.min(max_width, vim.o.columns - 4), 20)
    local height = math.max(math.min(#lines, vim.o.lines - 4), 1)

    vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = height,
        border = "rounded",
        style = "minimal",
        title = " " .. expr .. " ",
    })

    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf, nowait = true, silent = true })
end

-- Evaluate the expression under the cursor (or visual selection) in the active
-- DAP session. When the result is a quoted Python string, render it in a float
-- with real newlines/tabs. Otherwise, fall back to dapui.eval so dicts, lists
-- and objects keep their expandable tree view.
M.peek_string_value = function()
    local dap = require("dap")
    local dapui = require("dapui")

    local session = dap.session()
    if not session then
        dapui.eval()
        return
    end

    local expr = get_eval_expression()
    if expr == nil or expr == "" then
        return
    end

    session:evaluate(expr, function(err, response)
        vim.schedule(function()
            if err or not response or response.result == nil then
                dapui.eval(expr)
                return
            end
            local body = strip_python_quotes(response.result)
            if body == nil then
                dapui.eval(expr)
                return
            end
            open_string_float(expr, unescape_python_string(body))
        end)
    end)
end

---Condition of the breakpoint on a line, if there is one.
---
---@param bufnr integer
---@param lnum integer
---@return string|nil
local function condition_at(bufnr, lnum)
    for _, bp in ipairs(require("dap.breakpoints").get(bufnr)[bufnr] or {}) do
        if bp.line == lnum then
            return bp.condition
        end
    end
    return nil
end

---Indentation of a line, taken from the closest non-blank line at or above
---it.
---
---@param lines string[]
---@param lnum integer
---@return string
local function indent_at(lines, lnum)
    for i = lnum, 1, -1 do
        local indent, rest = lines[i]:match("^(%s*)(.*)$")
        if rest ~= "" then
            return indent
        end
    end
    return ""
end

---Path the prompt buffer is named after: a file that never exists, next to
---the source so that the language server resolves imports from the same
---project.
---
---@param source string Path of the source buffer
---@return string
local function prompt_name(source)
    return vim.fs.joinpath(vim.fs.dirname(source), ".dap-condition." .. vim.fs.basename(source))
end

-- Edit the condition of the breakpoint on the current line in a one-line
-- split at the bottom. The buffer behind it is a Python file holding the
-- source up to that line, with the condition as its last line, so that
-- highlighting and the language server's completion see the names in scope.
-- The rest of the buffer stays out of sight and the cursor is kept on the
-- condition. <CR> sets the breakpoint (replacing one already there), <Esc> or
-- q in normal mode, or leaving the window, cancels; an empty condition cancels
-- too.
M.prompt_condition = function()
    local dap = require("dap")
    local src_win = vim.api.nvim_get_current_win()
    local src_buf = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(src_win)[1]
    local source = vim.api.nvim_buf_get_name(src_buf)

    local lines = vim.api.nvim_buf_get_lines(src_buf, 0, lnum - 1, false)
    local indent = indent_at(vim.api.nvim_buf_get_lines(src_buf, 0, lnum, false), lnum)
    table.insert(lines, indent .. (condition_at(src_buf, lnum) or ""))
    local last = #lines

    local name = prompt_name(source)
    local stale = vim.fn.bufnr(name)
    if stale ~= -1 then
        vim.api.nvim_buf_delete(stale, { force = true })
    end

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buflisted = false
    vim.bo[buf].swapfile = false
    vim.bo[buf].modified = false
    vim.diagnostic.enable(false, { bufnr = buf })

    vim.cmd("botright 1split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].winfixheight = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldenable = false
    vim.wo[win].scrolloff = 0
    vim.wo[win].wrap = false
    vim.wo[win].statusline = (" Break condition for %s:%d   <CR> set   <Esc> cancel "):format(
        vim.fn.fnamemodify(source, ":~:."), lnum)

    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
        if vim.api.nvim_win_is_valid(src_win) then
            vim.api.nvim_set_current_win(src_win)
        end
    end

    local function confirm()
        local condition = vim.trim(vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or "")
        close()
        if condition == "" or not vim.api.nvim_win_is_valid(src_win) then
            return
        end
        vim.api.nvim_win_call(src_win, function()
            -- nvim-dap works on the cursor line: point it at the breakpoint
            -- line for the call, then put it back.
            local cursor = vim.api.nvim_win_get_cursor(src_win)
            vim.api.nvim_win_set_cursor(src_win, { lnum, 0 })
            dap.set_breakpoint(condition)
            vim.api.nvim_win_set_cursor(src_win, cursor)
        end)
    end

    -- Set before entering insert mode, so that nvim-cmp takes the <CR> as
    -- the fallback of its own mapping.
    local opts = { buffer = buf, nowait = true, silent = true }
    vim.keymap.set({ "n", "i" }, "<CR>", confirm, opts)
    vim.keymap.set("n", "<Esc>", close, opts)
    vim.keymap.set("n", "q", close, opts)

    local group = vim.api.nvim_create_augroup("utilities_dap_condition_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        buffer = buf,
        callback = function()
            if vim.api.nvim_win_get_cursor(win)[1] ~= last then
                vim.api.nvim_win_set_cursor(win, { last, #lines[last] })
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = buf, callback = close })
    -- The language server attaches after the prompt has entered insert mode,
    -- and cmp-nvim-lsp only picks up clients on InsertEnter: replay it.
    vim.api.nvim_create_autocmd("LspAttach", {
        group = group,
        buffer = buf,
        callback = function()
            if vim.fn.mode():sub(1, 1) == "i" then
                pcall(vim.api.nvim_exec_autocmds, "InsertEnter", { group = "cmp_nvim_lsp", buffer = buf })
            end
        end,
    })

    -- Filetype last: it starts the language server, which must see the
    -- final name and content.
    vim.bo[buf].filetype = "python"
    vim.api.nvim_win_set_cursor(win, { last, #lines[last] })
    vim.cmd("startinsert!")
end

return M
