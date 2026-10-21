-- TODO items in markdown notes: highlights the TODO/DONE keywords, jumps
-- between TODO lines and lists them in a floating window.
--
-- An item is any line containing the word TODO, outside headings and code
-- fences. Each item is labelled with the heading it belongs to.

local M = {}

local TITLE = "Todos"
local KEYWORDS = { TODO = "NotesTodo", DONE = "NotesDone" }

-- TODO is purple rather than the usual yellow so that it stands out from
-- markdown's own highlighting. Redefined after each colorscheme change, which
-- clears all highlight groups.
local function define_highlights()
    vim.api.nvim_set_hl(0, "NotesTodo", { default = true, fg = "#ab9df2", ctermfg = 176, bold = true })
    vim.api.nvim_set_hl(0, "NotesDone", { default = true, link = "DiagnosticOk" })
end
define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("notes-todo", { clear = true }),
    callback = define_highlights,
})

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

local ns = vim.api.nvim_create_namespace("notes-todo")

---Calls `fn(start_col, end_col, hl_group)` for each keyword of `line`, with
---0-indexed, end-exclusive columns.
---@param line string
---@param fn fun(s: integer, e: integer, hl: string)
local function each_keyword(line, fn)
    for word, hl in pairs(KEYWORDS) do
        local init = 1
        while true do
            local s, e = line:find("%f[%w]" .. word .. "%f[%W]", init)
            if not s then break end
            fn(s - 1, e, hl)
            init = e + 1
        end
    end
end

---Moves the cursor of `win` to the closest item row after (or before) it.
---@param win integer
---@param rows integer[] sorted item rows
---@param forward boolean
local function move_to_item(win, rows, forward)
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    local target
    if forward then
        for _, row in ipairs(rows) do
            if row > cur then target = row; break end
        end
    else
        for i = #rows, 1, -1 do
            if rows[i] < cur then target = rows[i]; break end
        end
    end
    if target then vim.api.nvim_win_set_cursor(win, { target, 2 }) end
end

---Opens a floating window listing the TODO items of the current buffer,
---grouped by section. <CR> jumps to the item under the cursor.
function M.show()
    local src_win = vim.api.nvim_get_current_win()
    local items = collect(0)
    if #items == 0 then
        vim.notify("No TODO in buffer", vim.log.levels.INFO)
        return
    end

    -- One heading row per section, followed by its items. by_row maps the
    -- rows of the float to the items they show.
    local lines, headings, by_row, rows = {}, {}, {}, {}
    local section
    for _, item in ipairs(items) do
        if item.section ~= section then
            section = item.section
            if #lines > 0 then table.insert(lines, "") end
            table.insert(lines, section ~= "" and section or "(no section)")
            headings[#lines] = true
        end
        table.insert(lines, "  " .. item.text)
        by_row[#lines] = item
        table.insert(rows, #lines)
    end

    local lnum_width = #tostring(items[#items].lnum) + 1
    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = math.min(width + lnum_width + 3, vim.o.columns - 8)
    local height = math.min(#lines, vim.o.lines - 8)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "notes-todo"
    for row, line in ipairs(lines) do
        if headings[row] then
            vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { end_col = #line, hl_group = "Title" })
        elseif by_row[row] then
            each_keyword(line, function(s, e, hl)
                vim.api.nvim_buf_set_extmark(buf, ns, row - 1, s, { end_col = e, hl_group = hl })
            end)
            vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
                virt_text = { { tostring(by_row[row].lnum), "LineNr" } },
                virt_text_pos = "right_align",
            })
        end
    end

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = (" %s (%d) "):format(TITLE, #items),
        title_pos = "center",
        footer = " <CR> jump · q close ",
        footer_pos = "center",
    })
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false

    -- Start on the item the cursor is in, or the first one.
    local cur = vim.api.nvim_win_get_cursor(src_win)[1]
    local start = rows[1]
    for _, row in ipairs(rows) do
        if by_row[row].lnum <= cur then start = row end
    end
    vim.api.nvim_win_set_cursor(win, { start, 2 })

    local function close()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    local function jump_to_item()
        local item = by_row[vim.api.nvim_win_get_cursor(win)[1]]
        if not item then return end
        close()
        vim.api.nvim_set_current_win(src_win)
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(src_win, { item.lnum, 0 })
        vim.cmd("normal! zvzz")
    end

    local opts = { buffer = buf, nowait = true }
    vim.keymap.set("n", "<CR>", jump_to_item, opts)
    vim.keymap.set("n", "q", close, opts)
    vim.keymap.set("n", "<Esc>", close, opts)
    vim.keymap.set("n", "j", function() move_to_item(win, rows, true) end, opts)
    vim.keymap.set("n", "k", function() move_to_item(win, rows, false) end, opts)
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

-- Highlights the keywords of the visible lines on each redraw. Priority is
-- above treesitter's (100) so markdown highlighting does not hide them.
vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, bufnr)
        return vim.bo[bufnr].filetype == "markdown"
    end,
    on_line = function(_, _, bufnr, row)
        local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        each_keyword(line, function(s, e, hl)
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, s, {
                end_col = e, hl_group = hl, priority = 200, ephemeral = true,
            })
        end)
    end,
})

return M
