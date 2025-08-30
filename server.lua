
-- dont add "return" (idk why this is so, but keep it)
function(require)
    -- CC: Tweaked DFPWM Playlist with Stop, Loop, Shuffle, and Adaptive Buttons (Clickable aligned)
    
    local dfpwm = require("cc.audio.dfpwm")
    local speakers = { peripheral.find("speaker") }
    if not peripheral.find("speaker") then error("No speaker(s) attached. If this is a pocket computer, combine it in the crafting grid.") end

    -- Ender modem / rednet support (optional)
    local modem = peripheral.find("ender_modem") or peripheral.find("modem")
    local rednetEnabled = false
    local modemName = nil
    if modem and rednet then
        modemName = peripheral.getName(modem)
        local ok = pcall(rednet.open, modemName)
        if ok then rednetEnabled = true end
    end
    local function sendCmd(tbl)
        if rednetEnabled and rednet then
            pcall(function() rednet.broadcast(tbl, "cc-atm10-music") end)
        end
    end
    
    -- Terminal setup
    local mon = peripheral.find("monitor")
    if mon then
        term.redirect(mon)
        if mon.setTextScale then mon.setTextScale(1) end
        mon.clear()
    end
    
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    
    -- ===== Playlists setup (from config.json) =====
    -- Expect a JSON file named `config.json` in the same directory with structure:
    -- [ { "name": "display name", "repo": "user/repo" }, ... ]
    local configFile = "config.json"
    local playlists = {}

    if not fs.exists(configFile) then
        error("Config file '"..configFile.."' not found. Create it with format: [{ \"name\": \"a\", \"repo\": \"user/repo\" }]")
    end

    local fh = fs.open(configFile, "r")
    local cfgContents = fh.readAll()
    fh.close()

    local ok, cfg = pcall(textutils.unserializeJSON, cfgContents)
    if not ok or type(cfg) ~= "table" then
        error("Invalid JSON in '"..configFile.."'")
    end

    -- For each repo entry in the config, fetch its index.txt and build a playlist.
    for _, entry in ipairs(cfg) do
        if type(entry) == "table" and entry.repo then
            local repo = entry.repo
            local displayPrefix = entry.name or repo
            local indexUrl = "https://raw.githubusercontent.com/" .. repo .. "/main/index.txt"
            local resp = http.get(indexUrl)
            if resp then
                local body = resp.readAll()
                resp.close()
                local songNames = textutils.unserialize(body)
                if type(songNames) == "table" then
                    local plist = { name = displayPrefix, repo = repo, songs = {} }
                    for i, name in ipairs(songNames) do
                        local songName = name
                        table.insert(plist.songs, {
                            name = songName,
                            fn = (function(r, n)
                                return function()
                                    local url = "https://raw.githubusercontent.com/" .. r .. "/main/" .. n:gsub(" ", "%%20") .. ".dfpwm"
                                    local rresp = http.get(url)
                                    if not rresp then error("Failed to fetch "..url) end
                                    local data = rresp.readAll()
                                    rresp.close()
                                    return data
                                end
                            end)(repo, name)
                        })
                    end
                    table.insert(playlists, plist)
                end
            else
                print("Warning: failed to fetch index for repo: "..repo)
            end
        end
    end

    if #playlists == 0 then
        error("No playlists found in configured repos (check config.json and index.txt files)")
    end
    
    -- ===== Playback state =====
    local savedName = settings.get("currentSong", nil)
    local currentSong = nil
    
    local playing = settings.get("playing", false)
    local stopFlag = false
    local shuffle = settings.get("shuffle", true)
    local loopMode = settings.get("loopMode", 0) -- 0=Off,1=All,2=One
    local volume = .35
    local decoder = dfpwm.make_decoder()
    local currentPage = settings.get("currentPage", 1)
    -- saved playlist name (string) if previously stored
    local savedPlaylistName = settings.get("playlist", nil)
    local width, height = term.getSize()
    local topRows = 2
    local bottomRows = 6 -- reserve bottom 6 lines (extra row for playlist controls)
    local songsPerPage = height - topRows - bottomRows

    -- Ensure a settings file exists and stored values are non-nil.
    -- This writes safe defaults so `settings.save()` creates the file on disk.
    do
        local _cs_init = (currentSong and currentSong.name) or ""
        settings.set("currentSong", _cs_init)
        settings.set("playing", playing)
        settings.set("shuffle", shuffle)
        settings.set("loopMode", loopMode)
        settings.set("currentPage", currentPage)
        settings.save()
    end
    
    -- Button storage for click detection
    local buttons = {}

    -- Build songs variable from selected playlist (playlist index chosen later)
    local songs = {}

    -- Playlist selection: accept either a numeric saved index or a saved playlist name.
    local selectedPlaylistIndex = nil
    if type(savedPlaylistName) == "number" and playlists[savedPlaylistName] then
        selectedPlaylistIndex = savedPlaylistName
    elseif type(savedPlaylistName) == "string" then
        for i,p in ipairs(playlists) do if p.name == savedPlaylistName then selectedPlaylistIndex = i break end end
    end

    if not selectedPlaylistIndex then
        -- default to first playlist if no saved/valid selection
        selectedPlaylistIndex = 1
    end

    local playlist = playlists[selectedPlaylistIndex]
    songs = playlist.songs
    -- persist playlist by name (safer if config order changes)
    settings.set("playlist", playlist.name)
    settings.save()

    -- Restore currentSong from savedName now that `songs` exists
    if savedName ~= nil then
        for _, song in ipairs(songs) do
            if song.name == savedName then
                currentSong = song
                break
            end
        end
    end
    
    -- ===== UI functions =====
    local function totalPages()
        return math.max(1, math.ceil(#songs / songsPerPage))
    end
    
    local function drawUI()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
    
        -- Now Playing
        term.setCursorPos(2,1)
        term.write("Now Playing: " .. (currentSong and currentSong.name or "(none)"))
    
        -- Song list (paged)
        local startIdx = (currentPage-1)*songsPerPage + 1
        local y = 3
        for i=startIdx, math.min(startIdx+songsPerPage-1, #songs) do
            term.setCursorPos(2,y)
            term.setTextColor((currentSong==songs[i]) and colors.yellow or colors.white)
            term.write(songs[i].name)
            y = y + 1
        end
    
        -- Reserve a blank line
        y = y + 1
    
        -- Bottom controls (5 lines): playlist row + controls
        buttons = {} -- reset button list
        local btnLines = {
            {"Radio: "..(playlist and playlist.name or "(none)"), "PrevPl","NextPl"},
            {"Shuffle: "..(shuffle and "On" or "Off"), "Loop: "..({[0]="Off",[1]="All",[2]="One"})[loopMode]},
            {"Page "..currentPage.."/"..totalPages(), "Prev","Next"},
            {(playing and "Playing" or "Stopped"), "Skip"},
            {"-","Volume: "..math.floor(volume*100).."%","+",""}
        }
    
        local startY = height - bottomRows + 1
        for lineIdx, line in ipairs(btnLines) do
            local x = 2
            local y = startY + lineIdx - 1
            for i, btn in ipairs(line) do
                if #btn>0 then
                    local btnStartX = x
                    term.setCursorPos(btnStartX,y)
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.white)
                    term.write(" "..btn.." ")
                    local btnEndX = btnStartX + #btn + 1
                    -- Store button for click detection
                    table.insert(buttons,{
                        line=lineIdx, text=btn, x1=btnStartX, x2=btnEndX
                    })
                    x = btnEndX + 2
                end
            end
        end
    end
    
    -- ===== Playback loop =====
    local function playerLoop()
        while true do
            if currentSong and playing then
                local songData = currentSong.fn()
                local dataLen = #songData
                for i = 1, dataLen, 16*1024 do
                    if stopFlag then break end
                    local chunk = songData:sub(i, math.min(i+16*1024-1, dataLen))
                    local buffer = decoder(chunk)
                    local pending = {}
                    
                    for _, spk in pairs(speakers) do
                      if stopFlag then break end
                      if not spk.playAudio(buffer, volume) then
                        pending[peripheral.getName(spk)] = spk
                      end
                    end
                    
                    while not stopFlag and next(pending) do
                      local _, name = os.pullEvent("speaker_audio_empty")
                      local spk = pending[name]
                      if spk and spk.playAudio(buffer, volume) then
                        pending[name] = nil
                      end
                    end
                end
    
                if stopFlag then
                    stopFlag = false
                    -- notify clients to stop
                        sendCmd({ cmd = "stop" })
                else
                    -- Auto-advance
                    if loopMode == 2 then
                        -- loop current song
                    elseif shuffle then
                        currentSong = songs[math.random(#songs)]
                    elseif loopMode == 1 then
                        local idx = 1
                        for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                        currentSong = songs[idx % #songs + 1]
                    else
                        local idx = 1
                        for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                        if idx<#songs then
                            currentSong = songs[idx+1]
                        else
                            currentSong = nil
                            playing = false
                        end
                    end
                    local _cs = (currentSong and currentSong.name) or ""
                    settings.set("currentSong", _cs)
                    settings.set("playing", playing)
                    settings.save()
                    -- notify clients about new song
                        if currentSong and playlist and playlist.repo then
                            sendCmd({ cmd = "play", repo = playlist.repo, name = currentSong.name })
                        end
                end
                drawUI()
            else
                os.sleep(0.05)
            end
        end
    end
    
    -- ===== Input loop =====
    local function inputLoop()
        drawUI()
        while true do
            local e, button, x, y = os.pullEvent()
            if e=="mouse_click" then
                -- Song list tap
                local startIdx = (currentPage-1)*songsPerPage + 1
                for i=startIdx, math.min(startIdx+songsPerPage-1, #songs) do
                    local row = 3 + (i-startIdx)
                    if y==row then
                        currentSong = songs[i]
                        stopFlag = true
                        playing = true
                        drawUI()
                    end
                end
    
                -- Bottom controls click detection
                for _, btn in ipairs(buttons) do
                    local btnY = (height - bottomRows + btn.line)
                    if y == btnY and x >= btn.x1 and x <= btn.x2 then
                        -- Identify which button was clicked
                        if btn.text:find("Shuffle") then shuffle = not shuffle
                        elseif btn.text:find("Loop") then loopMode = (loopMode+1)%3
                        elseif btn.text=="PrevPl" then
                            -- previous playlist
                            for i,p in ipairs(playlists) do if p==playlist then
                                local ni = (i-2) % #playlists + 1
                                playlist = playlists[ni]
                                songs = playlist.songs
                                    -- reset to first page of the new playlist
                                    currentPage = 1
                                    settings.set("playlist", playlist.name)
                                    settings.set("currentPage", currentPage)
                                    settings.save()
                                    -- notify clients of stop (playlist change)
                                    sendCmd({ cmd = "stop" })
                                break
                            end end
                        elseif btn.text=="NextPl" then
                            -- next playlist
                            for i,p in ipairs(playlists) do if p==playlist then
                                local ni = (i % #playlists) + 1
                                playlist = playlists[ni]
                                songs = playlist.songs
                                    -- reset to first page of the new playlist
                                    currentPage = 1
                                    settings.set("playlist", playlist.name)
                                    settings.set("currentPage", currentPage)
                                    settings.save()
                                    sendCmd({ cmd = "stop" })
                                break
                            end end
                        elseif btn.text:find("Prev") and currentPage>1 then currentPage=currentPage-1
                        elseif btn.text:find("Next") and currentPage<totalPages() then currentPage=currentPage+1
                        elseif btn.text:find("Stopped") or btn.text:find("Playing") then
                            if playing then
                                -- Pause
                                stopFlag = true
                                playing = false
                                    sendCmd({ cmd = "stop" })
                            else
                                -- Resume/start
                                if currentSong then
                                    playing = true
                                        sendCmd({ cmd = "play", repo = playlist.repo, name = currentSong.name })
                                end
                            end
                        elseif btn.text:find("Skip") then
                            if currentSong then
                                local idx = 1
                                for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                                if shuffle then
                                    currentSong = songs[math.random(#songs)]
                                else
                                    if idx < #songs then
                                        currentSong = songs[idx+1]
                                    else
                                        currentSong = songs[1]
                                    end
                                end
                                stopFlag = true
                                playing = true
                                    -- notify clients about new song
                                    sendCmd({ cmd = "play", repo = playlist.repo, name = currentSong.name })
                                end
                        elseif btn.text=="-" then volume = math.max(0,volume-0.05)
                        elseif btn.text=="+" then volume = math.min(1,volume+0.05)
                                -- propagate volume change to clients
                                sendCmd({ cmd = "setVolume", volume = volume })
                        end
                        drawUI()
                    end
                end

                settings.set("currentPage", currentPage)
                settings.set("loopMode", loopMode)
                settings.set("shuffle", shuffle)
                local _cs2 = (currentSong and currentSong.name) or ""
                settings.set("currentSong", _cs2)
                settings.set("playing", playing)
                settings.save()
            end
        end
    end
    
    parallel.waitForAny(playerLoop, inputLoop)
end
