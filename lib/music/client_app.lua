---@diagnostic disable: undefined-global, undefined-field
local audio = require("music.audio")
local catalog = require("music.catalog")
local network = require("music.network")
local UI = require("music.ui")
local util = require("music.util")

local M = {}

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

local function render(state)
    local ui = state.ui
    ui:refreshSize()
    ui:resetHits()

    local width, height = ui.width, ui.height
    ui:fill(1, 1, width, height, colors.black)
    ui:fill(1, 1, width, 3, colors.blue)
    ui:text(2, 1, "CC ATM10 MUSIC CLIENT", colors.white, colors.blue)
    ui:text(2, 2, util.truncate(state.status, width - 4), colors.white, colors.blue)

    ui:panel(2, 5, width - 2, math.max(8, height - 9), "Remote Speaker Node", colors.cyan)
    ui:text(4, 8, util.truncate("Track: " .. (state.track and state.track.name or "(idle)"), width - 8), colors.white, ui.theme.surface)
    ui:text(4, 10, util.truncate("Playlist: " .. (state.track and state.track.playlist or "(none)"), width - 8), colors.lightGray, ui.theme.surface)
    ui:text(4, 12, util.truncate("Repo: " .. (state.track and state.track.repo or "(none)"), width - 8), colors.lightGray, ui.theme.surface)
    ui:text(4, 14, util.truncate("Mode: " .. (state.playing and "Playing" or "Listening"), width - 8), colors.white, ui.theme.surface)
    ui:text(4, 16, util.truncate("Speakers: " .. #state.speakers .. "  |  Volume: " .. math.floor(state.volume * 100) .. "%", width - 8), colors.white, ui.theme.surface)
    ui:text(4, 18, util.truncate(state.lastError or "Waiting for play/stop commands from the server.", width - 8), state.lastError and colors.red or colors.white, ui.theme.surface)
    ui:text(4, 20, util.truncate("Rednet: " .. (state.remote.available and ("open on " .. state.remote.side) or "unavailable"), width - 8), colors.lightGray, ui.theme.surface)

    ui:progress(4, height - 3, math.max(10, width - 8), state.volume, colors.green, colors.gray)
    state.lastClock = util.safeFormatTime()
    state.dirty = false
end

local function playerLoop(state)
    while true do
        if state.pendingTrack and state.playing then
            local token = state.playbackToken
            local track = state.pendingTrack
            state.track = track
            state.pendingTrack = nil
            state.status = "Buffering " .. track.name
            state.lastError = nil
            state.dirty = true

            local ok, dataOrError = catalog.fetchTrackData({
                repo = track.repo,
                branch = track.branch
            }, {
                name = track.name,
                file = track.file
            })

            if token ~= state.playbackToken or not state.playing then
            elseif not ok then
                state.status = "Failed to load track"
                state.lastError = tostring(dataOrError)
                state.playing = false
                state.dirty = true
            else
                state.status = "Playing " .. track.name
                state.dirty = true

                local completed = audio.playData(dataOrError, state.speakers, function()
                    return state.volume
                end, function()
                    return token ~= state.playbackToken or not state.playing
                end)

                if token ~= state.playbackToken then
                elseif completed then
                    state.status = "Track finished"
                    state.playing = false
                    state.dirty = true
                else
                    state.status = state.playing and "Switching track" or "Stopped"
                    state.dirty = true
                end
            end
        else
            sleep(0.05)
        end
    end
end

local function networkLoop(state)
    while true do
        local _, message = state.remote:receive(0.5)
        if type(message) == "table" and message.cmd then
            if message.cmd == "play" and message.repo and message.name and message.file then
                state.playbackToken = state.playbackToken + 1
                state.pendingTrack = {
                    playlist = message.playlist or "(remote)",
                    repo = message.repo,
                    branch = message.branch or "main",
                    name = message.name,
                    file = message.file
                }
                state.playing = true
                state.status = "Queued " .. message.name
                state.lastError = nil
                state.dirty = true
            elseif message.cmd == "stop" then
                state.playbackToken = state.playbackToken + 1
                state.playing = false
                state.pendingTrack = nil
                state.status = "Stopped"
                state.dirty = true
            elseif message.cmd == "setVolume" and type(message.volume) == "number" then
                state.volume = util.clamp(message.volume, 0, 1)
                state.status = string.format("Volume %.0f%%", state.volume * 100)
                state.dirty = true
            end
        end
    end
end

local function renderLoop(state)
    while true do
        local clock = util.safeFormatTime()
        if state.dirty or clock ~= state.lastClock then
            render(state)
        end
        sleep(0.1)
    end
end

function M.run()
    if not http then
        error("HTTP API is required for remote playback clients.")
    end

    local remote = network.open("cc-atm10-music")
    if not remote.available then
        error("No modem or ender modem attached. Client mode requires rednet.")
    end

    local display, hasMonitor = findDisplay()
    local state = {
        status = "Listening for server commands",
        lastError = nil,
        volume = 0.35,
        playing = false,
        playbackToken = 0,
        pendingTrack = nil,
        track = nil,
        speakers = audio.findSpeakers(),
        remote = remote,
        ui = UI.new(display),
        hasMonitor = hasMonitor,
        dirty = true,
        lastClock = nil
    }

    parallel.waitForAny(
        function()
            networkLoop(state)
        end,
        function()
            playerLoop(state)
        end,
        function()
            renderLoop(state)
        end
    )
end

return M