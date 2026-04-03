---@diagnostic disable: undefined-global, undefined-field
local dfpwm = require("cc.audio.dfpwm")

local M = {}

local AUDIO_CHUNK_SIZE = 8 * 1024
local STOP_POLL_INTERVAL = 0.05

function M.findSpeakers()
    local speakers = { peripheral.find("speaker") }
    if not next(speakers) then
        error("No speaker attached. Add at least one speaker peripheral.")
    end
    return speakers
end

function M.playData(data, speakers, getVolume, shouldStop, onProgress)
    local decoder = dfpwm.make_decoder()
    local total = math.max(1, #data)

    if onProgress then
        onProgress(0, 0, total)
    end

    for offset = 1, #data, AUDIO_CHUNK_SIZE do
        if shouldStop() then
            return false
        end

        local chunk = data:sub(offset, math.min(offset + AUDIO_CHUNK_SIZE - 1, #data))
        local buffer = decoder(chunk)
        local pending = {}

        for _, speaker in ipairs(speakers) do
            if shouldStop() then
                return false
            end

            local volume = getVolume()
            if not speaker.playAudio(buffer, volume) then
                pending[peripheral.getName(speaker)] = speaker
            end
        end

        while next(pending) do
            if shouldStop() then
                return false
            end

            local timer = os.startTimer(STOP_POLL_INTERVAL)
            local event, side = os.pullEvent()
            if event == "speaker_audio_empty" then
                local speaker = pending[side]
                if speaker and speaker.playAudio(buffer, getVolume()) then
                    pending[side] = nil
                end
            elseif event == "timer" and side == timer then
                if shouldStop() then
                    return false
                end
            end
        end

        if onProgress then
            local played = math.min(offset + #chunk - 1, total)
            onProgress(played / total, played, total)
        end
    end

    if onProgress then
        onProgress(1, total, total)
    end

    return true
end

return M