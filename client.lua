-- dont add "return" (idk why this is so, but keep it)
function(require)
    -- Rednet client for cc-atm10-music: receives control messages and plays audio locally
    local dfpwm = require("cc.audio.dfpwm")
    local decoder = dfpwm.make_decoder()
    local speakers = { peripheral.find("speaker") }
    if not next(speakers) then error("No speaker attached to client") end

    local modem = peripheral.find("ender_modem") or peripheral.find("modem")
    if not modem then error("No modem or ender_modem attached - required for client") end

    rednet.open(peripheral.getName(modem))
    print("cc-atm10-music client listening on rednet...")

    local playing = false
    local stopFlag = false
    local volume = 0.35

    local function playUrl(url)
        local r = http.get(url)
        if not r then print("Failed to fetch "..url) return end
        local data = r.readAll(); r.close()
        local dataLen = #data
        for i = 1, dataLen, 16*1024 do
            if stopFlag then break end
            local chunk = data:sub(i, math.min(i+16*1024-1, dataLen))
            local buffer = decoder(chunk)
            for _, spk in pairs(speakers) do spk.playAudio(buffer, volume) end
            -- wait for at least one speaker to need refill (blocks until event)
            os.pullEvent("speaker_audio_empty")
        end
    end

    local function handleMessage(msg)
        if type(msg) ~= "table" or not msg.cmd then return end
        if msg.cmd == "stop" then
            stopFlag = true
            playing = false
        elseif msg.cmd == "play" and msg.repo and msg.name then
            stopFlag = false
            playing = true
            local url = "https://raw.githubusercontent.com/"..msg.repo.."/main/"..msg.name:gsub(" ","%%20")..".dfpwm"
            playUrl(url)
        elseif msg.cmd == "setVolume" and type(msg.volume)=="number" then
            volume = math.max(0, math.min(1, msg.volume))
        elseif msg.cmd == "pause" then
            playing = false
            stopFlag = true
        end
    end

    while true do
        local id, msg = rednet.receive("cc-atm10-music")
        handleMessage(msg)
    end
end