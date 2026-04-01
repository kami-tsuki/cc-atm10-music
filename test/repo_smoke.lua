---@diagnostic disable: undefined-global, undefined-field
local originalHttp = http
local originalPeripheral = peripheral
local originalParallel = parallel

local filesToInstall = {
    "startup.lua",
    "README.md",
    "config.json",
    "lib/music/bootstrap.lua",
    "lib/music/util.lua",
    "lib/music/config.lua",
    "lib/music/catalog.lua",
    "lib/music/audio.lua",
    "lib/music/ui.lua",
    "lib/music/app.lua"
}

local obsoleteFiles = {
    "server.lua",
    "client.lua",
    "lib/music/network.lua",
    "lib/music/server_app.lua",
    "lib/music/client_app.lua"
}

local smokeProbePath = "lib/music/smoke_probe.lua"

local fakeSpeaker = {
    playAudio = function()
        return true
    end
}

local requestedUrls = {}

local function response(body)
    return {
        readAll = function()
            return body
        end,
        close = function()
        end
    }
end

local function readRepoFile(path)
    local handle = fs.open(path, "rb") or fs.open(path, "r")
    if not handle then
        return nil
    end

    local body = handle.readAll()
    handle.close()
    return body
end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir == "" then
        return
    end

    local cursor = ""
    for part in string.gmatch(dir, "[^/]+") do
        cursor = cursor == "" and part or fs.combine(cursor, part)
        if not fs.exists(cursor) then
            fs.makeDir(cursor)
        end
    end
end

local function writeFile(path, body)
    ensureDir(path)
    local handle = fs.open(path, "wb") or fs.open(path, "w")
    if not handle then
        error("Failed to write file: " .. path, 0)
    end

    handle.write(body)
    handle.close()
end

local function installFromRepo()
    for _, path in ipairs(obsoleteFiles) do
        if fs.exists(path) then
            fs.delete(path)
        end
    end

    for _, path in ipairs(filesToInstall) do
        local body = readRepoFile(fs.combine("/repo", path))
        if not body then
            error("Missing repo file during smoke install: " .. path, 0)
        end
        writeFile(path, body)
    end
end

local function fakeHttpGet(url)
    if type(url) ~= "string" then
        return nil
    end

    requestedUrls[#requestedUrls + 1] = url

    local repoPath = url:match("^https://raw%.githubusercontent%.com/kami%-tsuki/cc%-atm10%-music/main/(.+)$")
    if repoPath then
        local body = readRepoFile(fs.combine("/repo", repoPath))
        if body then
            return response(body)
        end
        return nil
    end

    if url:match("^https://raw%.githubusercontent%.com/test/smoke/main/index%.json$")
        or url:match("^https://raw%.githubusercontent%.com/test/smoke/main/index%.txt$") then
        return response("Smoke Track\n")
    end

    if url:match("^https://raw%.githubusercontent%.com/test/smoke/main/.+%.dfpwm$") then
        return response(string.rep("\0", 64))
    end

    return nil
end

http = { get = fakeHttpGet }
_G.http = http

peripheral = {
    find = function(kind)
        if kind == "speaker" then
            return fakeSpeaker
        end

        return nil
    end,
    getName = function(_)
        return "speaker_0"
    end
}
_G.peripheral = peripheral

parallel = {
    waitForAny = function(...)
        return 1
    end
}
_G.parallel = parallel

local function assertExists(path)
    if not fs.exists(path) then
        error("Expected file to exist after install: " .. path, 0)
    end
end

local function readFile(path)
    local handle = fs.open(path, "r")
    if not handle then
        error("Failed to open file: " .. path, 0)
    end

    local body = handle.readAll()
    handle.close()
    return body
end

local function runProgram(path)
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load program '" .. path .. "': " .. tostring(err), 0)
    end

    return chunk
end

local function writeSmokeProbe()
    writeFile(smokeProbePath, [[
return function()
    local audio = require("music.audio")
    local catalog = require("music.catalog")
    local config = require("music.config")

    local entries = config.load("config.json")
    local playlists, warnings = catalog.loadPlaylists(entries)
    if #playlists == 0 then
        error("No smoke playlists loaded: " .. table.concat(warnings, "; "), 0)
    end

    local speakers = audio.findSpeakers()
    if #speakers == 0 then
        error("No speakers detected during smoke probe", 0)
    end

    return {
        playlists = #playlists,
        tracks = #playlists[1].songs,
        warnings = #warnings
    }
end
]])
end

local ok, err = pcall(function()
    installFromRepo()

    assertExists("startup.lua")
    assertExists("config.json")
    assertExists("lib/music/bootstrap.lua")
    assertExists("lib/music/app.lua")

    local bootstrapBody = readFile("lib/music/bootstrap.lua")
    if not bootstrapBody:find("ROM_MODULE_ROOTS", 1, true) then
        error("Installed bootstrap.lua does not match the expected repo version", 0)
    end

    runProgram("startup.lua")

    local configHandle = fs.open("config.json", "w")
    configHandle.write('[{"name":"Smoke","repo":"test/smoke","branch":"main","index":"index.txt"}]')
    configHandle.close()

    writeSmokeProbe()

    local bootstrap = assert(loadfile("lib/music/bootstrap.lua"))()
    local result = bootstrap.run("music.smoke_probe")
    if type(result) ~= "table" or result.playlists < 1 or result.tracks < 1 then
        error("Smoke probe returned invalid result", 0)
    end

    if fs.exists(smokeProbePath) then
        fs.delete(smokeProbePath)
    end
end)

http = originalHttp
peripheral = originalPeripheral
parallel = originalParallel
_G.http = http
_G.peripheral = peripheral
_G.parallel = parallel

if not ok then
    error("CraftOS-PC repo smoke test failed: " .. tostring(err) .. " | URLs: " .. table.concat(requestedUrls, ", "), 0)
end

print("CraftOS-PC repo smoke test passed")
os.shutdown()