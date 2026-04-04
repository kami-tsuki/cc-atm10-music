---@diagnostic disable: undefined-global
local httpClient = require("music.http")
local util = require("music.util")

local M = {}

M.DEFAULT_REPO = "kami-tsuki/cc-atm10-music"
M.DEFAULT_BRANCH = "main"
M.DEFAULT_PATH = "manifest.json"

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

local function normalizeStringList(items)
    local normalized = {}
    local lookup = {}

    for _, item in ipairs(items or {}) do
        local value = util.trim(item)
        if value ~= "" and not lookup[value] then
            lookup[value] = true
            normalized[#normalized + 1] = value
        end
    end

    return normalized, lookup
end

local function matchesPath(path, values, lookup)
    path = tostring(path or "")
    if path == "" then
        return false
    end

    if lookup and lookup[path] then
        return true
    end

    for _, value in ipairs(values or {}) do
        if hasWildcard(value) and path:match(globToPattern(value)) then
            return true
        end
    end

    return false
end

local function normalizeFileEntry(entry)
    if type(entry) == "string" then
        local path = util.trim(entry)
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

    local path = util.trim(entry.path or entry.destination or "")
    if path == "" then
        return nil, "file entry is missing 'path'"
    end

    local source = util.trim(entry.source or entry.path or path)
    if (hasWildcard(source) or hasWildcard(path)) and path ~= source then
        return nil, "pattern entries currently require matching 'path' and 'source'"
    end

    return {
        path = path,
        source = source,
        isPattern = hasWildcard(source) or hasWildcard(path)
    }
end

local function makeTreeUrl(repo, branch)
    return string.format(
        "https://api.github.com/repos/%s/git/trees/%s?recursive=1",
        repo or M.DEFAULT_REPO,
        util.urlEncode(branch or M.DEFAULT_BRANCH)
    )
end

local function fetchRepoFiles(repo, branch, cache)
    local cacheKey = (repo or M.DEFAULT_REPO) .. "@" .. (branch or M.DEFAULT_BRANCH)
    if cache and cache[cacheKey] then
        return cache[cacheKey]
    end

    local parsed, err = httpClient.readJson(makeTreeUrl(repo, branch), {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = "cc-atm10-music-updater"
    })
    if not parsed then
        return nil, err
    end

    if type(parsed.tree) ~= "table" then
        return nil, "invalid repository tree response"
    end

    local files = {}
    for _, node in ipairs(parsed.tree) do
        if type(node) == "table" and node.type == "blob" and type(node.path) == "string" then
            files[#files + 1] = node.path
        end
    end

    if cache then
        cache[cacheKey] = files
    end

    return files
end

function M.rawUrl(repo, branch, path)
    return string.format(
        "https://raw.githubusercontent.com/%s/%s/%s",
        repo or M.DEFAULT_REPO,
        branch or M.DEFAULT_BRANCH,
        util.encodePath(path)
    )
end

function M.normalize(parsed, defaults)
    defaults = defaults or {}
    if type(parsed) ~= "table" then
        return nil, "manifest must be a JSON object"
    end

    local version = util.trim(parsed.version or "")
    if version == "" then
        return nil, "manifest is missing 'version'"
    end

    local repo = util.trim(parsed.repo or defaults.repo or M.DEFAULT_REPO)
    local branch = util.trim(parsed.branch or defaults.branch or M.DEFAULT_BRANCH)
    local files = {}

    for _, entry in ipairs(parsed.files or {}) do
        local normalized, err = normalizeFileEntry(entry)
        if not normalized then
            return nil, err
        end
        files[#files + 1] = normalized
    end

    if #files == 0 then
        return nil, "manifest does not contain any files"
    end

    local obsolete = normalizeStringList(parsed.obsolete or {})
    local preserve, preserveLookup = normalizeStringList(parsed.preserve or {})

    return {
        tabletName = util.trim(parsed["Tablet name"] or parsed.tabletName or ""),
        version = version,
        repo = repo,
        branch = branch,
        files = files,
        obsolete = obsolete,
        preserve = preserve,
        preserveLookup = preserveLookup
    }
end

function M.parse(body, defaults)
    local parsed = textutils.unserializeJSON(body)
    if type(parsed) ~= "table" then
        return nil, "invalid manifest JSON"
    end

    return M.normalize(parsed, defaults)
end

function M.load(path, defaults)
    local body, err = util.readFile(path or M.DEFAULT_PATH)
    if not body then
        return nil, err
    end

    return M.parse(body, defaults)
end

function M.fetch(repo, branch, path, defaults)
    local url = M.rawUrl(repo or M.DEFAULT_REPO, branch or M.DEFAULT_BRANCH, path or M.DEFAULT_PATH)
    local ok, bodyOrError = httpClient.read(url)
    if not ok then
        return nil, bodyOrError
    end

    defaults = defaults or {}
    defaults.repo = repo or defaults.repo
    defaults.branch = branch or defaults.branch
    return M.parse(bodyOrError, defaults)
end

function M.expandFiles(entries, repo, branch, cache)
    local expanded = {}
    local seen = {}
    local treeCache = cache or {}

    for _, entry in ipairs(entries or {}) do
        if entry.isPattern then
            local files, err = fetchRepoFiles(repo, branch, treeCache)
            if not files then
                return nil, err
            end

            local pattern = globToPattern(entry.source)
            local matched = false
            for _, path in ipairs(files) do
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

function M.isPreservedPath(manifest, path)
    return matchesPath(path, manifest and manifest.preserve or nil, manifest and manifest.preserveLookup or nil)
end

function M.compareVersions(left, right)
    local function parseVersion(version)
        version = util.trim(version or "")
        local base = version:match("^v?([0-9][0-9%.]*)")
        if not base then
            return nil
        end

        local parts = {}
        for token in base:gmatch("(%d+)") do
            parts[#parts + 1] = tonumber(token)
        end

        if #parts == 0 then
            return nil
        end

        return parts
    end

    local leftParts = parseVersion(left)
    local rightParts = parseVersion(right)

    if not leftParts or not rightParts then
        local leftValue = tostring(left or "")
        local rightValue = tostring(right or "")
        if leftValue == rightValue then
            return 0
        end
        return leftValue < rightValue and -1 or 1
    end

    local count = math.max(#leftParts, #rightParts)
    for index = 1, count do
        local leftValue = leftParts[index] or 0
        local rightValue = rightParts[index] or 0
        if leftValue < rightValue then
            return -1
        elseif leftValue > rightValue then
            return 1
        end
    end

    return 0
end

return M