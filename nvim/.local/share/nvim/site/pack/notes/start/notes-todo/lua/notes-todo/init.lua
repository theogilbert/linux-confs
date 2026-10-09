-- TODO items in markdown notes: highlights the TODO/DONE keywords, jumps
-- between TODO lines and lists them in the quickfix list.
--
-- An item is any line containing the word TODO, outside headings and code
-- fences. Each item is labelled with the heading it belongs to.

local M = {}

local QF_TITLE = "Todos"
local KEYWORDS = { TODO = "NotesTodo", DONE = "NotesDone" }

vim.api.nvim_set_hl(0, "NotesTodo", { default = true, link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "NotesDone", { default = true, link = "DiagnosticOk" })

---@class notes-todo.Item
---@field lnum    integer  -- 1-indexed
---@field section string
---@field text    string

---@param line string
---@return boolean
local function is_fence(line)
    return line:match("^%s*```") ~= nil
end

---@param line string
---@return boolean
local function is_heading(line)
    return line:match("^#+%s") ~= nil
end

---@param bufnr integer
---@return notes-todo.Item[]
local function collect(bufnr)
    local items, section, in_fence = {}, "", false
    for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if is_fence(line) then
            in_fence = not in_fence
        elseif not in_fence then
            if is_heading(line) then
                section = line:match("^#+%s+(.-)%s*$")
            elseif line:match("%f[%w]TODO%f[%W]") then
                table.insert(items, {
                    lnum = lnum,
                    section = section,
                    text = vim.trim((line:gsub("^%s*[-*+]%s+", ""))),
                })
            end
        end
    end
    return items
end

---Moves the cursor to the next (or previous) TODO item, wrapping around the
---buffer like `wrapscan`.
---@param forward boolean
local function jump(forward)
    local items = collect(0)
    if #items == 0 then
        vim.notify("No TODO in buffer", vim.log.levels.INFO)
        return
    end
    local cur = vim.fn.line(".")
    local target
    if forward then
        for _, item in ipairs(items) do
            if item.lnum > cur then target = item; break end
        end
        target = target or items[1]
    else
        for i = #items, 1, -1 do
            if items[i].lnum < cur then target = items[i]; break end
        end
        target = target or items[#items]
    end
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
end

function M.next() jump(true) end
function M.prev() jump(false) end

---Opens the quickfix list with the TODO items of the current buffer.
function M.show()
    local bufnr = vim.api.nvim_get_current_buf()
    local entries = vim.tbl_map(function(item)
        return {
            bufnr = bufnr,
            lnum = item.lnum,
            text = item.section ~= "" and ("[" .. item.section .. "] " .. item.text) or item.text,
        }
    end, collect(bufnr))
    vim.fn.setqflist({}, " ", { title = QF_TITLE, items = entries })
    vim.cmd.copen()
end

-- Highlights the keywords of the visible lines on each redraw. Priority is
-- above treesitter's (100) so markdown highlighting does not hide them.
local ns = vim.api.nvim_create_namespace("notes-todo")
vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, bufnr)
        return vim.bo[bufnr].filetype == "markdown"
    end,
    on_line = function(_, _, bufnr, row)
        local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        for word, hl in pairs(KEYWORDS) do
            local init = 1
            while true do
                local s, e = line:find("%f[%w]" .. word .. "%f[%W]", init)
                if not s then break end
                vim.api.nvim_buf_set_extmark(bufnr, ns, row, s - 1, {
                    end_col = e, hl_group = hl, priority = 200, ephemeral = true,
                })
                init = e + 1
            end
        end
    end,
})

return M
