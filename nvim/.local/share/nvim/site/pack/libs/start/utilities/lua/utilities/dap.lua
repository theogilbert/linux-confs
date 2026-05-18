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

return M
