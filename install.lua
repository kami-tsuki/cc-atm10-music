---@diagnostic disable: undefined-global
local repoBase = "https://raw.githubusercontent.com/kami-tsuki/cc-atm10-music/main/"
local files = {
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

local keepIfPresent = {
    ["config.json"] = true
}

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

local function download(url, destination)
    local lastError = "request failed"

    for attempt = 1, 3 do
        local ok, response = pcall(http.get, url, nil, true)
        if ok and response then
            local body = response.readAll()
            response.close()

            ensureDir(destination)
            local handle = fs.open(destination, "wb") or fs.open(destination, "w")
            if not handle then
                return false, "failed to write " .. destination
            end

            handle.write(body)
            handle.close()
            return true
        end

        lastError = tostring(response)
        sleep(0.2 * attempt)
    end

    return false, lastError
end

if not http then
    error("HTTP API is not available. Enable HTTP in CC: Tweaked before running install.lua.")
end

print("cc-atm10-music")
print("Installing runtime files into " .. shell.dir())
print("")

local failures = {}

for _, path in ipairs(obsoleteFiles) do
    if fs.exists(path) then
        fs.delete(path)
        print("Removed obsolete " .. path)
    end
end

if #obsoleteFiles > 0 then
    print("")
end

for _, path in ipairs(files) do
    if keepIfPresent[path] and fs.exists(path) then
        print("Keeping existing " .. path)
    else
        write("Downloading " .. path .. " ... ")
        local ok, err = download(repoBase .. path, path)
        if ok then
            print("ok")
        else
            print("failed")
            failures[#failures + 1] = path .. ": " .. tostring(err)
        end
    end
end

print("")
if #failures > 0 then
    print("Install finished with errors:")
    for _, failure in ipairs(failures) do
        print(" - " .. failure)
    end
    error("Installation incomplete.")
end

print("Install complete.")
print("Run 'startup' to launch the music player.")
