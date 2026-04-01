---@diagnostic disable: undefined-global, undefined-field
local dfpwm = require("cc.audio.dfpwm")

local M = {}

function M.findSpeakers()
    local speakers = { peripheral.find("speaker") }
    if not next(speakers) then
        error("No speaker attached. Add at least one speaker peripheral.")
    end
    return speakers
end

function M.playData(data, speakers, getVolume, shouldStop)
    local decoder = dfpwm.make_decoder()

    for offset = 1, #data, 16 * 1024 do
        if shouldStop() then
            return false
        end

        local chunk = data:sub(offset, math.min(offset + 16 * 1024 - 1, #data))
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

            local _, side = os.pullEvent("speaker_audio_empty")
            local speaker = pending[side]
            if speaker and speaker.playAudio(buffer, getVolume()) then
                pending[side] = nil
            end
        end
    end

    return true
end

return M