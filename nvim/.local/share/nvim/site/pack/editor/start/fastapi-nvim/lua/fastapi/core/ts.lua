-- Tree-sitter parsing of Python files and small node helpers.
local M = {}

---@return boolean
function M.has_parser()
    return (pcall(vim.treesitter.language.add, "python"))
end

---@param path string
---@return string?, string?
local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local src, read_err = file:read("*a")
    file:close()
    return src, read_err
end

---@param src string
---@return TSNode?, string  the root, or nil with an error message
function M.parse_string(src)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, "python")
    if not ok then
        return nil, tostring(parser)
    end
    return parser:parse()[1]:root(), src
end

---@param path string
---@return TSNode?, string  root and source, or nil and an error message
function M.parse_file(path)
    local src, err = read_file(path)
    if not src then
        return nil, err or ("cannot read " .. path)
    end
    return M.parse_string(src)
end

---@param node TSNode
---@param src string
---@return string
function M.text(node, src)
    return vim.treesitter.get_node_text(node, src)
end

---@param node TSNode
---@param name string
---@return TSNode?
function M.field(node, name)
    return node:field(name)[1]
end

---@param node TSNode
---@return TSNode[]
function M.children(node)
    local list = {}
    for i = 0, node:named_child_count() - 1 do
        list[#list + 1] = assert(node:named_child(i))
    end
    return list
end

---@param node TSNode
---@param kind string
---@return TSNode?
local function child_of_type(node, kind)
    for child in node:iter_children() do
        if child:type() == kind then
            return child
        end
    end
end

---@param node TSNode
---@param src string
---@return string?  the text between the quotes, interpolations included
function M.string_content(node, src)
    if node:type() ~= "string" then
        return nil
    end
    local start, finish = child_of_type(node, "string_start"), child_of_type(node, "string_end")
    if not start or not finish then
        return nil
    end
    local _, _, from = start:end_()
    local _, _, to = finish:start()
    return src:sub(from + 1, to)
end

---@param node TSNode
---@param src string
---@return string?  nil for f-strings and non-strings
function M.string_value(node, src)
    local start = child_of_type(node, "string_start")
    if
        not start
        or child_of_type(node, "interpolation")
        or M.text(start, src):lower():match("^[a-z]*f")
    then
        return nil
    end
    return M.string_content(node, src)
end

return M
