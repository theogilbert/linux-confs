describe("scratch", function()
    local scratch = require("utilities.scratch")
    local fzf = require("fzf-lua")

    -- The scratch store hangs off stdpath("state"): moving XDG_STATE_HOME
    -- keeps every test out of the real one. XDG_DATA_HOME is moved as well,
    -- or setup() would migrate the real legacy store into the temporary one.
    local original_state_home = vim.env.XDG_STATE_HOME
    local original_data_home = vim.env.XDG_DATA_HOME
    local scratches, legacy_scratches

    local original_select, original_input, original_notify
    local prompts, notifications

    ---Answer the scope prompt with {scope} and the name prompts with the
    ---successive entries of {names}.
    local function answer(scope, names)
        vim.ui.select = function(_, _, on_choice)
            on_choice(scope)
        end
        vim.ui.input = function(opts, on_input)
            table.insert(prompts, opts.prompt)
            on_input(table.remove(names, 1))
        end
    end

    local function write(path, content)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile({ content }, path)
    end

    ---A scratch only exists on disk once its buffer is written.
    local function new_scratch(scope, name)
        answer(scope, { name })
        scratch.prompt_new_file()
        local path = vim.api.nvim_buf_get_name(0)
        vim.cmd("silent write")
        return path
    end

    ---The scratches |scratch.search_scratches()| would offer from the current
    ---directory, obtained by running the listing command it hands to fzf-lua.
    local function visible()
        local entries = {}
        local original_files = fzf.files
        fzf.files = function(opts)
            entries = vim.fn.systemlist(
                ("cd %s && %s"):format(vim.fn.shellescape(opts.cwd), opts.cmd))
        end

        scratch.search_scratches()

        fzf.files = original_files
        table.sort(entries)
        return entries
    end

    local function in_new_dir()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        vim.cmd("lcd " .. dir)
        return dir
    end

    before_each(function()
        original_select, original_input = vim.ui.select, vim.ui.input
        original_notify = vim.notify
        prompts, notifications = {}, {}
        vim.notify = function(msg)
            table.insert(notifications, msg)
        end
        vim.env.XDG_STATE_HOME = vim.fn.tempname()
        vim.env.XDG_DATA_HOME = vim.fn.tempname()
        scratches = vim.env.XDG_STATE_HOME .. "/nvim/scratches"
        legacy_scratches = vim.env.XDG_DATA_HOME .. "/nvim/scratches"
        vim.fn.mkdir(scratches, "p")
    end)

    after_each(function()
        vim.fn.delete(vim.env.XDG_STATE_HOME, "rf")
        vim.fn.delete(vim.env.XDG_DATA_HOME, "rf")
        vim.env.XDG_STATE_HOME = original_state_home
        vim.env.XDG_DATA_HOME = original_data_home
        vim.ui.select, vim.ui.input = original_select, original_input
        vim.notify = original_notify
        vim.cmd("silent! %bwipeout!")
    end)

    it("lists a global scratch from any directory", function()
        scratch.setup()
        in_new_dir()

        local path = new_scratch("global", "shared.md")

        assert.are.equal(scratches .. "/global/shared.md", path)
        assert.are.same({ "global/shared.md" }, visible())
        in_new_dir()
        assert.are.same({ "global/shared.md" }, visible())
    end)

    it("lists a project scratch from its directory only", function()
        scratch.setup()
        local project = in_new_dir()

        local path = new_scratch("project", "todo.md")

        -- Stored outside of the project, in a directory named after it.
        assert.are.equal(
            vim.fn.fnamemodify(project, ":t"),
            vim.fs.basename(vim.fs.dirname(path)):gsub("%-%x+$", "")
        )
        assert.is_truthy(vim.startswith(path, scratches))
        assert.are.same({ vim.fs.basename(vim.fs.dirname(path)) .. "/todo.md" }, visible())

        in_new_dir()
        assert.are.same({}, visible())
    end)

    it("gives two directories sharing a name distinct scratch directories", function()
        scratch.setup()
        local base = vim.fn.tempname()
        local dirs = {}

        for _, parent in ipairs({ "one", "two" }) do
            local project = base .. "/" .. parent .. "/project"
            vim.fn.mkdir(project, "p")
            vim.cmd("lcd " .. project)

            table.insert(dirs, vim.fs.dirname(new_scratch("project", "notes.md")))
        end

        assert.is_not.equal(dirs[1], dirs[2])
    end)

    it("creates the directories a scratch name carries", function()
        scratch.setup()
        local path = new_scratch("global", "notes/monday.md")

        assert.are.equal(scratches .. "/global/notes/monday.md", path)
        assert.are.same({ "global/notes/monday.md" }, visible())
    end)

    it("re-prompts with the reason when the name is taken", function()
        scratch.setup()
        write(scratches .. "/global/taken.md", "content")
        answer("global", { "taken.md", "free.md" })

        scratch.prompt_new_file()

        assert.are.equal(2, #prompts)
        assert.is_truthy(prompts[2]:match("already used"))
        assert.are.equal(scratches .. "/global/free.md", vim.api.nvim_buf_get_name(0))
        -- The existing scratch was not touched.
        assert.are.same({ "content" }, vim.fn.readfile(scratches .. "/global/taken.md"))
    end)

    it("opens no buffer when the scope prompt is cancelled", function()
        scratch.setup()
        local before = vim.api.nvim_buf_get_name(0)
        answer(nil, {})

        scratch.prompt_new_file()

        assert.are.equal(before, vim.api.nvim_buf_get_name(0))
        assert.are.same({}, prompts)
    end)

    it("creates no directory for a cwd that has no scratch", function()
        scratch.setup()
        in_new_dir()

        assert.are.same({}, visible())

        assert.are.same({ "global" }, vim.fn.readdir(scratches))
    end)

    it("moves an unscoped scratch into the global scope", function()
        write(scratches .. "/legacy.md", "kept")

        scratch.setup()

        assert.are.same({ "kept" }, vim.fn.readfile(scratches .. "/global/legacy.md"))
        assert.are.equal(0, vim.fn.filereadable(scratches .. "/legacy.md"))
    end)

    it("reports an unscoped scratch whose name is already taken", function()
        write(scratches .. "/dup.md", "unscoped")
        write(scratches .. "/global/dup.md", "global")

        scratch.setup()

        assert.are.same({ "global" }, vim.fn.readfile(scratches .. "/global/dup.md"))
        assert.are.same({ "unscoped" }, vim.fn.readfile(scratches .. "/dup.md"))
        assert.are.equal(1, #notifications)
        assert.is_truthy(notifications[1]:match("already exists"))
    end)

    it("moves the store from the data dir to the state dir", function()
        vim.fn.delete(scratches, "rf")
        write(legacy_scratches .. "/global/old.md", "moved")

        scratch.setup()

        assert.are.same({ "moved" }, vim.fn.readfile(scratches .. "/global/old.md"))
        assert.are.equal(0, vim.fn.isdirectory(legacy_scratches))
        assert.are.same({}, notifications)
    end)

    it("keeps a legacy store when the state dir already holds one", function()
        write(scratches .. "/global/new.md", "state")
        write(legacy_scratches .. "/global/old.md", "data")

        scratch.setup()

        assert.are.same({ "state" }, vim.fn.readfile(scratches .. "/global/new.md"))
        assert.are.same({ "data" }, vim.fn.readfile(legacy_scratches .. "/global/old.md"))
        assert.are.equal(1, #notifications)
        assert.is_truthy(notifications[1]:match("already exists"))
    end)
end)
