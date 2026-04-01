---@diagnostic disable: undefined-global
local baseDir = shell and shell.dir() or ""
local bootstrapPath = fs.combine(baseDir, "lib/music/bootstrap.lua")

if not fs.exists(bootstrapPath) then
    error("Missing lib/music/bootstrap.lua. Run install.lua first.")
end

local bootstrap = assert(loadfile(bootstrapPath))()
bootstrap.run("music.app")