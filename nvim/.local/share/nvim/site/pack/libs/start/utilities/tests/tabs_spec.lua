describe("tabs", function()
    local tabs = require("utilities.tabs")

    local function stub_notify()
        local messages = {}
        vim.notify = function(msg)
            table.insert(messages, msg)
        end
        return messages
    end

    local original_notify

    before_each(function()
        original_notify = vim.notify
    end)

    after_each(function()
        vim.notify = original_notify
        vim.t.tabname = nil
    end)

    it("stores the given name on the current tab", function()
        tabs.name_current_tab("scratch")

        assert.are.equal("scratch", vim.t.tabname)
    end)

    it("overwrites a previously assigned name", function()
        vim.t.tabname = "previous"

        tabs.name_current_tab("new-name")

        assert.are.equal("new-name", vim.t.tabname)
    end)

    it("clears the tab name and notifies when cleared", function()
        vim.t.tabname = "kept"
        local messages = stub_notify()

        tabs.clear_current_tab_name()

        assert.is_nil(vim.t.tabname)
        assert.are.equal(1, #messages)
        assert.are.equal("Tab name cleared", messages[1])
    end)

    describe("close and reopen", function()
        after_each(function()
            vim.cmd("tabonly")
        end)

        it("brings back the windows, buffers and name of the closed tab", function()
            vim.cmd("tabnew")
            local top_left = vim.api.nvim_get_current_buf()
            vim.cmd("vsplit")
            local right = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(0, right)
            vim.cmd("wincmd h | split")
            local bottom_left = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(0, bottom_left)
            tabs.name_current_tab("work")

            tabs.close_current_tab()
            assert.are.equal(1, vim.fn.tabpagenr("$"))

            tabs.reopen_closed_tab()

            assert.are.equal(2, vim.fn.tabpagenr("$"))
            assert.are.equal("work", vim.t.tabname)
            local layout = vim.fn.winlayout()
            assert.are.equal("row", layout[1])
            assert.are.equal("col", layout[2][1][1])
            local function buf(leaf) return vim.api.nvim_win_get_buf(leaf[2]) end
            assert.are.equal(top_left, buf(layout[2][1][2][1]))
            assert.are.equal(bottom_left, buf(layout[2][1][2][2]))
            assert.are.equal(right, buf(layout[2][2]))
        end)

        it("notifies when there is nothing to reopen", function()
            local messages = stub_notify()

            tabs.reopen_closed_tab()

            assert.are.same({ "No closed tab to reopen" }, messages)
        end)
    end)

    describe("render", function()
        after_each(function()
            vim.cmd("tabonly")
        end)

        it("falls back to the buffer name when the tab has no assigned name", function()
            vim.cmd("edit some_file.txt")
            assert.is_not_nil(tabs.render():find("some_file.txt", 1, true))
        end)

        it("uses the assigned tab name instead of the buffer name", function()
            vim.cmd("edit some_file.txt")
            vim.t.tabname = "custom"
            assert.is_not_nil(tabs.render():find("custom", 1, true))
            assert.is_nil(tabs.render():find("some_file.txt", 1, true))
        end)

        it("labels each tab with its own number", function()
            vim.cmd("tabnew other_file.txt")
            local rendered = tabs.render()
            assert.is_not_nil(rendered:find("1:", 1, true))
            assert.is_not_nil(rendered:find("2:", 1, true))
        end)
    end)
end)
