---@diagnostic disable: undefined-global
local M = {}

function M.clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

function M.trim(value)
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.truncate(value, width)
    value = tostring(value or "")
    if width <= 0 then
        return ""
    end
    if #value <= width then
        return value
    end
    if width == 1 then
        return "."
    end
    if width == 2 then
        return ".."
    end
    return value:sub(1, width - 3) .. "..."
end

function M.ensureDir(path)
    local dir = fs.getDir(path)
    if dir == "" then
        return
    end

    local cursor = ""
    for part in string.gmatch(dir, "[^/]+") do
        cursor = cursor == "" and part or fs.combine(cursor, part)
        if not fs.exists(cursor) then
            fs.makeDir(cursor)
        end
    end
end

function M.readFile(path)
    if not fs.exists(path) then
        return nil, "missing file"
    end

    local handle = fs.open(path, "r")
    if not handle then
        return nil, "failed to open file"
    end

    local data = handle.readAll()
    handle.close()
    return data
end

function M.writeFile(path, contents)
    M.ensureDir(path)
    local handle = fs.open(path, "w")
    if not handle then
        return false, "failed to open file"
    end

    handle.write(contents)
    handle.close()
    return true
end

function M.urlEncode(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function M.encodePath(path)
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
        parts[#parts + 1] = M.urlEncode(part)
    end
    return table.concat(parts, "/")
end

function M.splitLines(value)
    local lines = {}
    if value == "" then
        return lines
    end

    value = tostring(value):gsub("\r\n", "\n")
    if value:sub(-1) ~= "\n" then
        value = value .. "\n"
    end

    for line in value:gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

function M.findIndexByField(items, field, expected)
    for index, item in ipairs(items) do
        if item[field] == expected then
            return index
        end
    end
    return nil
end

function M.safeFormatTime()
    local ok, formatted = pcall(textutils.formatTime, os.time(), true)
    if ok then
        return formatted
    end
    return tostring(os.time())
end

return M