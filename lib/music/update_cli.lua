---@diagnostic disable: undefined-global
local updater = require("music.updater")

local M = {}

local function confirm(prompt)
    write(prompt .. " [y/N] ")
    local answer = read()
    answer = tostring(answer or ""):lower()
    return answer == "y" or answer == "yes"
end

local function printProgress(info)
    local percent = math.floor(((info and info.ratio) or 0) * 100 + 0.5)
    print(string.format("[%3d%%] %s", percent, info.message or "Working..."))
end

function M.run()
    if not http then
        error("HTTP API is required for updates.")
    end

    local updateInfo, updateErr = updater.checkForUpdate()
    if not updateInfo then
        error("Update check failed: " .. tostring(updateErr))
    end

    print("Current version: " .. tostring(updateInfo.currentVersion))
    print("Remote version:  " .. tostring(updateInfo.targetVersion))

    if not updateInfo.updateAvailable then
        print("Already up to date.")
        return true
    end

    if not confirm("Apply update now?") then
        print("Update cancelled.")
        return false
    end

    local ok, resultOrError = updater.installFromManifest(updateInfo.remoteManifest, {
        onProgress = printProgress
    })

    if not ok then
        error("Update failed: " .. tostring(resultOrError))
    end

    local installedVersion = updateInfo.targetVersion
    if type(resultOrError) == "table" and resultOrError.version then
        installedVersion = resultOrError.version
    end

    print("Updated to version " .. tostring(installedVersion) .. ".")
    if os.reboot and confirm("Reboot now?") then
        os.reboot()
    end

    return true
end

return M