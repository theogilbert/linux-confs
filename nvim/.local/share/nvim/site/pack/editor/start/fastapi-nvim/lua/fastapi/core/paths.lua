-- Pure URL path helpers.
local M = {}

---@param path string
---@return string
function M.strip_dynamic_prefix(path)
    local rest = path:match("^{[^}]+}(.*)$")
    while rest do
        path = rest
        rest = path:match("^{[^}]+}(.*)$")
    end
    return path == "" and "/" or path
end

---@param path string
---@return string[]
local function split(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

---@param path string
---@param count integer
---@return string
function M.segments(path, count)
    local parts = split(path)
    if count >= #parts then
        return path
    end
    return "/" .. table.concat(parts, "/", 1, count)
end

---@param path string
---@return integer
function M.count_segments(path)
    return #split(path)
end

---@param path string
---@return string
local function trim_trailing_slashes(path)
    local trimmed = path:gsub("/+$", "")
    return trimmed == "" and "/" or trimmed
end

---@param path string
---@param dir string
---@return boolean
function M.is_within(path, dir)
    path, dir = trim_trailing_slashes(path), trim_trailing_slashes(dir)
    if path == dir then
        return true
    end
    return vim.startswith(path, dir == "/" and dir or dir .. "/")
end

---@param segment string
---@return boolean
function M.is_dynamic(segment)
    return vim.startswith(segment, "{") and vim.endswith(segment, "}")
end

---@param path string
---@return string[]
function M.comparable_segments(path)
    return split(M.strip_dynamic_prefix(path))
end

---@param test_segments string[]
---@param route_segments string[]
---@return boolean
function M.segments_match(test_segments, route_segments)
    if #test_segments ~= #route_segments then
        return false
    end
    for i, test_segment in ipairs(test_segments) do
        local route_segment = route_segments[i]
        if
            not (M.is_dynamic(test_segment) or M.is_dynamic(route_segment))
            and test_segment ~= route_segment
        then
            return false
        end
    end
    return true
end

---@param test_path string
---@param route_path string
---@return boolean
function M.matches(test_path, route_path)
    return M.segments_match(
        M.comparable_segments(test_path:match("^[^?]*")),
        M.comparable_segments(route_path)
    )
end

return M
