---@diagnostic disable: undefined-global
local httpClient = require("music.http")
local manifestModel = require("music.manifest")
local util = require("music.util")

local M = {}

M.MANIFEST_PATH = manifestModel.DEFAULT_PATH
M.DEFAULT_REPO = manifestModel.DEFAULT_REPO
M.DEFAULT_BRANCH = manifestModel.DEFAULT_BRANCH

local function resolveManifestSource(localManifest, overrides)
    overrides = overrides or {}

    return {
        repo = overrides.repo or (localManifest and localManifest.repo) or M.DEFAULT_REPO,
        branch = overrides.branch or (localManifest and localManifest.branch) or M.DEFAULT_BRANCH,
        path = overrides.path or M.MANIFEST_PATH
    }
end

local function writeBody(path, body)
    util.ensureDir(path)

    local handle = fs.open(path, "wb") or fs.open(path, "w")
    if not handle then
        return false, "failed to open file"
    end

    handle.write(body)
    handle.close()
    return true
end

local function progress(callback, step, total, message, phase, path)
    if not callback then
        return
    end

    callback({
        step = step,
        total = total,
        ratio = total > 0 and (step / total) or 1,
        message = message,
        phase = phase,
        path = path
    })
end

function M.rawUrl(repo, branch, path)
    return manifestModel.rawUrl(repo, branch, path)
end

function M.loadManifest(path)
    return manifestModel.load(path or M.MANIFEST_PATH)
end

function M.fetchRemoteManifest(repo, branch, path)
    return manifestModel.fetch(repo or M.DEFAULT_REPO, branch or M.DEFAULT_BRANCH, path or M.MANIFEST_PATH)
end

function M.compareVersions(left, right)
    return manifestModel.compareVersions(left, right)
end

function M.checkForUpdate(options)
    local localManifest = M.loadManifest(M.MANIFEST_PATH)
    local currentVersion = localManifest and localManifest.version or "0.0.0"
    local source = resolveManifestSource(localManifest, options)
    local remoteManifest, err = M.fetchRemoteManifest(source.repo, source.branch, source.path)
    if not remoteManifest then
        return nil, err
    end

    return {
        localManifest = localManifest,
        remoteManifest = remoteManifest,
        source = source,
        currentVersion = currentVersion,
        targetVersion = remoteManifest.version,
        updateAvailable = M.compareVersions(currentVersion, remoteManifest.version) < 0
    }
end

function M.installFromManifest(manifest, options)
    options = options or {}
    local onProgress = options.onProgress

    local normalized, err = manifestModel.normalize(manifest)
    if not normalized then
        return false, err
    end

    local expandedFiles, expandErr = manifestModel.expandFiles(normalized.files, normalized.repo, normalized.branch)
    if not expandedFiles then
        return false, expandErr
    end

    normalized.files = expandedFiles

    local downloadQueue = {}
    local skipped = 0
    for _, entry in ipairs(normalized.files) do
        if manifestModel.isPreservedPath(normalized, entry.path) and fs.exists(entry.path) then
            skipped = skipped + 1
        else
            downloadQueue[#downloadQueue + 1] = entry
        end
    end

    local deleteQueue = {}
    for _, path in ipairs(normalized.obsolete) do
        if not manifestModel.isPreservedPath(normalized, path) and fs.exists(path) then
            deleteQueue[#deleteQueue + 1] = path
        end
    end

    local writeQueue = {}
    local totalSteps = #downloadQueue + #deleteQueue + #downloadQueue
    local step = 0

    if totalSteps == 0 then
        progress(onProgress, 1, 1, "Already up to date", "done")
        return true, {
            downloaded = 0,
            written = 0,
            deleted = 0,
            skipped = skipped,
            version = normalized.version
        }
    end

    for _, entry in ipairs(downloadQueue) do
        step = step + 1
        progress(onProgress, step, totalSteps, "Downloading " .. entry.path, "download", entry.path)

        local ok, bodyOrError = httpClient.read(M.rawUrl(normalized.repo, normalized.branch, entry.source))
        if not ok then
            return false, "Failed to download " .. entry.path .. ": " .. tostring(bodyOrError)
        end

        writeQueue[#writeQueue + 1] = {
            entry = entry,
            body = bodyOrError
        }
    end

    for _, path in ipairs(deleteQueue) do
        step = step + 1
        progress(onProgress, step, totalSteps, "Removing obsolete " .. path, "delete", path)
        fs.delete(path)
    end

    table.sort(writeQueue, function(left, right)
        if left.entry.path == M.MANIFEST_PATH then
            return false
        end
        if right.entry.path == M.MANIFEST_PATH then
            return true
        end
        return left.entry.path < right.entry.path
    end)

    for _, item in ipairs(writeQueue) do
        step = step + 1
        progress(onProgress, step, totalSteps, "Installing " .. item.entry.path, "write", item.entry.path)

        local ok, writeErr = writeBody(item.entry.path, item.body)
        if not ok then
            return false, "Failed to write " .. item.entry.path .. ": " .. tostring(writeErr)
        end
    end

    return true, {
        downloaded = #downloadQueue,
        written = #writeQueue,
        deleted = #deleteQueue,
        skipped = skipped,
        version = normalized.version
    }
end

function M.installLatest(options)
    local manifest, err = M.fetchRemoteManifest()
    if not manifest then
        return false, err
    end

    return M.installFromManifest(manifest, options)
end

return M
