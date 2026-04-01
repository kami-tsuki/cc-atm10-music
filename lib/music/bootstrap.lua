---@diagnostic disable: undefined-global
local M = {}

local function currentBaseDir()
    if shell and shell.getRunningProgram then
        local program = shell.getRunningProgram()
        if program and program ~= "" then
            return fs.getDir(program)
        end
    end

    if shell and shell.dir then
        return shell.dir()
    end

    return ""
end

local function loadCcRequireModule(nativeRequire)
    if nativeRequire then
        local ok, result = pcall(nativeRequire, "cc.require")
        if ok and type(result) == "table" and type(result.make) == "function" then
            return result
        end
    end

    local romPath = "rom/modules/main/cc/require.lua"
    if not fs.exists(romPath) then
        error("Missing CC: Tweaked module loader at '" .. romPath .. "'.")
    end

    local chunk, err = loadfile(romPath)
    if not chunk then
        error("Failed to load CC: Tweaked require implementation: " .. tostring(err))
    end

    local ok, result = pcall(chunk)
    if not ok then
        error(result)
    end

    if type(result) ~= "table" or type(result.make) ~= "function" then
        error("CC: Tweaked require module did not expose make().")
    end

    return result
end

function M.run(moduleName, ...)
    local baseDir = currentBaseDir()
    local nativeRequire = rawget(_G, "require")
    local ccRequire = loadCcRequireModule(nativeRequire)
    local envDir = baseDir == "" and "/" or baseDir

    _G.require, _G.package = ccRequire.make(_G, envDir)

    local entry = require(moduleName)
    if type(entry) == "table" and type(entry.run) == "function" then
        return entry.run(...)
    end

    if type(entry) == "function" then
        return entry(...)
    end

    error("Module '" .. tostring(moduleName) .. "' has no runnable entry point.")
end

return M