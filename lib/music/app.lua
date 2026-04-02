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

local ICONS = {
    pagePlaylists = "<",
    pageTracks = ">",
    play = ">",
    pause = "||",
    stop = "[]",
    prev = "<<",
    next = ">>",
    shuffleOn = "<>",
    shuffleOff = "--",
    reload = "R",
    volumeDown = "-",
    volumeUp = "+"
}

local LOOP_ICONS = {
    [0] = "-",
    [1] = "*",
    [2] = "1"
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
        browserPlaylistIndex = util.findIndexByField(playlists, "name", playlistName) or 1,
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
        page = playlistName ~= "" and "tracks" or "playlists",
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
    state.browserPlaylistIndex = index
    state.trackIndex = 1
    state.selectedTrackIndex = 1
    state.trackScroll = 1
    state.status = "Playlist loaded: " .. playlist.name
    state.lastError = nil
    ensureTrackSelection(state)
    interruptPlayback(state, false)
end

local function openPlaylist(state, index)
    local playlist = state.playlists[index]
    if not playlist then
        return
    end

    if state.playlistIndex ~= index then
        setPlaylist(state, index)
    else
        state.browserPlaylistIndex = index
        ensureTrackSelection(state)
        state.dirty = true
    end

    state.page = "tracks"
    state.status = "Playlist: " .. playlist.name
    persist(state)
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
    state.browserPlaylistIndex = state.playlistIndex
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

    if not state.selectedTrackIndex then
        state.selectedTrackIndex = 1
    end

    local maxScroll = math.max(1, #playlist.songs - visibleRows + 1)
    state.trackScroll = util.clamp(state.trackScroll or 1, 1, maxScroll)
    if state.selectedTrackIndex < state.trackScroll then
        state.trackScroll = state.selectedTrackIndex
    elseif state.selectedTrackIndex >= state.trackScroll + visibleRows then
        state.trackScroll = state.selectedTrackIndex - visibleRows + 1
    end
end

local function formatPlaylistLabel(item)
    return item.name .. " (" .. #item.songs .. ")"
end

local function formatTrackLabel(state, item, index)
    local prefix = index == state.trackIndex and state.playing and ">" or " "
    return prefix .. " " .. item.name
end

local function drawControlStrip(ui, y, width, controls)
    local totalRequested = 0
    for _, control in ipairs(controls) do
        totalRequested = totalRequested + control.width
    end

    local remaining = math.max(0, width - totalRequested)
    local x = 1

    for _, control in ipairs(controls) do
        local drawWidth = control.width
        if remaining > 0 then
            drawWidth = drawWidth + 1
            remaining = remaining - 1
        end

        if control.kind == "label" then
            ui:fill(x, y, drawWidth, 1, colors.black, colors.white, " ")
            ui:centerText(x, y, drawWidth, control.label, colors.white, colors.black)
        else
            ui:button(control.id, x, y, drawWidth, control.label, {
                active = control.active,
                height = 1
            })
        end

        x = x + drawWidth
    end
end

local function currentTitle(state)
    if state.page == "playlists" then
        return "Playlist Selection"
    end

    local playlist = currentPlaylist(state)
    return playlist and playlist.name or "No Playlist"
end

local function currentActionText(state)
    if state.lastError and state.lastError ~= "" then
        return state.lastError
    end

    return state.status or "Ready"
end

local function render(state)
    local ui = state.ui
    ui:refreshSize()
    ui:resetHits()

    local width, height = ui.width, ui.height
    local listY = 4
    local footerHeight = 3
    local listHeight = math.max(1, height - listY - footerHeight + 1)
    local playlist = currentPlaylist(state)
    local clock = util.safeFormatTime()
    local pageIsTracks = state.page == "tracks"
    local title = currentTitle(state)

    ui:fill(1, 1, width, height, ui.theme.background)
    ui:fill(1, 1, width, 1, colors.blue)
    ui:text(1, 1, util.truncate("KAMI-RADIO 2.0", math.max(1, width - #clock - 1)), colors.white, colors.blue)
    ui:text(math.max(1, width - #clock + 1), 1, clock, colors.white, colors.blue)
    ui:text(1, 3, util.truncate(title, width), colors.white, colors.black)
    ui:addHit("title_action", 1, 3, width, 3, {
        kind = "title_action"
    })

    if pageIsTracks then
        local trackItems = playlist and playlist.songs or {}
        ensureVisibleSelection(state, listHeight)
        state.trackScroll = ui:list("tracks", 1, listY, width, listHeight, trackItems, state.selectedTrackIndex, state.trackScroll, {
            plain = true,
            formatter = function(item, index)
                return formatTrackLabel(state, item, index)
            end
        })
    else
        local visibleRows = math.max(1, listHeight)
        local maxScroll = math.max(1, #state.playlists - visibleRows + 1)
        state.playlistScroll = util.clamp(state.playlistScroll or 1, 1, maxScroll)
        if state.browserPlaylistIndex < state.playlistScroll then
            state.playlistScroll = state.browserPlaylistIndex
        elseif state.browserPlaylistIndex >= state.playlistScroll + visibleRows then
            state.playlistScroll = state.browserPlaylistIndex - visibleRows + 1
        end

        state.playlistScroll = ui:list("playlists", 1, listY, width, listHeight, state.playlists, state.browserPlaylistIndex, state.playlistScroll, {
            plain = true,
            formatter = function(item)
                return formatPlaylistLabel(item)
            end
        })
    end

    local volumeText = string.format("%02d", math.floor(state.volume * 100))
    drawControlStrip(ui, height - 2, width, {
        { id = "prev_track", width = 4, label = ICONS.prev },
        { id = "play_pause", width = 4, label = state.playing and ICONS.pause or ICONS.play, active = state.playing },
        { id = "stop", width = 4, label = ICONS.stop },
        { id = "next_track", width = 4, label = ICONS.next }
    })
    drawControlStrip(ui, height - 1, width, {
        { id = "shuffle", width = 4, label = state.shuffle and ICONS.shuffleOn or ICONS.shuffleOff, active = state.shuffle },
        { id = "loop", width = 4, label = LOOP_ICONS[state.loopMode] },
        { id = "vol_down", width = 4, label = ICONS.volumeDown },
        { kind = "label", width = 5, label = volumeText },
        { id = "vol_up", width = 4, label = ICONS.volumeUp }
    })
    ui:fill(1, height, width, 1, colors.blue, colors.white, " ")
    ui:text(1, height, util.truncate(currentActionText(state), width), colors.white, colors.blue)

    state.lastRenderClock = clock
    state.dirty = false
end

local function handleClick(state, x, y)
    local hit = state.ui:hitTest(x, y)
    if not hit then
        return
    end

    if hit.id == "playlists" and hit.meta and hit.meta.index then
        state.browserPlaylistIndex = hit.meta.index
        openPlaylist(state, hit.meta.index)
    elseif hit.id == "tracks" and hit.meta and hit.meta.index then
        state.selectedTrackIndex = hit.meta.index
        playSelected(state)
    elseif hit.id == "title_action" then
        if state.page == "tracks" then
            state.page = "playlists"
            state.browserPlaylistIndex = state.playlistIndex
        else
            openPlaylist(state, state.browserPlaylistIndex or state.playlistIndex)
        end
        state.dirty = true
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
    elseif hit.id == "vol_down" then
        adjustVolume(state, -0.05)
    elseif hit.id == "vol_up" then
        adjustVolume(state, 0.05)
    end
end

local function handleKey(state, key)
    local playlist = currentPlaylist(state)
    if state.page == "playlists" then
        if key == keys.up and state.browserPlaylistIndex > 1 then
            state.browserPlaylistIndex = state.browserPlaylistIndex - 1
            state.dirty = true
        elseif key == keys.down and state.browserPlaylistIndex < #state.playlists then
            state.browserPlaylistIndex = state.browserPlaylistIndex + 1
            state.dirty = true
        elseif key == keys.enter then
            openPlaylist(state, state.browserPlaylistIndex)
        elseif key == keys.left or key == keys.right then
            state.page = "tracks"
            state.dirty = true
        end
        return
    end

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
    elseif key == keys.backspace then
        state.page = "playlists"
        state.browserPlaylistIndex = state.playlistIndex
        state.dirty = true
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