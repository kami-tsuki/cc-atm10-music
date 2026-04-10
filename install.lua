---@diagnostic disable: undefined-global
local APP_NAME = "cc-atm10-music"
local TABLET_NAME = "KAMI-RADIO"
local REPO = "kami-tsuki/cc-atm10-music"
local BRANCH = "main"
local MANIFEST_PATH = "manifest.json"
local BOOTSTRAP_ROOT_FILES = {
    ["startup.lua"] = true,
    ["update.lua"] = true,
    ["install.lua"] = true,
    ["config.json"] = true,
    ["README.md"] = true,
}
local BOOTSTRAP_PRESERVE = {
    "config.json",
    "local/*"
}

local function currentDir()
    if shell and shell.dir then
        return shell.dir()
    end
    return "/"
end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir == "" then
        return
    end

    local cursor = ""
    for part in string.gmatch(dir, "[^/]+") do
        cursor = cursor == "" and part or fs.combine(cursor, part)
        if not fs.exists(cursor) then
            fs.makeDir(cursor)
        end
    end
end

local function readUrl(url, headers)
    local lastError = "request failed"

    for attempt = 1, 3 do
        local ok, response = pcall(http.get, url, headers, true)
        if ok and response then
            local body = response.readAll()
            response.close()
            return true, body
        end

        lastError = tostring(response)
        sleep(0.2 * attempt)
    end

    return false, lastError
end

local function writeBody(path, body)
    ensureDir(path)
    local handle = fs.open(path, "wb") or fs.open(path, "w")
    if not handle then
        return false, "failed to write " .. path
    end

    handle.write(body)
    handle.close()
    return true
end

local function readLocalFile(path)
    if not fs.exists(path) then
        return nil, "missing file"
    end

    local handle = fs.open(path, "r")
    if not handle then
        return nil, "failed to open " .. path
    end

    local body = handle.readAll()
    handle.close()
    return body
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function encodePath(path)
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
        parts[#parts + 1] = (part:gsub("([^%w%-_%.~])", function(char)
            return string.format("%%%02X", string.byte(char))
        end))
    end
    return table.concat(parts, "/")
end

local function rawUrl(path, repo, branch)
    return string.format(
        "https://raw.githubusercontent.com/%s/%s/%s",
        repo or REPO,
        branch or BRANCH,
        encodePath(path)
    )
end

local function makeTreeUrl(repo, branch)
    return string.format(
        "https://api.github.com/repos/%s/git/trees/%s?recursive=1",
        repo or REPO,
        encodePath(branch or BRANCH)
    )
end

local function hasWildcard(value)
    value = tostring(value or "")
    return value:find("%*", 1, false) ~= nil or value:find("%?", 1, false) ~= nil
end

local function globToPattern(glob)
    local parts = { "^" }
    for index = 1, #glob do
        local char = glob:sub(index, index)
        if char == "*" then
            parts[#parts + 1] = ".*"
        elseif char == "?" then
            parts[#parts + 1] = "."
        elseif char:match("[%^%$%(%)%%%.%[%]%+%-%]]") then
            parts[#parts + 1] = "%" .. char
        else
            parts[#parts + 1] = char
        end
    end
    parts[#parts + 1] = "$"
    return table.concat(parts)
end

local function fetchRepoFiles(repo, branch)
    local ok, bodyOrError = readUrl(makeTreeUrl(repo, branch), {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = "cc-atm10-music-installer"
    })
    if not ok then
        return nil, bodyOrError
    end

    local parsed = textutils.unserializeJSON(bodyOrError)
    if type(parsed) ~= "table" or type(parsed.tree) ~= "table" then
        return nil, "invalid repository tree response"
    end

    local files = {}
    for _, node in ipairs(parsed.tree) do
        if type(node) == "table" and node.type == "blob" and type(node.path) == "string" then
            files[#files + 1] = node.path
        end
    end

    return files
end

local function normalizeFileEntry(entry)
    if type(entry) == "string" then
        local path = trim(entry)
        if path == "" then
            return nil, "file entry path is empty"
        end

        return {
            path = path,
            source = path,
            isPattern = hasWildcard(path)
        }
    end

    if type(entry) ~= "table" then
        return nil, "file entry must be a string or object"
    end

    local path = trim(entry.path or entry.destination or "")
    if path == "" then
        return nil, "file entry is missing 'path'"
    end

    local source = trim(entry.source or entry.path or path)
    if (hasWildcard(source) or hasWildcard(path)) and path ~= source then
        return nil, "pattern entries currently require matching 'path' and 'source'"
    end

    return {
        path = path,
        source = source,
        isPattern = hasWildcard(source) or hasWildcard(path)
    }
end

local function expandFileEntries(files, repo, branch)
    local expanded = {}
    local seen = {}
    local repoFiles = nil

    for _, entry in ipairs(files) do
        if entry.isPattern then
            if not repoFiles then
                local loaded, err = fetchRepoFiles(repo, branch)
                if not loaded then
                    return nil, err
                end
                repoFiles = loaded
            end

            local pattern = globToPattern(entry.source)
            local matched = false
            for _, path in ipairs(repoFiles) do
                if path:match(pattern) then
                    matched = true
                    if not seen[path] then
                        seen[path] = true
                        expanded[#expanded + 1] = {
                            path = path,
                            source = path,
                            isPattern = false
                        }
                    end
                end
            end

            if not matched then
                return nil, "pattern did not match any files: " .. entry.source
            end
        elseif not seen[entry.path] then
            seen[entry.path] = true
            expanded[#expanded + 1] = entry
        end
    end

    table.sort(expanded, function(left, right)
        return left.path < right.path
    end)

    return expanded
end

local function normalizeStringList(items)
    local values = {}
    local lookup = {}

    for _, item in ipairs(items or {}) do
        local value = trim(item)
        if value ~= "" and not lookup[value] then
            lookup[value] = true
            values[#values + 1] = value
        end
    end

    return values, lookup
end

local function isPreservedPath(manifest, path)
    path = trim(path)
    if path == "" then
        return false
    end

    if manifest.preserveLookup[path] then
        return true
    end

    for _, value in ipairs(manifest.preserve or {}) do
        if hasWildcard(value) and path:match(globToPattern(value)) then
            return true
        end
    end

    return false
end

local function parseManifestBody(body)
    local parsed = textutils.unserializeJSON(body)
    if type(parsed) ~= "table" then
        return nil, "invalid manifest.json"
    end

    local version = trim(parsed.version or "")
    if version == "" then
        return nil, "manifest.json is missing 'version'"
    end

    local files = {}
    for _, entry in ipairs(parsed.files or {}) do
        local normalized, err = normalizeFileEntry(entry)
        if not normalized then
            return nil, err
        end
        files[#files + 1] = normalized
    end

    if #files == 0 then
        return nil, "manifest.json does not contain any files"
    end

    local expandedFiles, expandErr = expandFileEntries(files, trim(parsed.repo or REPO), trim(parsed.branch or BRANCH))
    if not expandedFiles then
        return nil, expandErr
    end

    local obsolete = normalizeStringList(parsed.obsolete or {})
    local preserve, preserveLookup = normalizeStringList(parsed.preserve or {})

    return {
        version = version,
        repo = trim(parsed.repo or REPO),
        branch = trim(parsed.branch or BRANCH),
        files = expandedFiles,
        obsolete = obsolete,
        preserve = preserve,
        preserveLookup = preserveLookup
    }
end

local function loadManifest()
    local ok, bodyOrError = readUrl(rawUrl(MANIFEST_PATH))
    if ok then
        local manifest, parseErr = parseManifestBody(bodyOrError)
        if not manifest then
            return nil, parseErr
        end

        writeBody(MANIFEST_PATH, bodyOrError)
        return manifest, nil, "remote"
    end

    local localBody = readLocalFile(MANIFEST_PATH)
    if not localBody then
        return nil, "unable to download manifest.json: " .. tostring(bodyOrError)
    end

    local manifest, parseErr = parseManifestBody(localBody)
    if not manifest then
        return nil, "remote manifest unavailable and local manifest is invalid: " .. tostring(parseErr)
    end

    return manifest, nil, "local"
end

if not http then
    error("HTTP API is not available. Enable HTTP in CC: Tweaked before running install.lua.")
end

local manifest, manifestErr, manifestSource = loadManifest()
if not manifest then
    error("Failed to load install manifest: " .. tostring(manifestErr))
end

print(APP_NAME)
print("Installing runtime files into " .. currentDir())
print("Target version: " .. tostring(manifest.version))
if manifestSource == "local" then
    print("Remote manifest unavailable, using the existing local manifest.json.")
end
print("")

local failures = {}

for _, path in ipairs(manifest.obsolete) do
    if fs.exists(path) and not isPreservedPath(manifest, path) then
        fs.delete(path)
        print("Removed obsolete " .. path)
    end
end

if #manifest.obsolete > 0 then
    print("")
end

for _, entry in ipairs(manifest.files) do
    if isPreservedPath(manifest, entry.path) and fs.exists(entry.path) then
        print("Keeping existing " .. entry.path)
    else
        write("Downloading " .. entry.path .. " ... ")
        local ok, bodyOrError = readUrl(rawUrl(entry.source, manifest.repo, manifest.branch))
        if ok then
            local written, writeErr = writeBody(entry.path, bodyOrError)
            if written then
                print("ok")
            else
                print("failed")
                failures[#failures + 1] = entry.path .. ": " .. tostring(writeErr)
            end
        else
            print("failed")
            failures[#failures + 1] = entry.path .. ": " .. tostring(bodyOrError)
        end
    end
end

print("")
if #failures > 0 then
    print("Install finished with errors:")
    for _, failure in ipairs(failures) do
        print(" - " .. failure)
    end
    error("Installation incomplete.")
end

print("Install complete.")
print("Run 'startup' to launch the music player.")
