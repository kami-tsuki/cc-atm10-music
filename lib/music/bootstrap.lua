---@diagnostic disable: undefined-global
local M = {}

local function appendPath(fragment)
    if not package or not package.path then
        error("Lua package.path is unavailable in this environment.")
    end

    if not string.find(package.path, fragment, 1, true) then
        package.path = package.path .. ";" .. fragment
    end
end

local function configurePackagePath(baseDir)
    local libRoot = fs.combine(baseDir, "lib")
    appendPath(fs.combine(libRoot, "?.lua"))
    appendPath(fs.combine(libRoot, "?/init.lua"))
end

function M.run(moduleName, ...)
    local baseDir = shell and shell.dir() or ""
    configurePackagePath(baseDir)

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