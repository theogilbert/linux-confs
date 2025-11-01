local evaluator = require("nvim-dap-df-pane.evaluator")
local table_fmt = require("utilities.table")

local DataView = {}
DataView.__index = DataView

local State = {
    EVALUATING = 0,
    READY = 1,
    FAILED = 2
}

-- Constructor
function DataView:new(expr, limit)
	local self = setmetatable({}, DataView)

        self.limit = limit
        self.expr = expr
        self.state = State.EVALUATING
        self.shape = nil
        self.lines = {}

	return self
end

function DataView:refresh(on_ready)
    self.state = State.EVALUATING
    on_ready()

    evaluator.evaluate_expression(self.expr, self.limit, function(data, shape, err)
        if err ~= nil then
            self.state = State.FAILED
            self.lines = {"Failed to evaluate expression:"}

            local err_lines = vim.split(vim.inspect(err), "\n")
            vim.list_extend(self.lines, err_lines)

            on_ready()
            return
        end

        local table, fmt_err = table_fmt.from_csv(data, 2)
        if fmt_err ~= nil then
            self.state = State.FAILED
            self.lines = {"Failed to format result: " .. vim.inspect(fmt_err)}
            on_ready()
            return
        end

        self.state = State.READY
        self.table = table
        self.lines = table.text
        self.shape = shape
        self.state = State.READY
        on_ready()
    end)
end

local function get_shape_repr(self)
    return self.shape and "[" .. self.shape[1] .. "×" .. self.shape[2] .. "]" or ""
end

local function get_prompt_line(self, width)
    local shape_repr = get_shape_repr(self)

    local loading = ""
    if self.state == State.EVALUATING then
        loading = " Loading..."
    end

    local base_prompt = "➜ " .. self.expr .. " " .. shape_repr .. loading
    local chars_to_add = math.max(0, width - vim.api.nvim_strwidth(base_prompt))

    return base_prompt .. string.rep(" ", chars_to_add)
end

local function build_hl_rules_for_prompt(self)
    local shape_start = 3 + #self.expr + 2
    local shape_end = shape_start + #get_shape_repr(self)

    local rules = {
        { higroup = "DapDfPrompt", start = {0, 0}, finish = {0, -1}}
    }

    if self.shape ~= nil then
        table.insert(rules, {
            higroup = "DapDfPromptShape", start = {0, shape_start}, finish = {0, shape_end}
        })
    end

    if self.state == State.EVALUATING then
        table.insert(rules, {
             higroup = "DapDfPromptLoading", start = {0, shape_end + 1}, finish = {0, -1}
        })
    end

    return rules
end

function DataView:get_lines()
    local first_line_width = vim.api.nvim_strwidth(self.lines[1] or "")
    local prompt_line = get_prompt_line(self, first_line_width)

    local lines = { prompt_line }
    return vim.list_extend(lines, self.lines)
end

local function build_hl_rules_for_columns(higroup, line, table)
        local content_rules = {}

        if table == nil then
            return content_rules
        end

        local cur_col = 1
        for i, width in ipairs(table.columns_width) do
            content_rules[i] = {
                higroup = higroup,
                start = {line, cur_col },
                finish = {line, cur_col + width + 2}
            }

            cur_col = cur_col + width + 3

        end

        return content_rules
end

function DataView:get_hl_rules()
    local hl_rules = {}
    if self.state == State.FAILED then
        hl_rules = {
            { higroup = "DapDfError", start = {1, 0}, finish = {#self.lines + 1, -1} }
        }
    else
        hl_rules = vim.iter(
            {
                build_hl_rules_for_prompt(self),
                build_hl_rules_for_columns("DapDfHeaderRow", 1, self.table),
                build_hl_rules_for_columns("DapDfTypeRow", 2, self.table),
            }
        ):flatten():totable()
    end

    return hl_rules
end


return DataView
