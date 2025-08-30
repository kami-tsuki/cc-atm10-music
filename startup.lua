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

-- Try to fetch latest config.json from the repo so playlists stay dynamic.
local configRemote = "https://github.com/kami-tsuki/cc-atm10-music/raw/refs/heads/main/config.json"
if http then
	local ok, resp = pcall(function() return http.get(configRemote) end)
	if ok and resp then
		local cfg = resp.readAll()
		resp.close()
		local fh = fs.open("config.json", "w")
		if fh then
			fh.write(cfg)
			fh.close()
		end
	else
		-- couldn't fetch remote config; leave local config.json as-is (if any)
	end
end

local fn = load("return " .. source, "code", "t", _G)
setfenv(fn, _G)
fn()(require)