local kind = "server"
local source
-- Prefer local copy if it exists so in-repo edits are used; otherwise fall back to remote.
if fs and fs.exists(kind..".lua") then
	local fh = fs.open(kind..".lua", "r")
	source = fh.readAll()
	fh.close()
else
	local ok,resp = pcall(function()
		return http.get("https://github.com/kami-tsuki/cc-atm10-music/raw/refs/heads/main/"..kind..".lua")
	end)
	if ok and resp then
		source = resp.readAll()
		resp.close()
	else
		error("Failed to load server.lua from both local and remote")
	end
end

local fn = load("return " .. source, "code", "t", _G)
setfenv(fn, _G)
fn()(require)