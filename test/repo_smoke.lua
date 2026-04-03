---@diagnostic disable: undefined-global, undefined-field
local originalHttp = http
local originalOsReboot = os.reboot
local originalPeripheral = peripheral
local originalParallel = parallel

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

local function collectRepoFiles(root, basePath, output)
    output = output or {}
    basePath = basePath or ""

    for _, name in ipairs(fs.list(root)) do
        local fullPath = fs.combine(root, name)
        local relativePath = basePath == "" and name or fs.combine(basePath, name)
        if fs.isDir(fullPath) then
            collectRepoFiles(fullPath, relativePath, output)
        else
            output[#output + 1] = relativePath:gsub("\\", "/")
        end
    end

    return output
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

local function fakeHttpGet(url)
    if type(url) ~= "string" then
        return nil
    end

    requestedUrls[#requestedUrls + 1] = url

    local repoPath = url:match("^https://raw%.githubusercontent%.com/kami%-tsuki/cc%-atm10%-music/main/(.+)$")
    if repoPath then
        if _G.__smokeFailPath == repoPath then
            return nil
        end

        if _G.__smokeBodyOverrides and _G.__smokeBodyOverrides[repoPath] then
            return response(_G.__smokeBodyOverrides[repoPath])
        end

        local body = readRepoFile(fs.combine("/repo", repoPath))
        if body then
            return response(body)
        end
        return nil
    end

    if url:match("^https://api%.github%.com/repos/kami%-tsuki/cc%-atm10%-music/git/trees/main%?recursive=1$") then
        local tree = {}
        for _, path in ipairs(collectRepoFiles("/repo")) do
            tree[#tree + 1] = {
                path = path,
                type = "blob"
            }
        end
        return response(textutils.serializeJSON({ tree = tree }))
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

os.reboot = function()
    _G.__smokeRebooted = true
end

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

    return chunk()
end

local function writeSmokeProbe()
    writeFile(smokeProbePath, [[
return function()
    local audio = require("music.audio")
    local catalog = require("music.catalog")
    local config = require("music.config")
    local updater = require("music.updater")
    local util = require("music.util")

    local function bumpPatchVersion(version)
        local parts = {}
        for token in tostring(version or "0.0.0"):gmatch("(%d+)") do
            parts[#parts + 1] = tonumber(token)
        end

        while #parts < 3 do
            parts[#parts + 1] = 0
        end

        parts[3] = parts[3] + 1
        return string.format("%d.%d.%d", parts[1], parts[2], parts[3])
    end

    local function replaceVersion(body, nextVersion)
        local replaced, count = body:gsub('"version"%s*:%s*"[^"]+"', '"version": "' .. nextVersion .. '"', 1)
        if count ~= 1 then
            error("Unable to rewrite manifest version for smoke test", 0)
        end
        return replaced
    end

    local entries = config.load("config.json")
    local playlists, warnings = catalog.loadPlaylists(entries)
    if #playlists == 0 then
        error("No smoke playlists loaded: " .. table.concat(warnings, "; "), 0)
    end

    local speakers = audio.findSpeakers()
    if #speakers == 0 then
        error("No speakers detected during smoke probe", 0)
    end

    local updateInfo, updateErr = updater.checkForUpdate()
    if not updateInfo then
        error("Update check failed after install: " .. tostring(updateErr), 0)
    end
    if updateInfo.updateAvailable then
        error("Installer left a pending update after install", 0)
    end

    local repoManifest = util.readFile("/repo/manifest.json")
    local baseVersion = assert(updater.loadManifest("manifest.json")).version
    local nextVersion = bumpPatchVersion(baseVersion)
    local failingVersion = bumpPatchVersion(nextVersion)
    local originalReadme = util.readFile("README.md")
    _G.__smokeBodyOverrides = {
        ["manifest.json"] = replaceVersion(repoManifest, nextVersion),
        ["README.md"] = originalReadme .. "\n\nSmoke update marker.\n"
    }

    local newerInfo, newerErr = updater.checkForUpdate()
    if not newerInfo then
        error("Failed to detect newer manifest: " .. tostring(newerErr), 0)
    end
    if not newerInfo.updateAvailable or newerInfo.targetVersion ~= nextVersion then
        error(
            "Updater did not detect the newer version"
                .. " | current=" .. tostring(newerInfo.currentVersion)
                .. " | target=" .. tostring(newerInfo.targetVersion)
                .. " | available=" .. tostring(newerInfo.updateAvailable),
            0
        )
    end

    local installOk, installResult = updater.installFromManifest(newerInfo.remoteManifest)
    if not installOk then
        error("Smoke update failed: " .. tostring(installResult), 0)
    end

    local installedManifest = updater.loadManifest("manifest.json")
    if not installedManifest or installedManifest.version ~= nextVersion then
        error("Updated manifest was not written correctly", 0)
    end

    local updatedReadme = util.readFile("README.md")
    if not updatedReadme or not updatedReadme:find("Smoke update marker.", 1, true) then
        error("Updated README marker was not written", 0)
    end

    _G.__smokeBodyOverrides = {
        ["manifest.json"] = replaceVersion(repoManifest, failingVersion)
    }
    _G.__smokeFailPath = "lib/music/app.lua"

    local failingInfo, failingErr = updater.checkForUpdate()
    if not failingInfo then
        error("Failed to fetch failing update manifest: " .. tostring(failingErr), 0)
    end
    if not failingInfo.updateAvailable then
        error("Expected a newer version for the failure path", 0)
    end

    local failedOk, failedErr = updater.installFromManifest(failingInfo.remoteManifest)
    _G.__smokeFailPath = nil
    _G.__smokeBodyOverrides = nil

    if failedOk or not tostring(failedErr):find("lib/music/app.lua", 1, true) then
        error("Updater failure path did not report the failing file", 0)
    end

    local afterFailure = updater.loadManifest("manifest.json")
    if not afterFailure or afterFailure.version ~= nextVersion then
        error("Failed update should not advance the local version", 0)
    end

    return {
        playlists = #playlists,
        tracks = #playlists[1].songs,
        warnings = #warnings,
        version = afterFailure.version
    }
end
]])
end

local ok, err = pcall(function()
    writeFile("config.json", '[{"name":"Preserved","repo":"test/smoke","branch":"main","index":"index.txt"}]')

    runProgram("/repo/install.lua")

    assertExists("startup.lua")
    assertExists("manifest.json")
    assertExists("config.json")
    assertExists("lib/music/bootstrap.lua")
    assertExists("lib/music/app.lua")

    local preservedConfig = readFile("config.json")
    if preservedConfig ~= '[{"name":"Preserved","repo":"test/smoke","branch":"main","index":"index.txt"}]' then
        error("Installer did not preserve the existing config.json", 0)
    end

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
os.reboot = originalOsReboot
peripheral = originalPeripheral
parallel = originalParallel
_G.http = http
_G.__smokeBodyOverrides = nil
_G.__smokeFailPath = nil
_G.__smokeRebooted = nil
_G.peripheral = peripheral
_G.parallel = parallel

if not ok then
    error("CraftOS-PC repo smoke test failed: " .. tostring(err) .. " | URLs: " .. table.concat(requestedUrls, ", "), 0)
end

print("CraftOS-PC repo smoke test passed")
os.shutdown()