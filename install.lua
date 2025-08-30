-- install.lua
-- ComputerCraft installer: download project files into the current computer's folder
-- Usage: run install

local files = {
  ["startup.lua"] = "https://raw.githubusercontent.com/kami-tsuki/cc-atm10-music/main/startup.lua",
  }

local function okPrint(...) print(...) end
local function errPrint(...) print(... ) end

if not http then
  errPrint("HTTP API is not available. Enable 'enableHttp' in ComputerCraft config.")
  return
end

local function download(url, dest)
  local resp = http.get(url)
  if not resp then return false, "http.get failed" end
  local data = resp.readAll()
  resp.close()
  local fh = fs.open(dest, "w")
  if not fh then return false, "failed to open "..dest end
  fh.write(data)
  fh.close()
  return true
end

local function listOptions()
  print("Files available to download:")
  local i = 1
  for name,_ in pairs(files) do
    print(string.format(" %2d) %s", i, name))
    i = i + 1
  end
  print(" a) all")
  print(" q) quit")
end

-- Simple prompt
print("cc-atm10-music installer")
listOptions()
write("Choose file number, 'a' for all, or 'q' to quit: ")
local choice = read()
if not choice then print("no selection, aborting") return end
choice = choice:lower()

local toDownload = {}
if choice == "q" then
  print("aborted")
  return
elseif choice == "a" then
  for name,_ in pairs(files) do table.insert(toDownload, name) end
else
  local n = tonumber(choice)
  if n then
    -- map numeric selection to file name
    local idx = 1
    for name,_ in pairs(files) do
      if idx == n then table.insert(toDownload, name) break end
      idx = idx + 1
    end
  end
end

if #toDownload == 0 then
  print("No valid selection, aborting")
  return
end

for _, name in ipairs(toDownload) do
  local url = files[name]
  if not url then
    print("Unknown file: "..name)
  else
    print("Downloading "..name.." ...")
    local ok, err = download(url, name)
    if ok then
      print("Saved: "..name)
    else
      print("Failed to download "..name..": "..tostring(err))
    end
  end
end

print("Done. You can now run 'startup' or edit the downloaded files.")
