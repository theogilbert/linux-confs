local M = {}

local scratch_dir = vim.fn.stdpath("data") .. '/scratches/'

local fzf = require("fzf-lua")

M.setup = function()
    vim.fn.mkdir(scratch_dir, "p")
end

M.search_scratches = function()
    fzf.files({ cwd = scratch_dir })
end

local get_file_path = function(filename)
    return scratch_dir .. filename
end

local create_and_open = function(filename)
    local path = get_file_path(filename)
    if vim.fn.filereadable(path) == 1 then
        return false, "Filename already used. Please pick another name"
    end

    vim.cmd("edit " .. path)
    return true, nil
end

M.prompt_new_file = function(prompt, previous_filename)
    prompt = prompt or "Name of the scratch file"

    vim.ui.input(
        {prompt = prompt, default=previous_filename },
        function(submitted_filename)
            if submitted_filename == nil then
                return
            end

            local success, err = create_and_open(submitted_filename)
            if not success then
                M.prompt_new_file(err, submitted_filename)
            end
    end)
end

return M
