local kind = "server"
local source = http.get("https://github.com/kami-tsuki/cc-atm10-music/raw/refs/heads/main/"..kind..".lua").readAll()
local fn = load("return " .. source, "code", "t", _G)
setfenv(fn, _G)
fn()(require)