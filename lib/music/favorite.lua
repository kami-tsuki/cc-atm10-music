---@diagnostic disable: undefined-global
local catalog = require("music.catalog")
local localLibrary = require("music.local")
local util = require("music.util")

local M = {}

local function sanitizeFileName(value)
    value = tostring(value or "")
    value = value:gsub("[\\/:*?\"<>|]", "_")
    value = value:gsub("%s+", " ")
    value = util.trim(value)
    if value == "" then
        return "track"
    end
    return value
end

local function openForWrite(path)
    return fs.open(path, "wb") or fs.open(path, "w")
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

local function playlistId(playlist)
    if playlist and playlist.isLocal then
        return localLibrary.playlistId(playlist)
    end

    return string.format(
        "remote:%s@%s:%s",
        tostring(playlist and playlist.repo or ""),
        tostring(playlist and playlist.branch or "main"),
        tostring(playlist and playlist.index or "index.txt")
    )
end

local function sourceTrackPath(playlist, track)
    if playlist and playlist.isLocal then
        return localLibrary.trackPath(track)
    end
    return catalog.trackPath(track)
end

local function loadSourceData(playlist, track)
    if playlist and playlist.isLocal then
        return localLibrary.readTrackData(playlist, track)
    end
    return catalog.fetchTrackData(playlist, track)
end

local function readFavoritesPlaylist()
    localLibrary.ensureFavorites()
    return localLibrary.loadPlaylist(localLibrary.FAVORITES_DIRNAME)
end

local function favoriteExtension(track)
    local sourcePath = sourceTrackPath(nil, track)
    local extension = tostring(sourcePath or ""):match("(%.[^./\\]+)$")
    return extension or ".dfpwm"
end

local function makeFavoriteFileName(existingSongs, track)
    local extension = favoriteExtension(track)
    local baseName = sanitizeFileName(track.name or track.file)
    local candidate = baseName .. extension
    local index = 2
    local used = {}

    for _, song in ipairs(existingSongs or {}) do
        used[tostring(song.file or ""):lower()] = true
    end

    while used[candidate:lower()] do
        candidate = string.format("%s_%d%s", baseName, index, extension)
        index = index + 1
    end

    return candidate
end

function M.buildTrackKey(playlist, track)
    local explicit = util.trim(track and (track.favoriteKey or track.sourceKey) or "")
    if explicit ~= "" then
        return explicit
    end

    return playlistId(playlist) .. "|" .. tostring(sourceTrackPath(playlist, track))
end

function M.buildLookup(playlists)
    local lookup = {}

    for _, playlist in ipairs(playlists or {}) do
        for _, track in ipairs(playlist.songs or {}) do
            local key = M.buildTrackKey(playlist, track)
            if playlist.isFavorites or util.trim(track.favoriteKey or "") ~= "" then
                lookup[key] = {
                    playlist = playlist,
                    track = track
                }
            end
        end
    end

    return lookup
end

function M.isFavorited(lookup, playlist, track)
    local key = M.buildTrackKey(playlist, track)
    return lookup and lookup[key] ~= nil, key
end

function M.toggle(playlist, track)
    local favoritesPlaylist, err = readFavoritesPlaylist()
    if not favoritesPlaylist then
        return false, err
    end

    local key = M.buildTrackKey(playlist, track)
    local songs = favoritesPlaylist.songs
    local existingIndex = nil
    for index, song in ipairs(songs) do
        if M.buildTrackKey(favoritesPlaylist, song) == key then
            existingIndex = index
            break
        end
    end

    if existingIndex then
        local existing = songs[existingIndex]
        table.remove(songs, existingIndex)

        if existing and existing.file then
            local targetPath = fs.combine(favoritesPlaylist.localDir, tostring(existing.file))
            if fs.exists(targetPath) then
                fs.delete(targetPath)
            end
        end

        local ok, saveErr = localLibrary.savePlaylist(localLibrary.FAVORITES_DIRNAME, localLibrary.FAVORITES_TITLE, songs)
        if not ok then
            return false, saveErr
        end

        return true, {
            removed = true,
            key = key,
            name = track.name
        }
    end

    local ok, bodyOrError = loadSourceData(playlist, track)
    if not ok then
        return false, bodyOrError
    end

    local destinationFile = makeFavoriteFileName(songs, track)
    local destinationPath = fs.combine(favoritesPlaylist.localDir, destinationFile)
    local written, writeErr = writeBinaryFile(destinationPath, bodyOrError)
    if not written then
        return false, writeErr
    end

    songs[#songs + 1] = {
        name = track.name,
        file = destinationFile,
        favoriteKey = key,
        sourcePlaylist = playlist.name,
        sourceFile = sourceTrackPath(playlist, track),
        sourceName = track.name
    }

    local saved, saveErr = localLibrary.savePlaylist(localLibrary.FAVORITES_DIRNAME, localLibrary.FAVORITES_TITLE, songs)
    if not saved then
        if fs.exists(destinationPath) then
            fs.delete(destinationPath)
        end
        return false, saveErr
    end

    return true, {
        added = true,
        key = key,
        name = track.name,
        destinationFile = destinationFile
    }
end

return M