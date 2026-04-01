---@diagnostic disable: undefined-global
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

local baseDir = currentBaseDir()
local bootstrapPath = fs.combine(baseDir, "lib/music/bootstrap.lua")

if not fs.exists(bootstrapPath) then
    error("Missing lib/music/bootstrap.lua. Run install.lua first.")
end

local bootstrap = assert(loadfile(bootstrapPath))()
bootstrap.run("music.app")