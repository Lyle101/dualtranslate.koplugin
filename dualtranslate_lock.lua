-- Book-level mutual exclusion for manifest/entries writers (design 14.1).
-- Lives outside Store so Epub.save_checkpoint can hold the same lock without
-- an Epub -> Store -> Cache/Overlay dependency cycle (D12).  lfs only.

local lfs = require("libs/libkoreader-lfs")

local Lock = {}

local DEFAULT_TIMEOUT = 10
local DEFAULT_INTERVAL = 0.05
local STALE_SECONDS = 300

local function ensure_dir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local prefix = dir:sub(1, 1) == "/" and "" or "."
    for component in dir:gmatch("[^/]+") do
        prefix = prefix .. "/" .. component
        if lfs.attributes(prefix, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(prefix)
            if not ok and lfs.attributes(prefix, "mode") ~= "directory" then
                return nil, tostring(err)
            end
        end
    end
    return lfs.attributes(dir, "mode") == "directory"
end

-- lfs offers no sleep and this module must not pull in ffi/socket: poll the
-- clock instead.  Critical sections are short, so contention is brief.
local function wait(seconds)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do end
end

local function pack(...)
    return { n = select("#", ...), ... }
end

-- Runs fn while holding <dir>/.lock.  Returns fn's results; on lock timeout
-- returns nil, err; an error inside fn unlocks and is rethrown unchanged.
function Lock.withBookLock(dir, fn, opts)
    if not dir or dir == "" then return nil, "book lock: missing directory" end
    opts = opts or {}
    local timeout = tonumber(opts.timeout) or DEFAULT_TIMEOUT
    local interval = tonumber(opts.interval) or DEFAULT_INTERVAL
    local stale_seconds = tonumber(opts.stale_seconds) or STALE_SECONDS
    local ok, err = ensure_dir(dir)
    if not ok then return nil, "book lock: cannot create directory: " .. tostring(err) end
    local lockdir = dir .. "/.lock"
    local deadline = os.clock() + timeout
    while true do
        if lfs.mkdir(lockdir) then break end
        local mtime = lfs.attributes(lockdir, "modification")
        if mtime and os.time() - mtime > stale_seconds then
            lfs.rmdir(lockdir)
        else
            if os.clock() >= deadline then
                return nil, "book lock timeout: " .. dir
            end
            wait(interval)
        end
    end
    local result = pack(pcall(fn))
    lfs.rmdir(lockdir)
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end

return Lock