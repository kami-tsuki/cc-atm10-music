---@diagnostic disable: undefined-global, undefined-field
local audio = require("music.audio")
local catalog = require("music.catalog")
local config = require("music.config")
local UI = require("music.ui")
local updater = require("music.updater")
local util = require("music.util")

local M = {}

local PERSIST_DELAY = 0.2

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

local function monotonicTime()
    if os.epoch then
        return os.epoch("utc") / 1000
    end
    return os.clock()
end

local function capturePersistSnapshot(state)
    local playlist = state.playlists[state.playlistIndex]
    local track = playlist and playlist.songs[state.trackIndex] or nil

    return {
        playlist = playlist and playlist.name or "",
        track = track and track.name or "",
        shuffle = state.shuffle,
        loopMode = state.loopMode,
        volume = state.volume,
        playing = state.playing,
        trackScroll = state.trackScroll,
        playlistScroll = state.playlistScroll
    }
end

local function persistSnapshotsEqual(left, right)
    if not left or not right then
        return false
    end

    return left.playlist == right.playlist
        and left.track == right.track
        and left.shuffle == right.shuffle
        and left.loopMode == right.loopMode
        and left.volume == right.volume
        and left.playing == right.playing
        and left.trackScroll == right.trackScroll
        and left.playlistScroll == right.playlistScroll
end

local function flushPersist(state)
    if not state.persistPending then
        return
    end

    local snapshot = capturePersistSnapshot(state)
    state.persistPending = false

    if persistSnapshotsEqual(snapshot, state.lastPersistSnapshot) then
        return
    end

    settings.set(SETTINGS.playlist, snapshot.playlist)
    settings.set(SETTINGS.track, snapshot.track)
    settings.set(SETTINGS.shuffle, snapshot.shuffle)
    settings.set(SETTINGS.loopMode, snapshot.loopMode)
    settings.set(SETTINGS.volume, snapshot.volume)
    settings.set(SETTINGS.playing, snapshot.playing)
    settings.set(SETTINGS.trackScroll, snapshot.trackScroll)
    settings.set(SETTINGS.playlistScroll, snapshot.playlistScroll)
    settings.save()

    state.lastPersistSnapshot = snapshot
end

local function persist(state, immediate)
    state.persistPending = true
    state.nextPersistAt = immediate and monotonicTime() or (monotonicTime() + PERSIST_DELAY)
    if immediate then
        flushPersist(state)
    end
end

local function flushPersistIfDue(state, force)
    if not state.persistPending then
        return
    end

    if force or monotonicTime() >= (state.nextPersistAt or 0) then
        flushPersist(state)
    end
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
        manualTrackScroll = false,
        playbackToken = 0,
        status = "Ready",
        lastError = nil,
        speakers = audio.findSpeakers(),
        dirty = true,
        hasMonitor = false,
        page = playlistName ~= "" and "tracks" or "playlists",
        ui = nil,
        display = nil,
        modal = nil,
        updateInfo = nil,
        exitRequested = false,
        rebootRequested = false,
        playlistSearch = "",
        trackSearch = "",
        activeSearch = nil,
        playbackProgress = 0,
        clockText = util.safeFormatTime(),
        nextClockRefreshAt = 0,
        nextPersistAt = 0,
        persistPending = false,
        lastPersistSnapshot = nil,
        libraryRevision = 1,
        playlistSearchKey = "",
        trackSearchKey = "",
        caches = {
            playlists = {
                key = nil,
                items = {},
                selectedIndex = nil
            },
            tracks = {
                key = nil,
                items = {},
                selectedIndex = nil
            }
        }
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
    persist(state, true)
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
        state.manualTrackScroll = false
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
    state.manualTrackScroll = false
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
    state.manualTrackScroll = false
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
    state.playbackProgress = 0
    state.status = "Playlist: " .. playlist.name
    persist(state)
end

local function playSelected(state)
    if not currentPlaylist(state) then
        return
    end

    state.manualTrackScroll = false
    state.trackIndex = state.selectedTrackIndex
    state.playbackProgress = 0
    local track = currentTrack(state)
    state.status = track and ("Buffering " .. track.name) or "Ready"
    state.lastError = nil
    interruptPlayback(state, true)
end

local function stopPlayback(state)
    state.playbackProgress = 0
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
    state.manualTrackScroll = false
    playSelected(state)
end

local function adjustVolume(state, delta)
    state.volume = util.clamp(state.volume + delta, 0, 1)
    state.status = string.format("Volume %.0f%%", state.volume * 100)
    state.dirty = true
    persist(state)
end

local function invalidateCache(state, target)
    if target == "playlists" or not target then
        state.caches.playlists.key = nil
    end
    if target == "tracks" or not target then
        state.caches.tracks.key = nil
    end
end

local function matchesQuery(value, query)
    if not query or query == "" then
        return true
    end

    return tostring(value or ""):find(query, 1, true) ~= nil
end

local function buildPlaylistItems(state)
    local cacheKey = table.concat({
        state.playlistSearchKey,
        tostring(state.browserPlaylistIndex),
        tostring(state.libraryRevision)
    }, "\31")

    local cache = state.caches.playlists
    if cache.key == cacheKey then
        return cache.items, cache.selectedIndex
    end

    local items = {}
    local selectedIndex = nil

    for index, item in ipairs(state.playlists) do
        if matchesQuery(item.searchText or "", state.playlistSearchKey) then
            items[#items + 1] = {
                sourceIndex = index,
                sourceItem = item
            }
            if index == state.browserPlaylistIndex then
                selectedIndex = #items
            end
        end
    end

    cache.key = cacheKey
    cache.items = items
    cache.selectedIndex = selectedIndex
    return items, selectedIndex
end

local function buildTrackItems(state)
    local playlist = currentPlaylist(state)
    local cacheKey = table.concat({
        tostring(state.libraryRevision),
        tostring(state.playlistIndex or 0),
        state.trackSearchKey,
        tostring(state.selectedTrackIndex or 0)
    }, "\31")

    local cache = state.caches.tracks
    if cache.key == cacheKey then
        return cache.items, cache.selectedIndex
    end

    local items = {}
    local selectedIndex = nil

    if not playlist then
        cache.key = cacheKey
        cache.items = items
        cache.selectedIndex = selectedIndex
        return items, selectedIndex
    end

    for index, item in ipairs(playlist.songs) do
        if matchesQuery(item.searchText or "", state.trackSearchKey) then
            items[#items + 1] = {
                sourceIndex = index,
                sourceItem = item
            }
            if index == state.selectedTrackIndex then
                selectedIndex = #items
            end
        end
    end

    cache.key = cacheKey
    cache.items = items
    cache.selectedIndex = selectedIndex
    return items, selectedIndex
end

local function setSearchQuery(state, target, query)
    query = tostring(query or "")
    local normalizedQuery = util.trim(query):lower()

    if target == "playlists" then
        state.playlistSearch = query
        state.playlistSearchKey = normalizedQuery
        invalidateCache(state, "playlists")
        local items, selectedIndex = buildPlaylistItems(state)
        if #items > 0 and not selectedIndex then
            state.browserPlaylistIndex = items[1].sourceIndex
            invalidateCache(state, "playlists")
        end
        state.playlistScroll = 1
    elseif target == "tracks" then
        state.trackSearch = query
        state.trackSearchKey = normalizedQuery
        invalidateCache(state, "tracks")
        local items, selectedIndex = buildTrackItems(state)
        if #items > 0 and not selectedIndex then
            state.selectedTrackIndex = items[1].sourceIndex
            invalidateCache(state, "tracks")
        end
        state.trackScroll = 1
        state.manualTrackScroll = false
    end

    state.dirty = true
end

local function currentSearchTarget(state)
    return state.page == "tracks" and "tracks" or "playlists"
end

local function isSearchActive(state)
    return state.activeSearch ~= nil and state.activeSearch == currentSearchTarget(state)
end

local function moveFilteredSelection(state, target, delta)
    local items, selectedIndex
    if target == "tracks" then
        items, selectedIndex = buildTrackItems(state)
    else
        items, selectedIndex = buildPlaylistItems(state)
    end

    if #items == 0 then
        return false
    end

    selectedIndex = util.clamp((selectedIndex or 1) + delta, 1, #items)
    local sourceIndex = items[selectedIndex].sourceIndex

    if target == "tracks" then
        state.selectedTrackIndex = sourceIndex
        state.manualTrackScroll = false
        invalidateCache(state, "tracks")
        persist(state)
    else
        state.browserPlaylistIndex = sourceIndex
        invalidateCache(state, "playlists")
    end

    state.dirty = true
    return true
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
    invalidateCache(state)
    state.libraryRevision = state.libraryRevision + 1
    state.playlistIndex = util.findIndexByField(playlists, "name", currentPlaylistName) or 1
    state.browserPlaylistIndex = state.playlistIndex
    local playlist = currentPlaylist(state)
    state.trackIndex = playlist and (util.findIndexByField(playlist.songs, "name", currentTrackName) or 1) or 1
    state.selectedTrackIndex = state.trackIndex
    state.manualTrackScroll = false
    state.playbackProgress = 0
    state.status = "Library refreshed"
    state.lastError = nil
    ensureTrackSelection(state)
    state.dirty = true
    persist(state)

    setSearchQuery(state, "playlists", state.playlistSearch)
    setSearchQuery(state, "tracks", state.trackSearch)
end

local function setPlaybackProgress(state, ratio)
    local width = math.max(1, (state.ui and state.ui.width) or 32)
    local quantized = math.floor((util.clamp(ratio or 0, 0, 1) * width) + 0.5) / width
    if quantized ~= state.playbackProgress then
        state.playbackProgress = quantized
        state.dirty = true
    end
end

local function refreshClock(state)
    local now = monotonicTime()
    if now < state.nextClockRefreshAt then
        return
    end

    state.nextClockRefreshAt = now + 1
    local nextClock = util.safeFormatTime()
    if nextClock ~= state.clockText then
        state.clockText = nextClock
        state.dirty = true
    end
end

local function ensureVisibleRow(scroll, selectedRow, totalRows, visibleRows)
    visibleRows = math.max(1, visibleRows)
    totalRows = math.max(0, totalRows or 0)

    if totalRows == 0 or not selectedRow then
        return 1
    end

    local maxScroll = math.max(1, totalRows - visibleRows + 1)
    scroll = util.clamp(scroll or 1, 1, maxScroll)
    if selectedRow < scroll then
        scroll = selectedRow
    elseif selectedRow >= scroll + visibleRows then
        scroll = selectedRow - visibleRows + 1
    end

    return util.clamp(scroll, 1, maxScroll)
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
            ui:fill(x, y, drawWidth, 1, ui.theme.label or ui.theme.surfaceAlt, ui.theme.labelText or ui.theme.text, " ")
            ui:centerText(x, y, drawWidth, control.label, ui.theme.labelText or ui.theme.text, ui.theme.label or ui.theme.surfaceAlt)
        else
            ui:button(control.id, x, y, drawWidth, control.label, {
                active = control.active,
                height = 1
            })
        end

        x = x + drawWidth
    end
end

local function drawSearchRow(state, target)
    local ui = state.ui
    local label = target == "tracks" and "Songs" or "Playlists"
    local value = target == "tracks" and state.trackSearch or state.playlistSearch

    ui:input("search_box", 1, 2, ui.width, label, value, {
        active = state.activeSearch == target,
        placeholder = target == "tracks" and "Type to filter songs" or "Type to filter playlists",
        meta = {
            target = target
        }
    })
end

local function makeModal(title, message, buttons, options)
    options = options or {}

    return {
        title = title or "Notice",
        message = message or "",
        buttons = buttons or {},
        selectedIndex = options.selectedIndex or ((buttons and #buttons > 0) and 1 or nil),
        accent = options.accent,
        progress = options.progress,
        busy = options.busy or false
    }
end

local function buildReadyStatus(warnings, updateErr)
    local parts = {}
    if #warnings > 0 then
        parts[#parts + 1] = "Ready with " .. #warnings .. " warning(s)"
    else
        parts[#parts + 1] = "Ready"
    end

    if updateErr then
        parts[#parts + 1] = "update check failed"
    end

    return table.concat(parts, " | ")
end

local function showUpdatePrompt(state, updateInfo)
    state.updateInfo = updateInfo
    state.modal = makeModal(
        "Update Available",
        string.format(
            "A new version is available. Update from %s to %s now?",
            updateInfo.currentVersion,
            updateInfo.targetVersion
        ),
        {
            { id = "update_confirm", label = "Update Now" },
            { id = "update_cancel", label = "Later" }
        },
        {
            selectedIndex = 1
        }
    )
    state.status = "Update available: " .. updateInfo.targetVersion
    state.lastError = nil
    state.dirty = true
end

local function renderModal(state)
    local modal = state.modal
    if not modal then
        return
    end

    local ui = state.ui
    local width = math.max(28, math.min(ui.width - 2, 46))
    local messageWidth = math.max(1, width - 4)
    local messageLines = util.wrapText(modal.message or "", messageWidth)
    local progressRows = modal.progress and 2 or 0
    local buttonRows = (#modal.buttons > 0) and 2 or 0
    local maxMessageRows = math.max(2, ui.height - progressRows - buttonRows - 7)

    while #messageLines > maxMessageRows do
        messageLines[#messageLines] = nil
    end

    if #messageLines == 0 then
        messageLines[1] = ""
    end

    if #messageLines == maxMessageRows and #util.wrapText(modal.message or "", messageWidth) > maxMessageRows then
        messageLines[#messageLines] = util.truncate(messageLines[#messageLines], math.max(1, messageWidth - 3)) .. "..."
    end

    local height = math.max(8, #messageLines + progressRows + buttonRows + 4)
    local box = ui:modal(width, math.min(ui.height, height), modal.title, modal.accent)
    local textX = box.innerX
    local textY = box.innerY

    for _, line in ipairs(messageLines) do
        if textY > box.y + box.height - 3 then
            break
        end

        ui:text(textX, textY, util.truncate(line, box.innerWidth), ui.theme.text, ui.theme.surface)
        textY = textY + 1
    end

    if modal.progress then
        ui:text(textX, textY, util.truncate(modal.progress.message or "", box.innerWidth), ui.theme.labelText or ui.theme.text, ui.theme.surface)
        textY = textY + 1
        ui:progress(textX, textY, box.innerWidth, modal.progress.ratio or 0)
        textY = textY + 1
    end

    if #modal.buttons > 0 then
        local gap = #modal.buttons > 1 and 1 or 0
        local totalGap = (#modal.buttons - 1) * gap
        local remaining = math.max(0, box.innerWidth - totalGap)
        local buttonWidth = math.max(10, math.floor(remaining / #modal.buttons))
        local totalWidth = (buttonWidth * #modal.buttons) + totalGap
        local buttonX = box.innerX + math.max(0, math.floor((box.innerWidth - totalWidth) / 2))
        local buttonY = box.y + box.height - 2

        for index, button in ipairs(modal.buttons) do
            local drawWidth = buttonWidth
            if index == #modal.buttons then
                drawWidth = math.max(buttonWidth, (box.innerX + box.innerWidth) - buttonX)
            end

            ui:button("modal_button", buttonX, buttonY, drawWidth, button.label, {
                active = index == modal.selectedIndex,
                height = 1,
                meta = {
                    index = index,
                    id = button.id
                }
            })
            buttonX = buttonX + drawWidth + gap
        end
    end
end

local function performUpdate(state)
    local updateInfo = state.updateInfo
    if not updateInfo or not updateInfo.remoteManifest then
        return
    end

    interruptPlayback(state, false)

    state.modal = makeModal(
        "Updating",
        "Preparing update...",
        nil,
        {
            busy = true,
            progress = {
                ratio = 0,
                message = "Preparing update..."
            }
        }
    )
    state.status = "Applying update " .. updateInfo.targetVersion
    state.lastError = nil
    state.dirty = true

    local ok, resultOrError = updater.installFromManifest(updateInfo.remoteManifest, {
        onProgress = function(info)
            if state.modal then
                state.modal.message = info.message or state.modal.message
                state.modal.progress = info
            end
            state.status = info.message or state.status
            state.dirty = true
        end
    })

    if ok then
        state.status = "Updated to version " .. updateInfo.targetVersion
        state.modal = makeModal(
            "Update Complete",
            string.format(
                "Updated from %s to %s. Restarting now...",
                updateInfo.currentVersion,
                updateInfo.targetVersion
            ),
            nil,
            {
                busy = true,
                progress = {
                    ratio = 1,
                    message = "Restarting..."
                }
            }
        )
        state.dirty = true
        sleep(0.4)
        state.exitRequested = true
        state.rebootRequested = true
    else
        state.status = "Update failed"
        state.lastError = tostring(resultOrError)
        state.modal = makeModal(
            "Update Failed",
            "The update could not be completed.\n" .. tostring(resultOrError),
            {
                { id = "modal_close", label = "Close" }
            },
            {
                selectedIndex = 1
            }
        )
        state.dirty = true
    end
end

local function activateModalButton(state, buttonId)
    if buttonId == "update_confirm" then
        performUpdate(state)
    elseif buttonId == "update_cancel" then
        state.modal = nil
        state.status = "Update skipped"
        state.lastError = nil
        state.dirty = true
    elseif buttonId == "modal_close" then
        state.modal = nil
        state.dirty = true
    end
end

local function handleModalClick(state, x, y)
    local hit = state.ui:hitTest(x, y)
    if not hit or hit.id ~= "modal_button" or not hit.meta then
        return
    end

    state.modal.selectedIndex = hit.meta.index or state.modal.selectedIndex
    state.dirty = true
    activateModalButton(state, hit.meta.id)
end

local function handleModalKey(state, key)
    if not state.modal or state.modal.busy or #state.modal.buttons == 0 then
        return
    end

    if key == keys.left or key == keys.up then
        state.modal.selectedIndex = state.modal.selectedIndex - 1
        if state.modal.selectedIndex < 1 then
            state.modal.selectedIndex = #state.modal.buttons
        end
        state.dirty = true
    elseif key == keys.right or key == keys.down or key == keys.tab then
        state.modal.selectedIndex = state.modal.selectedIndex + 1
        if state.modal.selectedIndex > #state.modal.buttons then
            state.modal.selectedIndex = 1
        end
        state.dirty = true
    elseif key == keys.enter or key == keys.space then
        local button = state.modal.buttons[state.modal.selectedIndex]
        if button then
            activateModalButton(state, button.id)
        end
    elseif key == keys.backspace then
        local fallback = state.modal.buttons[#state.modal.buttons]
        if fallback then
            activateModalButton(state, fallback.id)
        end
    end
end

local function currentTitle(state)
    if state.page == "playlists" then
        return "Playlist Selection"
    end

    local playlist = currentPlaylist(state)
    return playlist and ("(<-) " .. playlist.name) or "(<-) No Playlist"
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
    local footerHeight = 4
    local listHeight = math.max(1, height - listY - footerHeight + 1)
    local clock = state.clockText or util.safeFormatTime()
    local pageIsTracks = state.page == "tracks"
    local title = currentTitle(state)
    local headerColor = ui.theme.header or ui.theme.accent
    local titleBarColor = ui.theme.titleBar or ui.theme.surface
    local actionBarColor = state.lastError and colors.pink or (ui.theme.actionBar or ui.theme.accent)
    local progressRatio = state.playing and state.playbackProgress or 0

    ui:fill(1, 1, width, height, ui.theme.background)
    ui:fill(1, 1, width, 1, headerColor)
    ui:text(1, 1, util.truncate("KAMI-RADIO 2.0", math.max(1, width - #clock - 1)), ui.theme.text, headerColor)
    ui:text(math.max(1, width - #clock + 1), 1, clock, ui.theme.text, headerColor)
    drawSearchRow(state, pageIsTracks and "tracks" or "playlists")
    ui:fill(1, 3, width, 1, titleBarColor, ui.theme.text, " ")
    ui:text(1, 3, util.truncate(title, width), ui.theme.text, titleBarColor)
    ui:addHit("title_action", 1, 3, width, 3, {
        kind = "title_action"
    })

    if pageIsTracks then
        local trackItems, selectedTrackRow = buildTrackItems(state)
        if state.manualTrackScroll then
            local maxScroll = math.max(1, #trackItems - listHeight + 1)
            state.trackScroll = util.clamp(state.trackScroll or 1, 1, maxScroll)
        else
            state.trackScroll = ensureVisibleRow(state.trackScroll, selectedTrackRow, #trackItems, listHeight)
        end
        state.trackScroll = ui:list("tracks", 1, listY, width, listHeight, trackItems, selectedTrackRow, state.trackScroll, {
            plain = true,
            formatter = function(item, index)
                return formatTrackLabel(state, item.sourceItem, item.sourceIndex)
            end
        })
        if #trackItems == 0 then
            ui:centerText(1, listY + math.floor(math.max(0, listHeight - 1) / 2), width, "No matching songs", ui.theme.labelText or ui.theme.text, ui.theme.background)
        end
    else
        local playlistItems, selectedPlaylistRow = buildPlaylistItems(state)
        local visibleRows = math.max(1, listHeight)
        state.playlistScroll = ensureVisibleRow(state.playlistScroll, selectedPlaylistRow, #playlistItems, visibleRows)

        state.playlistScroll = ui:list("playlists", 1, listY, width, listHeight, playlistItems, selectedPlaylistRow, state.playlistScroll, {
            plain = true,
            formatter = function(item)
                return formatPlaylistLabel(item.sourceItem)
            end
        })
        if #playlistItems == 0 then
            ui:centerText(1, listY + math.floor(math.max(0, listHeight - 1) / 2), width, "No matching playlists", ui.theme.labelText or ui.theme.text, ui.theme.background)
        end
    end

    ui:progressBlocks(1, height - 3, width, progressRatio, {
        background = ui.theme.surfaceAlt,
        foreground = ui.theme.accent,
        filledGlyph = "=",
        emptyGlyph = "-"
    })

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
    ui:fill(1, height, width, 1, actionBarColor, ui.theme.text, " ")
    ui:text(1, height, util.truncate(currentActionText(state), width), ui.theme.text, actionBarColor)

    if state.modal then
        renderModal(state)
    end

    state.dirty = false
end

local function handleClick(state, x, y)
    if state.modal then
        handleModalClick(state, x, y)
        return
    end

    local hit = state.ui:hitTest(x, y)
    if not hit then
        return
    end

    if hit.id == "playlists" and hit.meta and hit.meta.kind == "scrollbar" and hit.meta.scroll then
        state.playlistScroll = hit.meta.scroll
        state.dirty = true
    elseif hit.id == "playlists" and hit.meta and hit.meta.index then
        state.browserPlaylistIndex = hit.meta.item.sourceIndex
        invalidateCache(state, "playlists")
        openPlaylist(state, hit.meta.item.sourceIndex)
    elseif hit.id == "tracks" and hit.meta and hit.meta.kind == "scrollbar" and hit.meta.scroll then
        state.trackScroll = hit.meta.scroll
        state.manualTrackScroll = true
        state.dirty = true
    elseif hit.id == "tracks" and hit.meta and hit.meta.index then
        state.selectedTrackIndex = hit.meta.item.sourceIndex
        state.manualTrackScroll = false
        invalidateCache(state, "tracks")
        playSelected(state)
    elseif hit.id == "search_box" and hit.meta and hit.meta.target then
        state.activeSearch = hit.meta.target
        state.status = hit.meta.target == "tracks" and "Searching songs" or "Searching playlists"
        state.dirty = true
    elseif hit.id == "title_action" then
        if state.page == "tracks" then
            state.page = "playlists"
            state.browserPlaylistIndex = state.playlistIndex
            invalidateCache(state, "playlists")
            state.activeSearch = nil
        else
            openPlaylist(state, state.browserPlaylistIndex or state.playlistIndex)
            state.activeSearch = nil
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

local function handleScroll(state, direction, x, y)
    if state.modal then
        return
    end

    local hit = state.ui:hitTest(x, y)
    if not hit then
        return
    end

    local step = direction > 0 and 1 or -1
    if hit.id == "playlists" then
        moveFilteredSelection(state, "playlists", step)
    elseif hit.id == "tracks" then
        moveFilteredSelection(state, "tracks", step)
    end
end

local function handleSearchKey(state, key)
    local target = currentSearchTarget(state)
    local query = target == "tracks" and state.trackSearch or state.playlistSearch

    if key == keys.backspace then
        setSearchQuery(state, target, util.dropLastCharacter(query))
        return true
    elseif key == keys.enter or key == keys.tab then
        state.activeSearch = nil
        state.dirty = true
        return true
    elseif key == keys.up then
        moveFilteredSelection(state, target, -1)
        return true
    elseif key == keys.down then
        moveFilteredSelection(state, target, 1)
        return true
    end

    return false
end

local function handleChar(state, value)
    if not isSearchActive(state) then
        return
    end

    local target = currentSearchTarget(state)
    local query = target == "tracks" and state.trackSearch or state.playlistSearch
    setSearchQuery(state, target, query .. value)
end

local function handlePaste(state, value)
    if not isSearchActive(state) then
        return
    end

    local target = currentSearchTarget(state)
    local query = target == "tracks" and state.trackSearch or state.playlistSearch
    setSearchQuery(state, target, query .. tostring(value or ""))
end

local function handleKey(state, key)
    if state.modal then
        handleModalKey(state, key)
        return
    end

    if isSearchActive(state) and handleSearchKey(state, key) then
        return
    end

    local playlist = currentPlaylist(state)
    if state.page == "playlists" then
        if key == keys.up then
            moveFilteredSelection(state, "playlists", -1)
        elseif key == keys.down then
            moveFilteredSelection(state, "playlists", 1)
        elseif key == keys.enter then
            openPlaylist(state, state.browserPlaylistIndex)
        elseif key == keys.left or key == keys.right then
            state.page = "tracks"
            state.activeSearch = nil
            state.dirty = true
        elseif key == keys.slash then
            state.activeSearch = "playlists"
            state.dirty = true
        end
        return
    end

    if key == keys.up then
        moveFilteredSelection(state, "tracks", -1)
    elseif key == keys.down then
        moveFilteredSelection(state, "tracks", 1)
    elseif key == keys.enter then
        playSelected(state)
    elseif key == keys.backspace then
        state.page = "playlists"
        state.browserPlaylistIndex = state.playlistIndex
        invalidateCache(state, "playlists")
        state.activeSearch = nil
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
    elseif key == keys.slash then
        state.activeSearch = "tracks"
        state.dirty = true
    end
end

local function playerLoop(state)
    while not state.exitRequested do
        local playlist = currentPlaylist(state)
        local track = currentTrack(state)
        if playlist and track and state.playing then
            local token = state.playbackToken
            state.status = "Buffering " .. track.name
            state.lastError = nil
            setPlaybackProgress(state, 0)
            state.dirty = true

            local ok, dataOrError = catalog.fetchTrackData(playlist, track)
            if token ~= state.playbackToken or not state.playing then
            elseif not ok then
                setPlaybackProgress(state, 0)
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
                end, function(ratio)
                    setPlaybackProgress(state, ratio)
                end)

                if token ~= state.playbackToken then
                elseif completed then
                    setPlaybackProgress(state, 1)
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
    while not state.exitRequested do
        refreshClock(state)
        flushPersistIfDue(state, false)
        if state.dirty then
            render(state)
        end
        sleep(0.05)
    end
end

local function inputLoop(state)
    while not state.exitRequested do
        local event, a, b, c = os.pullEvent()
        if event == "mouse_click" then
            handleClick(state, b, c)
        elseif event == "mouse_scroll" then
            handleScroll(state, a, b, c)
        elseif event == "monitor_touch" then
            handleClick(state, b, c)
        elseif event == "key" then
            handleKey(state, a)
        elseif event == "char" then
            handleChar(state, a)
        elseif event == "paste" then
            handlePaste(state, a)
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

    local updateInfo, updateErr = updater.checkForUpdate()

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
    state.status = buildReadyStatus(warnings, updateErr)

    if updateInfo and updateInfo.updateAvailable then
        showUpdatePrompt(state, updateInfo)
    end

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

    flushPersistIfDue(state, true)

    if state.rebootRequested and os.reboot then
        os.reboot()
    end
end

return M