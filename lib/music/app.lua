---@diagnostic disable: undefined-global, undefined-field
local audio = require("music.audio")
local catalog = require("music.catalog")
local config = require("music.config")
local UI = require("music.ui")
local util = require("music.util")

local M = {}

local SETTINGS = {
    playlist = "ccmusic.playlist",
    track = "ccmusic.track",
    shuffle = "ccmusic.shuffle",
    loopMode = "ccmusic.loopMode",
    volume = "ccmusic.volume",
    playing = "ccmusic.playing",
    trackScroll = "ccmusic.trackScroll",
    playlistScroll = "ccmusic.playlistScroll"
}

local LOOP_LABELS = {
    [0] = "Loop Off",
    [1] = "Loop All",
    [2] = "Loop One"
}

local COMPACT_LOOP_LABELS = {
    [0] = "Off",
    [1] = "All",
    [2] = "One"
}

local function findDisplay()
    local monitor = peripheral.find("monitor")
    if monitor then
        pcall(function()
            monitor.setTextScale(0.5)
        end)
        return monitor, true
    end
    return term.current(), false
end

local function randomSeed()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 100000) + os.time()
end

local function persist(state)
    local playlist = state.playlists[state.playlistIndex]
    local track = playlist and playlist.songs[state.trackIndex] or nil

    settings.set(SETTINGS.playlist, playlist and playlist.name or "")
    settings.set(SETTINGS.track, track and track.name or "")
    settings.set(SETTINGS.shuffle, state.shuffle)
    settings.set(SETTINGS.loopMode, state.loopMode)
    settings.set(SETTINGS.volume, state.volume)
    settings.set(SETTINGS.playing, state.playing)
    settings.set(SETTINGS.trackScroll, state.trackScroll)
    settings.set(SETTINGS.playlistScroll, state.playlistScroll)
    settings.save()
end

local function currentPlaylist(state)
    return state.playlists[state.playlistIndex]
end

local function currentTrack(state)
    local playlist = currentPlaylist(state)
    return playlist and playlist.songs[state.trackIndex] or nil
end

local function ensureTrackSelection(state)
    local playlist = currentPlaylist(state)
    if not playlist or #playlist.songs == 0 then
        state.trackIndex = nil
        state.selectedTrackIndex = nil
        return
    end

    state.trackIndex = util.clamp(state.trackIndex or 1, 1, #playlist.songs)
    state.selectedTrackIndex = util.clamp(state.selectedTrackIndex or state.trackIndex, 1, #playlist.songs)
end

local function makeState(playlists, warnings)
    local playlistName = settings.get(SETTINGS.playlist, "")
    local trackName = settings.get(SETTINGS.track, "")

    local state = {
        playlists = playlists,
        warnings = warnings,
        playlistIndex = util.findIndexByField(playlists, "name", playlistName) or 1,
        trackIndex = 1,
        selectedTrackIndex = 1,
        shuffle = settings.get(SETTINGS.shuffle, true),
        loopMode = settings.get(SETTINGS.loopMode, 0),
        volume = util.clamp(settings.get(SETTINGS.volume, 0.35), 0, 1),
        playing = settings.get(SETTINGS.playing, false),
        trackScroll = settings.get(SETTINGS.trackScroll, 1),
        playlistScroll = settings.get(SETTINGS.playlistScroll, 1),
        playbackToken = 0,
        status = "Ready",
        lastError = nil,
        speakers = audio.findSpeakers(),
        dirty = true,
        lastRenderClock = nil,
        hasMonitor = false,
        ui = nil,
        display = nil
    }

    local playlist = playlists[state.playlistIndex]
    if playlist and trackName ~= "" then
        local restoredTrack = util.findIndexByField(playlist.songs, "name", trackName)
        if restoredTrack then
            state.trackIndex = restoredTrack
            state.selectedTrackIndex = restoredTrack
        end
    end

    ensureTrackSelection(state)
    persist(state)
    return state
end

local function advanceTrack(state)
    local playlist = currentPlaylist(state)
    if not playlist or #playlist.songs == 0 then
        state.playing = false
        return
    end

    if state.loopMode == 2 then
        return
    end

    if state.shuffle and #playlist.songs > 1 then
        local nextIndex = math.random(#playlist.songs)
        if nextIndex == state.trackIndex then
            nextIndex = (nextIndex % #playlist.songs) + 1
        end
        state.trackIndex = nextIndex
        state.selectedTrackIndex = nextIndex
        return
    end

    local nextIndex = (state.trackIndex or 1) + 1
    if nextIndex > #playlist.songs then
        if state.loopMode == 1 then
            nextIndex = 1
        else
            state.playing = false
            return
        end
    end

    state.trackIndex = nextIndex
    state.selectedTrackIndex = nextIndex
end

local function interruptPlayback(state, keepPlaying)
    state.playbackToken = state.playbackToken + 1
    state.playing = keepPlaying
    state.dirty = true
    persist(state)
end

local function setPlaylist(state, index)
    local playlist = state.playlists[index]
    if not playlist then
        return
    end

    state.playlistIndex = index
    state.trackIndex = 1
    state.selectedTrackIndex = 1
    state.trackScroll = 1
    state.status = "Playlist loaded: " .. playlist.name
    state.lastError = nil
    ensureTrackSelection(state)
    interruptPlayback(state, false)
end

local function playSelected(state)
    if not currentPlaylist(state) then
        return
    end

    state.trackIndex = state.selectedTrackIndex
    local track = currentTrack(state)
    state.status = track and ("Buffering " .. track.name) or "Ready"
    state.lastError = nil
    interruptPlayback(state, true)
end

local function stopPlayback(state)
    state.status = "Stopped"
    state.lastError = nil
    interruptPlayback(state, false)
end

local function togglePlayPause(state)
    if state.playing then
        stopPlayback(state)
    else
        playSelected(state)
    end
end

local function stepTrack(state, direction)
    local playlist = currentPlaylist(state)
    if not playlist or #playlist.songs == 0 then
        return
    end

    local nextIndex = (state.trackIndex or 1) + direction
    if nextIndex < 1 then
        nextIndex = #playlist.songs
    elseif nextIndex > #playlist.songs then
        nextIndex = 1
    end

    state.selectedTrackIndex = nextIndex
    state.trackIndex = nextIndex
    playSelected(state)
end

local function adjustVolume(state, delta)
    state.volume = util.clamp(state.volume + delta, 0, 1)
    state.status = string.format("Volume %.0f%%", state.volume * 100)
    state.dirty = true
    persist(state)
end

local function reloadCatalog(state)
    local currentPlaylistName = currentPlaylist(state) and currentPlaylist(state).name or ""
    local currentTrackName = currentTrack(state) and currentTrack(state).name or ""
    local entries = config.load("config.json")
    local playlists, warnings = catalog.loadPlaylists(entries)
    if #playlists == 0 then
        error("No playable playlists were loaded from config.json.")
    end

    state.playlists = playlists
    state.warnings = warnings
    state.playlistIndex = util.findIndexByField(playlists, "name", currentPlaylistName) or 1
    local playlist = currentPlaylist(state)
    state.trackIndex = playlist and (util.findIndexByField(playlist.songs, "name", currentTrackName) or 1) or 1
    state.selectedTrackIndex = state.trackIndex
    state.status = "Library refreshed"
    state.lastError = nil
    ensureTrackSelection(state)
    state.dirty = true
    persist(state)
end

local function ensureVisibleSelection(state, visibleRows)
    visibleRows = math.max(1, visibleRows)
    local playlist = currentPlaylist(state)
    if not playlist then
        state.trackScroll = 1
        return
    end

    local maxScroll = math.max(1, #playlist.songs - visibleRows + 1)
    state.trackScroll = util.clamp(state.trackScroll, 1, maxScroll)

    if state.selectedTrackIndex < state.trackScroll then
        state.trackScroll = state.selectedTrackIndex
    elseif state.selectedTrackIndex >= state.trackScroll + visibleRows then
        state.trackScroll = state.selectedTrackIndex - visibleRows + 1
    end

    state.trackScroll = util.clamp(state.trackScroll, 1, maxScroll)
end

local function drawButtonRow(ui, y, width, buttons, buttonHeight)
    local gap = 1
    local innerWidth = math.max(1, width - 2)
    local buttonWidth = math.max(4, math.floor((innerWidth - ((#buttons - 1) * gap)) / #buttons))
    local totalWidth = (buttonWidth * #buttons) + ((#buttons - 1) * gap)
    local x = math.max(2, math.floor((width - totalWidth) / 2) + 1)

    for _, button in ipairs(buttons) do
        ui:button(button.id, x, y, buttonWidth, button.label, {
            active = button.active,
            height = buttonHeight
        })
        x = x + buttonWidth + gap
    end
end

local function formatPlaylistLabel(item, compact)
    if compact then
        return string.format("%s (%d)", item.name, #item.songs)
    end

    return item.name .. " (" .. #item.songs .. ")"
end

local function formatTrackLabel(state, item, index, compact)
    local prefix = index == state.trackIndex and state.playing and ">" or " "
    if compact then
        return prefix .. " " .. item.name
    end

    return prefix .. " " .. item.name
end

local function render(state)
    local ui = state.ui
    ui:refreshSize()
    ui:resetHits()

    local width, height = ui.width, ui.height
    local compact = width < 38
    local headerHeight = 2
    local footerHeight = 4
    local bodyY = headerHeight + 1
    local bodyHeight = math.max(6, height - headerHeight - footerHeight)
    local playlist = currentPlaylist(state)
    local track = currentTrack(state)
    local clock = util.safeFormatTime()

    ui:fill(1, 1, width, height, ui.theme.background)
    ui:fill(1, 1, width, headerHeight, colors.blue)
    ui:text(2, 1, compact and "CC MUSIC" or "CC ATM10 MUSIC", colors.white, colors.blue)
    ui:text(2, 2, util.truncate(state.status, width - 4), colors.white, colors.blue)

    local badgeX = width - 2
    local badges = {
        state.hasMonitor and "MON" or "TERM",
        (#state.speakers) .. "SP",
        clock
    }

    for index = #badges, 1, -1 do
        local text = badges[index]
        local badgeWidth = #text + 2
        if badgeX - badgeWidth < 11 then
            break
        end
        badgeX = badgeX - badgeWidth
        ui:badge(badgeX, 1, text, colors.lightBlue, colors.white)
        badgeX = badgeX - 1
    end

    local trackItems = playlist and playlist.songs or {}

    if compact then
        local infoHeight = 3
        local listHeight = math.max(4, bodyHeight - infoHeight)
        local stationsHeight = math.max(4, math.floor(listHeight * 0.38))
        local tracksHeight = math.max(4, listHeight - stationsHeight)
        local stationsY = bodyY + infoHeight
        local tracksY = stationsY + stationsHeight

        ui:panel(1, bodyY, width, infoHeight, "Now", colors.cyan)
        ui:text(2, bodyY + 1, util.truncate(track and track.name or "No track selected", width - 2), colors.white, ui.theme.surface)

        local detailLine = state.lastError
            or ((playlist and playlist.name or "No playlist") .. " | " .. COMPACT_LOOP_LABELS[state.loopMode] .. " | " .. (state.shuffle and "Shf" or "Seq"))
        ui:text(2, bodyY + 2, util.truncate(detailLine, width - 2), state.lastError and colors.red or colors.lightGray, ui.theme.surface)

        state.playlistScroll = ui:list("playlists", 1, stationsY, width, stationsHeight, state.playlists, state.playlistIndex, state.playlistScroll, {
            title = "Stations",
            formatter = function(item)
                return formatPlaylistLabel(item, true)
            end
        })

        local visibleTrackRows = math.max(1, tracksHeight - 1)
        ensureVisibleSelection(state, visibleTrackRows)
        state.trackScroll = ui:list("tracks", 1, tracksY, width, tracksHeight, trackItems, state.selectedTrackIndex, state.trackScroll, {
            title = "Tracks",
            formatter = function(item, index)
                return formatTrackLabel(state, item, index, true)
            end
        })
    else
        local playlistPanelWidth = math.max(14, math.min(22, math.floor(width * 0.34)))
        local rightX = playlistPanelWidth + 1
        local rightWidth = width - playlistPanelWidth
        local infoHeight = 4
        local tracksY = bodyY + infoHeight
        local tracksHeight = math.max(4, bodyHeight - infoHeight)

        state.playlistScroll = ui:list("playlists", 1, bodyY, playlistPanelWidth, bodyHeight, state.playlists, state.playlistIndex, state.playlistScroll, {
            title = "Stations",
            formatter = function(item)
                return formatPlaylistLabel(item, false)
            end
        })

        ui:panel(rightX, bodyY, rightWidth, infoHeight, "Now Playing", colors.cyan)
        ui:text(rightX + 1, bodyY + 1, util.truncate(track and track.name or "No track selected", rightWidth - 2), colors.white, ui.theme.surface)
        ui:text(rightX + 1, bodyY + 2, util.truncate(playlist and playlist.name or "No playlist loaded", rightWidth - 2), colors.lightGray, ui.theme.surface)

        local detailLine = state.lastError
            or (LOOP_LABELS[state.loopMode] .. " | Shuffle " .. (state.shuffle and "On" or "Off") .. " | Vol " .. math.floor(state.volume * 100) .. "%")
        ui:text(rightX + 1, bodyY + 3, util.truncate(detailLine, rightWidth - 2), state.lastError and colors.red or colors.lightGray, ui.theme.surface)

        local visibleTrackRows = math.max(1, tracksHeight - 1)
        ensureVisibleSelection(state, visibleTrackRows)
        state.trackScroll = ui:list("tracks", rightX, tracksY, rightWidth, tracksHeight, trackItems, state.selectedTrackIndex, state.trackScroll, {
            title = "Tracks",
            formatter = function(item, index)
                return formatTrackLabel(state, item, index, false)
            end
        })
    end

    local controlsY = height - footerHeight + 1
    ui:fill(1, controlsY, width, footerHeight, colors.black)

    local primaryButtons = {
        { id = "play_pause", label = state.playing and "Pause" or "Play", active = state.playing },
        { id = "stop", label = "Stop" },
        { id = "prev_track", label = "Prev" },
        { id = "next_track", label = "Next" }
    }

    drawButtonRow(ui, controlsY, width, primaryButtons, 2)

    local volumeText = string.format("Vol %d", math.floor(state.volume * 100))
    if compact then
        ui:button("shuffle", 2, controlsY + 2, 5, state.shuffle and "Shf" or "Seq", {
            active = state.shuffle,
            height = 2
        })
        ui:button("loop", 8, controlsY + 2, 5, COMPACT_LOOP_LABELS[state.loopMode], { height = 2 })
        ui:button("vol_down", width - 11, controlsY + 2, 3, "-", { height = 2 })
        ui:text(width - 7, controlsY + 3, util.truncate(volumeText, 5), colors.white, colors.black)
        ui:button("vol_up", width - 3, controlsY + 2, 3, "+", { height = 2 })
    else
        ui:button("shuffle", 2, controlsY + 2, 8, state.shuffle and "Shuffle" or "Linear", {
            active = state.shuffle,
            height = 2
        })
        ui:button("loop", 11, controlsY + 2, 8, COMPACT_LOOP_LABELS[state.loopMode], { height = 2 })
        ui:button("reload", 20, controlsY + 2, 7, "Reload", { height = 2 })
        ui:button("vol_down", width - 14, controlsY + 2, 3, "-", { height = 2 })
        ui:text(width - 10, controlsY + 3, util.truncate(volumeText, 7), colors.white, colors.black)
        ui:button("vol_up", width - 3, controlsY + 2, 3, "+", { height = 2 })
    end

    state.lastRenderClock = clock
    state.dirty = false
end

local function handleClick(state, x, y)
    local hit = state.ui:hitTest(x, y)
    if not hit then
        return
    end

    if hit.id == "playlists" and hit.meta and hit.meta.index then
        setPlaylist(state, hit.meta.index)
    elseif hit.id == "tracks" and hit.meta and hit.meta.index then
        state.selectedTrackIndex = hit.meta.index
        playSelected(state)
    elseif hit.id == "play_pause" then
        togglePlayPause(state)
    elseif hit.id == "stop" then
        stopPlayback(state)
    elseif hit.id == "prev_track" then
        stepTrack(state, -1)
    elseif hit.id == "next_track" then
        stepTrack(state, 1)
    elseif hit.id == "shuffle" then
        state.shuffle = not state.shuffle
        state.status = state.shuffle and "Shuffle enabled" or "Shuffle disabled"
        state.dirty = true
        persist(state)
    elseif hit.id == "loop" then
        state.loopMode = (state.loopMode + 1) % 3
        state.status = LOOP_LABELS[state.loopMode]
        state.dirty = true
        persist(state)
    elseif hit.id == "reload" then
        reloadCatalog(state)
    elseif hit.id == "vol_down" then
        adjustVolume(state, -0.05)
    elseif hit.id == "vol_up" then
        adjustVolume(state, 0.05)
    end
end

local function handleKey(state, key)
    local playlist = currentPlaylist(state)
    if key == keys.up and playlist and state.selectedTrackIndex and state.selectedTrackIndex > 1 then
        state.selectedTrackIndex = state.selectedTrackIndex - 1
        state.dirty = true
        persist(state)
    elseif key == keys.down and playlist and state.selectedTrackIndex and state.selectedTrackIndex < #playlist.songs then
        state.selectedTrackIndex = state.selectedTrackIndex + 1
        state.dirty = true
        persist(state)
    elseif key == keys.enter then
        playSelected(state)
    elseif key == keys.space then
        togglePlayPause(state)
    elseif key == keys.leftBracket then
        adjustVolume(state, -0.05)
    elseif key == keys.rightBracket then
        adjustVolume(state, 0.05)
    elseif key == keys.left then
        stepTrack(state, -1)
    elseif key == keys.right then
        stepTrack(state, 1)
    elseif key == keys.s then
        stopPlayback(state)
    elseif key == keys.r then
        reloadCatalog(state)
    end
end

local function playerLoop(state)
    while true do
        local playlist = currentPlaylist(state)
        local track = currentTrack(state)
        if playlist and track and state.playing then
            local token = state.playbackToken
            state.status = "Buffering " .. track.name
            state.lastError = nil
            state.dirty = true

            local ok, dataOrError = catalog.fetchTrackData(playlist, track)
            if token ~= state.playbackToken or not state.playing then
            elseif not ok then
                state.status = "Failed to load track"
                state.lastError = tostring(dataOrError)
                state.playing = false
                state.dirty = true
                persist(state)
            else
                state.status = "Playing " .. track.name
                state.dirty = true
                persist(state)

                local completed = audio.playData(dataOrError, state.speakers, function()
                    return state.volume
                end, function()
                    return token ~= state.playbackToken or not state.playing
                end)

                if token ~= state.playbackToken then
                elseif completed then
                    advanceTrack(state)
                    if not state.playing then
                        state.status = "Queue ended"
                    end
                    persist(state)
                    state.dirty = true
                else
                    state.status = state.playing and "Switching track" or "Stopped"
                    state.dirty = true
                    persist(state)
                end
            end
        else
            sleep(0.05)
        end
    end
end

local function renderLoop(state)
    while true do
        local clock = util.safeFormatTime()
        if state.dirty or clock ~= state.lastRenderClock then
            render(state)
        end
        sleep(0.1)
    end
end

local function inputLoop(state)
    while true do
        local event, a, b, c = os.pullEvent()
        if event == "mouse_click" then
            handleClick(state, b, c)
        elseif event == "monitor_touch" then
            handleClick(state, b, c)
        elseif event == "key" then
            handleKey(state, a)
        elseif event == "term_resize" or event == "monitor_resize" then
            state.dirty = true
        end
    end
end

function M.run()
    math.randomseed(randomSeed())

    if not http then
        error("HTTP API is required for remote playlists.")
    end

    local entries = config.load("config.json")
    local playlists, warnings = catalog.loadPlaylists(entries)
    if #playlists == 0 then
        error("No playable playlists were loaded from config.json.")
    end

    local display, hasMonitor = findDisplay()
    local state = makeState(playlists, warnings)
    state.display = display
    state.hasMonitor = hasMonitor
    state.ui = UI.new(display)
    state.status = #warnings > 0 and ("Ready with " .. #warnings .. " warning(s)") or "Ready"

    parallel.waitForAny(
        function()
            playerLoop(state)
        end,
        function()
            renderLoop(state)
        end,
        function()
            inputLoop(state)
        end
    )
end

return M