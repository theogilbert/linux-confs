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
function DataView:new(expr)
	local self = setmetatable({}, DataView)

        self.expr = expr
        self.state = State.EVALUATING
        self.data = {"Loading..."}

	return self
end

function DataView:refresh(on_ready)
    evaluator.evaluate_expression(self.expr, function(err, ret)
        if err ~= nil then
            self.state = State.FAILED
            self.data = {"Failed to evaluate expression:",vim.inspect(err)}
            on_ready()
            return
        end

        local table, fmt_err = table_fmt.from_csv(ret, 2)
        if fmt_err ~= nil then
            self.state = State.FAILED
            self.data = {"Failed to format result: " .. vim.inspect(fmt_err)}
            on_ready()
            return
        end

        self.table = table
        self.data = table.text
        self.state = State.READY
        on_ready()
    end)
end

function DataView:get_lines()
    local lines = { "➜ " .. self.expr }

    return vim.list_extend(lines, self.data)

end

local function build_hl_rules_for_columns(higroup, line, columns_width)
        local content_rules = {}

        local cur_col = 1
        for i, width in ipairs(columns_width) do
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
    if self.state == State.EVALUATING then
        hl_rules = {
            { higroup = "DapDfLoading", start = {1, 0}, finish = {-1, -1} }
        }
    elseif self.state == State.READY then
        hl_rules = vim.iter(
            {
                {{ higroup = "DapDfPrompt", start = {0, 0}, finish = {0, -1}}},
                build_hl_rules_for_columns("DapDfHeaderRow", 1, self.table.columns_width),
                build_hl_rules_for_columns("DapDfTypeRow", 2, self.table.columns_width),
            }
        ):flatten():totable()
    elseif self.state == State.FAILED then
        hl_rules = {
            { higroup = "DapDfError", start = {1, 0}, finish = {#self.data + 1, -1} }
        }
    end

    return hl_rules
end


return DataView
