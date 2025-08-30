-- client.lua
-- Listens for rednet broadcasts from the music server and plays songs locally
local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()
local speakers = { peripheral.find("speaker") }
if not next(speakers) then error("No speaker attached to client") end

local modem = peripheral.find("ender_modem") or peripheral.find("modem")
if not modem then error("No modem or ender_modem attached - required for client") end

rednet.open(peripheral.getName(modem))
print("cc-atm10-music client listening on rednet...")

while true do
    local id, msg, dist = rednet.receive("cc-atm10-music")
    if type(msg) == "table" then
        if msg.cmd == "stop" then
            -- no-op for now
        elseif msg.cmd == "play" and msg.repo and msg.name then
            local url = "https://raw.githubusercontent.com/"..msg.repo.."/main/"..msg.name:gsub(" ","%%20")..".dfpwm"
            local r = http.get(url)
            if not r then print("Failed to fetch "..url) else
                local data = r.readAll()
                r.close()
                local dataLen = #data
                for i = 1, dataLen, 16*1024 do
                    local chunk = data:sub(i, math.min(i+16*1024-1, dataLen))
                    local buffer = decoder(chunk)
                    for _, spk in pairs(speakers) do
                        spk.playAudio(buffer, 0.35)
                    end
                    os.pullEvent("speaker_audio_empty")
                end
            end
        end
    end
end
