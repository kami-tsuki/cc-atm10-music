---@diagnostic disable: undefined-global
local M = {}

function M.read(url, headers)
    if not http or type(http.get) ~= "function" then
        return false, "HTTP API unavailable"
    end

    local lastError = "request failed"

    for attempt = 1, 3 do
        local ok, response = pcall(http.get, url, headers, true)
        if ok and response then
            local body = response.readAll()
            response.close()
            return true, body
        end

        lastError = tostring(response)
        sleep(0.2 * attempt)
    end

    return false, lastError
end

function M.readJson(url, headers)
    local ok, bodyOrError = M.read(url, headers)
    if not ok then
        return nil, bodyOrError
    end

    local parsed = textutils.unserializeJSON(bodyOrError)
    if type(parsed) ~= "table" then
        return nil, "invalid JSON response"
    end

    return parsed, bodyOrError
end

return M