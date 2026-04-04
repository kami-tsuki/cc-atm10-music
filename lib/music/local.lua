---@diagnostic disable: undefined-global
local util = require("music.util")

local M = {}

M.ROOT_DIR = "local"
M.DEFAULT_INDEX = "index.json"
M.FAVORITES_DIRNAME = "favorites"
M.FAVORITES_TITLE = "Favorites"

local function openForRead(path)
    return fs.open(path, "rb") or fs.open(path, "r")
end

local function openForWrite(path)
    return fs.open(path, "wb") or fs.open(path, "w")
end

local function prettifyName(value)
    local normalized = tostring(value or ""):gsub("[_%-]+", " ")
    normalized = util.trim(normalized)
    if normalized == "" then
        return "Local"
    end

    return (normalized:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end))
end

local function normalizeSong(song)
    if type(song) == "string" then
        local name = util.trim(song)
        if name == "" then
            return nil
        end

        return {
            name = name,
            file = name,
            searchText = (name .. " " .. name):lower()
        }
    end

    if type(song) ~= "table" then
        return nil
    end

    local name = util.trim(song.name or song.title or song.file or song.path or "")
    local file = util.trim(song.file or song.path or song.name or "")
    if name == "" or file == "" then
        return nil
    end

    local favoriteKey = util.trim(song.favoriteKey or song.sourceKey or "")
    local sourcePlaylist = util.trim(song.sourcePlaylist or "")
    local sourceFile = util.trim(song.sourceFile or "")
    local sourceName = util.trim(song.sourceName or name)

    return {
        name = name,
        file = file,
        favoriteKey = favoriteKey ~= "" and favoriteKey or nil,
        sourcePlaylist = sourcePlaylist ~= "" and sourcePlaylist or nil,
        sourceFile = sourceFile ~= "" and sourceFile or nil,
        sourceName = sourceName ~= "" and sourceName or nil,
        searchText = (name .. " " .. file):lower()
    }
end

local function readBinaryFile(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil, "missing file"
    end

    local handle = openForRead(path)
    if not handle then
        return nil, "failed to open file"
    end

    local body = handle.readAll()
    handle.close()
    return body
end

local function writeBinaryFile(path, body)
    util.ensureDir(path)
    local handle = openForWrite(path)
    if not handle then
        return false, "failed to open file"
    end

    local ok, err = pcall(handle.write, body)
    handle.close()
    if not ok then
        if fs.exists(path) then
            fs.delete(path)
        end
        return false, tostring(err)
    end

    return true
end

local function serializePlaylist(title, songs)
    local encodedSongs = {}
    for _, song in ipairs(songs or {}) do
        encodedSongs[#encodedSongs + 1] = {
            name = song.name,
            file = song.file,
            favoriteKey = song.favoriteKey,
            sourcePlaylist = song.sourcePlaylist,
            sourceFile = song.sourceFile,
            sourceName = song.sourceName
        }
    end

    return textutils.serializeJSON({
        name = title,
        songs = encodedSongs
    })
end

local function loadPlaylistIndex(path)
    local body, err = util.readFile(path)
    if not body then
        return nil, err
    end

    local parsed = textutils.unserializeJSON(body)
    if type(parsed) ~= "table" then
        return nil, "invalid JSON"
    end

    local title = util.trim(parsed.name or parsed.title or "")
    local sourceSongs = parsed.songs or parsed
    if type(sourceSongs) ~= "table" then
        return nil, "index.json must be an array or object with a 'songs' array"
    end

    local songs = {}
    for _, song in ipairs(sourceSongs) do
        local normalized = normalizeSong(song)
        if normalized then
            songs[#songs + 1] = normalized
        end
    end

    return {
        title = title,
        songs = songs
    }
end

function M.trackPath(track)
    local file = tostring(track and (track.file or track.name) or "")
    if file ~= "" and not file:lower():match("%.dfpwm$") then
        file = file .. ".dfpwm"
    end
    return file
end

function M.playlistId(playlist)
    return "local:" .. tostring((playlist and (playlist.localName or playlist.name)) or ""):lower()
end

function M.ensureRoot()
    if not fs.exists(M.ROOT_DIR) then
        fs.makeDir(M.ROOT_DIR)
    end
end

function M.ensurePlaylistDir(dirName, title)
    M.ensureRoot()

    local playlistDir = fs.combine(M.ROOT_DIR, dirName)
    if not fs.exists(playlistDir) then
        fs.makeDir(playlistDir)
    end

    local indexPath = fs.combine(playlistDir, M.DEFAULT_INDEX)
    if not fs.exists(indexPath) then
        local ok, err = util.writeFile(indexPath, serializePlaylist(title or prettifyName(dirName), {}))
        if not ok then
            return nil, err
        end
    end

    return playlistDir, indexPath
end

function M.ensureFavorites()
    return M.ensurePlaylistDir(M.FAVORITES_DIRNAME, M.FAVORITES_TITLE)
end

function M.loadPlaylist(dirName)
    M.ensureRoot()

    local playlistDir = fs.combine(M.ROOT_DIR, dirName)
    local indexPath = fs.combine(playlistDir, M.DEFAULT_INDEX)
    if not fs.exists(indexPath) then
        return nil, "missing index.json"
    end

    local loaded, err = loadPlaylistIndex(indexPath)
    if not loaded then
        return nil, err
    end

    return {
        name = loaded.title ~= "" and loaded.title or prettifyName(dirName),
        localName = dirName,
        localDir = playlistDir,
        index = indexPath,
        isLocal = true,
        isFavorites = dirName == M.FAVORITES_DIRNAME,
        searchText = ((loaded.title ~= "" and loaded.title or prettifyName(dirName)) .. " " .. dirName .. " local"):lower(),
        songs = loaded.songs
    }
end

function M.savePlaylist(dirName, title, songs)
    local playlistDir, indexPath = M.ensurePlaylistDir(dirName, title)
    if not playlistDir then
        return false, indexPath
    end

    return util.writeFile(indexPath, serializePlaylist(title or prettifyName(dirName), songs or {}))
end

function M.loadPlaylists()
    M.ensureRoot()
    M.ensureFavorites()

    local warnings = {}
    local playlists = {}
    local dirNames = fs.list(M.ROOT_DIR)

    table.sort(dirNames, function(left, right)
        if left == M.FAVORITES_DIRNAME then
            return true
        end
        if right == M.FAVORITES_DIRNAME then
            return false
        end
        return tostring(left):lower() < tostring(right):lower()
    end)

    for _, dirName in ipairs(dirNames) do
        local playlistDir = fs.combine(M.ROOT_DIR, dirName)
        if fs.isDir(playlistDir) then
            local loaded, err = M.loadPlaylist(dirName)
            if loaded then
                playlists[#playlists + 1] = loaded
            else
                warnings[#warnings + 1] = dirName .. ": " .. tostring(err)
            end
        end
    end

    return playlists, warnings
end

function M.trackFilePath(playlist, track)
    return fs.combine(playlist.localDir, M.trackPath(track))
end

function M.readTrackData(playlist, track)
    local path = M.trackFilePath(playlist, track)
    local body, err = readBinaryFile(path)
    if body then
        return true, body, path
    end
    return false, err, path
end

function M.writeTrackData(playlistDir, relativePath, body)
    return writeBinaryFile(fs.combine(playlistDir, relativePath), body)
end

return M