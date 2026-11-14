-- Book-level mutual exclusion for manifest/entries writers (design 14.1).
-- Lives outside Store so Epub.save_checkpoint can hold the same lock without
-- an Epub -> Store -> Cache/Overlay dependency cycle (D12).  Depends only on
-- lfs and the low-level ffi/util sleep/clock helpers (no D12 cycle).

local lfs = require("libs/libkoreader-lfs")
local util = require("ffi/util")

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

-- Yield the CPU instead of busy-waiting.  ffi/util.sleep maps to C.sleep on
-- POSIX, which truncates to whole seconds, so the sub-second polling
-- interval goes through usleep (same low-level module).
local function wait(seconds)
    local whole = math.floor(seconds)
    if whole > 0 then util.sleep(whole) end
    local fraction = seconds - whole
    if fraction > 0 then
        if util.usleep then
            util.usleep(math.floor(fraction * 1e6))
        else
            util.sleep(fraction)
        end
    end
end

local function pack(...)
    return { n = select("#", ...), ... }
end

-- Runs fn while holding <dir>/.lock.  Returns fn's results; on lock timeout
-- returns nil, err; an error inside fn unlocks and is rethrown unchanged.
-- The timeout accumulates on the wall clock (ffi/util.getTimestamp), not on
-- CPU time, so sleeping between polls does not stretch it.
function Lock.withBookLock(dir, fn, opts)
    if not dir or dir == "" then return nil, "book lock: missing directory" end
    opts = opts or {}
    local timeout = tonumber(opts.timeout) or DEFAULT_TIMEOUT
    local interval = tonumber(opts.interval) or DEFAULT_INTERVAL
    local stale_seconds = tonumber(opts.stale_seconds) or STALE_SECONDS
    local ok, err = ensure_dir(dir)
    if not ok then return nil, "book lock: cannot create directory: " .. tostring(err) end
    local lockdir = dir .. "/.lock"
    local deadline = util.getTimestamp() + timeout
    while true do
        if lfs.mkdir(lockdir) then break end
        local mtime = lfs.attributes(lockdir, "modification")
        local stale = mtime and os.time() - mtime > stale_seconds
        if stale then
            -- TOCTOU guard: another process may have reclaimed the stale
            -- lock and created a fresh one since the stat above.  Re-check
            -- immediately before the destructive rmdir so a fresh lock is
            -- never deleted.
            local current = lfs.attributes(lockdir, "modification")
            stale = current and os.time() - current > stale_seconds
        end
        if stale then
            lfs.rmdir(lockdir)
            -- Re-check after rmdir too: if the lock directory exists again,
            -- a competitor won the reclaim race.  Go back to the wait loop
            -- instead of mkdir-ing over (or deleting) its lock.
            if lfs.attributes(lockdir, "mode") == "directory" then
                stale = false
            end
        end
        if not stale then
            if util.getTimestamp() >= deadline then
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