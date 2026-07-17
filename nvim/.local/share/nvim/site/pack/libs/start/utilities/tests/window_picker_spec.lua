describe("window_picker", function()
    local window_picker = require("utilities.window_picker")

    local function labels_by_win()
        local by_win = {}
        for _, entry in ipairs(window_picker.get_ordered_wins()) do
            by_win[entry.win] = entry.label
        end
        return by_win
    end

    after_each(function()
        vim.cmd("only")
    end)

    it("labels a single window", function()
        local entries = window_picker.get_ordered_wins()
        assert.are.equal(1, #entries)
        assert.are.equal("A", entries[1].label)
        assert.are.equal(vim.api.nvim_get_current_win(), entries[1].win)
    end)

    it("orders side-by-side splits left to right", function()
        local left = vim.api.nvim_get_current_win()
        vim.cmd("rightbelow vsplit")
        local right = vim.api.nvim_get_current_win()

        local entries = window_picker.get_ordered_wins()
        assert.are.equal(2, #entries)
        assert.are.equal(left, entries[1].win)
        assert.are.equal("A", entries[1].label)
        assert.are.equal(right, entries[2].win)
        assert.are.equal("B", entries[2].label)
    end)

    it("orders stacked splits top to bottom", function()
        local top = vim.api.nvim_get_current_win()
        vim.cmd("rightbelow split")
        local bottom = vim.api.nvim_get_current_win()

        local entries = window_picker.get_ordered_wins()
        assert.are.equal(2, #entries)
        assert.are.equal(top, entries[1].win)
        assert.are.equal("A", entries[1].label)
        assert.are.equal(bottom, entries[2].win)
        assert.are.equal("B", entries[2].label)
    end)

    it("reads a grid of splits in row-major order", function()
        -- Build a 2x2 grid: top-left, top-right, bottom-left, bottom-right.
        local top_left = vim.api.nvim_get_current_win()
        vim.cmd("rightbelow vsplit")
        local top_right = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(top_left)
        vim.cmd("rightbelow split")
        local bottom_left = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(top_right)
        vim.cmd("rightbelow split")
        local bottom_right = vim.api.nvim_get_current_win()

        local by_win = labels_by_win()
        assert.are.equal("A", by_win[top_left])
        assert.are.equal("B", by_win[top_right])
        assert.are.equal("C", by_win[bottom_left])
        assert.are.equal("D", by_win[bottom_right])
    end)

    it("includes floating windows, positioned by their top-left corner", function()
        local left = vim.api.nvim_get_current_win()
        vim.cmd("rightbelow vsplit")
        local right = vim.api.nvim_get_current_win()

        -- Place the float's top-left corner between the two splits, on the
        -- same row, so its column alone decides where it sorts.
        local buf = vim.api.nvim_create_buf(false, true)
        local float = vim.api.nvim_open_win(buf, false, {
            relative = "editor",
            row = 0,
            col = 5,
            width = 10,
            height = 3,
            style = "minimal",
        })

        local by_win = labels_by_win()
        assert.are.equal("A", by_win[left])
        assert.are.equal("B", by_win[float])
        assert.are.equal("C", by_win[right])

        vim.api.nvim_win_close(float, true)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("ignores non-focusable floats, like hover/completion popups", function()
        local base = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_create_buf(false, true)
        local popup = vim.api.nvim_open_win(buf, false, {
            relative = "editor",
            row = 0,
            col = 5,
            width = 10,
            height = 3,
            style = "minimal",
            focusable = false,
        })

        local entries = window_picker.get_ordered_wins()
        assert.are.equal(1, #entries)
        assert.are.equal(base, entries[1].win)

        vim.api.nvim_win_close(popup, true)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)
