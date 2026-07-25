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
