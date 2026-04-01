---@diagnostic disable: undefined-global
local util = require("music.util")

local M = {}

local function normalizeEntry(entry)
    if type(entry) ~= "table" then
        return nil, "playlist entries must be objects"
    end

    local repo = util.trim(entry.repo or "")
    if repo == "" then
        return nil, "playlist entry is missing 'repo'"
    end

    return {
        name = util.trim(entry.name or entry.title or repo),
        repo = repo,
        branch = util.trim(entry.branch or "main"),
        index = util.trim(entry.index or "index.txt")
    }
end

function M.load(path)
    local contents, readErr = util.readFile(path)
    if not contents then
        error("Unable to read '" .. path .. "': " .. tostring(readErr))
    end

    local parsed = textutils.unserializeJSON(contents)
    if type(parsed) ~= "table" then
        error("Invalid JSON in '" .. path .. "'.")
    end

    local source = parsed.playlists or parsed
    if type(source) ~= "table" then
        error("Config must be a JSON array or an object with a 'playlists' array.")
    end

    local playlists = {}
    for _, entry in ipairs(source) do
        local normalized, err = normalizeEntry(entry)
        if not normalized then
            error("Invalid config entry: " .. tostring(err))
        end
        playlists[#playlists + 1] = normalized
    end

    if #playlists == 0 then
        error("config.json does not contain any playlists.")
    end

    return playlists
end

return M