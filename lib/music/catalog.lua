---@diagnostic disable: undefined-global
local httpClient = require("music.http")
local localLibrary = require("music.local")
local util = require("music.util")

local M = {}

local function normalizeSong(song)
    if type(song) == "string" then
        local label = util.trim(song)
        if label == "" then
            return nil
        end
        return {
            name = label,
            file = label,
            searchText = (label .. " " .. label):lower()
        }
    end

    if type(song) == "table" then
        local name = util.trim(song.name or song.title or song.file or "")
        local file = util.trim(song.file or song.path or song.name or "")
        if name == "" or file == "" then
            return nil
        end
        return {
            name = name,
            file = file,
            searchText = (name .. " " .. file):lower()
        }
    end

    return nil
end

local function parseLineBasedIndex(body)
    local songs = {}
    for _, rawLine in ipairs(util.splitLines(body)) do
        local line = util.trim(rawLine)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local display, file = line:match("^(.-)%s*|%s*(.+)$")
            if display and file then
                songs[#songs + 1] = {
                    name = util.trim(display),
                    file = util.trim(file)
                }
            else
                songs[#songs + 1] = {
                    name = line,
                    file = line
                }
            end
        end
    end
    return songs
end

local function parseIndexBody(body)
    local parsed = textutils.unserializeJSON(body)
    if type(parsed) == "table" then
        local songs = {}
        local source = parsed.songs or parsed
        for _, item in ipairs(source) do
            local normalized = normalizeSong(item)
            if normalized then
                songs[#songs + 1] = normalized
            end
        end
        if #songs > 0 then
            return songs
        end
    end

    local ok, legacy = pcall(textutils.unserialize, body)
    if ok and type(legacy) == "table" then
        local songs = {}
        for _, item in ipairs(legacy) do
            local normalized = normalizeSong(item)
            if normalized then
                songs[#songs + 1] = normalized
            end
        end
        if #songs > 0 then
            return songs
        end
    end

    return parseLineBasedIndex(body)
end

function M.rawUrl(repo, branch, path)
    return string.format(
        "https://raw.githubusercontent.com/%s/%s/%s",
        repo,
        branch or "main",
        util.encodePath(path)
    )
end

function M.trackPath(track)
    local file = track.file or track.name
    if not file:lower():match("%.dfpwm$") then
        file = file .. ".dfpwm"
    end
    return file
end

function M.trackUrl(playlist, track)
    if playlist and playlist.isLocal then
        return localLibrary.trackFilePath(playlist, track)
    end

    return M.rawUrl(playlist.repo, playlist.branch, M.trackPath(track))
end

function M.loadPlaylists(entries)
    local playlists = {}
    local warnings = {}

    for _, entry in ipairs(entries) do
        local url = M.rawUrl(entry.repo, entry.branch, entry.index)
        local ok, bodyOrError = httpClient.read(url)
        if ok then
            local songs = parseIndexBody(bodyOrError)
            if #songs > 0 then
                playlists[#playlists + 1] = {
                    name = entry.name,
                    repo = entry.repo,
                    branch = entry.branch,
                    index = entry.index,
                    searchText = entry.searchText or ((entry.name .. " " .. entry.repo):lower()),
                    songs = songs
                }
            else
                warnings[#warnings + 1] = entry.name .. ": index file is empty"
            end
        else
            warnings[#warnings + 1] = entry.name .. ": " .. tostring(bodyOrError)
        end
    end

    return playlists, warnings
end

function M.fetchTrackData(playlist, track)
    if playlist and playlist.isLocal then
        return localLibrary.readTrackData(playlist, track)
    end

    local url = M.trackUrl(playlist, track)
    local ok, bodyOrError = httpClient.read(url)
    if ok then
        return true, bodyOrError, url
    end
    return false, bodyOrError, url
end

return M