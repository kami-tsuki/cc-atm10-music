---@diagnostic disable: undefined-global
local M = {}

local function modulePath(baseDir, moduleName)
    return fs.combine(baseDir, fs.combine("lib", moduleName:gsub("%.", "/") .. ".lua"))
end

local function createRequire(baseDir, nativeRequire)
    local cache = {}
    local loading = {}

    local function customRequire(moduleName)
        if cache[moduleName] ~= nil then
            return cache[moduleName]
        end

        if not moduleName:match("^music%.") then
            if nativeRequire then
                return nativeRequire(moduleName)
            end
            error("No native require is available for module '" .. tostring(moduleName) .. "'.")
        end

        if loading[moduleName] then
            error("Circular module load detected for '" .. moduleName .. "'.")
        end

        local path = modulePath(baseDir, moduleName)
        if not fs.exists(path) then
            error("Module file not found: " .. path)
        end

        local chunk, err = loadfile(path)
        if not chunk then
            error("Failed to load module '" .. moduleName .. "': " .. tostring(err))
        end

        loading[moduleName] = true
        local result = chunk()
        loading[moduleName] = nil

        if result == nil then
            result = true
        end

        cache[moduleName] = result
        return result
    end

    return customRequire
end

function M.run(moduleName, ...)
    local baseDir = shell and shell.dir() or ""
    local customRequire = createRequire(baseDir, rawget(_G, "require"))
    _G.require = customRequire

    local entry = customRequire(moduleName)
    if type(entry) == "table" and type(entry.run) == "function" then
        return entry.run(...)
    end

    if type(entry) == "function" then
        return entry(...)
    end

    error("Module '" .. tostring(moduleName) .. "' has no runnable entry point.")
end

return M