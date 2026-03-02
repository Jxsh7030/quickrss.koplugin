-- QuickRSS: Image Cache Utilities
-- Downloads and caches remote images to disk. Provides helper functions to
-- rewrite remote <img src> URLs in HTML to local filenames, and to strip
-- publisher-injected width/height/style attributes so CSS can control layout.
--
-- Image downloads use wget (default) to avoid accumulating SSL sockets in
-- Lua's GC — on e-readers with low FD limits this prevents DNS failures.
-- Falls back to LuaSec if wget is not available.
--
-- Public API:
--   Images.IMAGE_DIR                    path to the image cache directory
--   Images.downloadImage(url)           → local filename (relative to IMAGE_DIR) or nil
--   Images.localizeImages(html)         → html with remote src rewritten to local filenames
--   Images.constrainImages(html)        → html with width/height/style stripped from <img>

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local IMAGE_DIR = DataStorage:getDataDir() .. "/quickrss/images"
lfs.mkdir(IMAGE_DIR)  -- no-op if already exists

-- ── Download backend detection ───────────────────────────────────────────────
-- Prefer wget (avoids Lua SSL socket accumulation), fall back to LuaSec.
local BACKEND  -- "wget" or "luasec"
do
    local ret = os.execute("wget --help >/dev/null 2>&1")
    -- Lua 5.1: os.execute returns exit code (0 = success).
    -- Lua 5.3+: returns true/nil.
    if ret == 0 or ret == true then
        BACKEND = "wget"
        logger.dbg("QuickRSS: using wget for image downloads")
    else
        BACKEND = "luasec"
        logger.dbg("QuickRSS: wget not found, using LuaSec for image downloads")
    end
end

-- Non-cryptographic hash → stable 8-char hex filename prefix.
local function urlHash(url)
    local h = 5381
    for i = 1, #url do
        h = ((h * 33) + url:byte(i)) % 0x100000000
    end
    return string.format("%08x", h)
end

-- Best-effort extension extraction; defaults to "jpg".
local function guessExt(url)
    return url:match("%.(%a%a%a?%a?)%?")
        or url:match("%.(%a%a%a?%a?)$")
        or "jpg"
end

-- Decode HTML entities in a URL extracted from an src attribute.
local function decodeUrl(url)
    return url:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
              :gsub("&quot;", '"'):gsub("&apos;", "'")
end

-- Shell-quote a string for safe use inside single quotes.
-- Replaces ' with '\'' (end quote, escaped literal quote, reopen quote).
local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ── wget backend ─────────────────────────────────────────────────────────────
local function _wgetOnce(url, fpath)
    local cmd = "wget -q -O " .. shellQuote(fpath)
             .. " --timeout=30"
             .. " -- " .. shellQuote(url)
             .. " 2>/dev/null"
    local ret = os.execute(cmd)
    if ret == 0 or ret == true then
        local size = lfs.attributes(fpath, "size")
        if size and size > 0 then
            return true
        end
    end
    os.remove(fpath)
    return false
end

local function downloadImageWget(url, fpath)
    return _wgetOnce(url, fpath)
end

-- ── LuaSec fallback backend ─────────────────────────────────────────────────
local function downloadImageLuaSec(url, fpath)
    local https      = require("ssl.https")
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")

    local MAX_RETRIES = 2
    local sink, ok, code, headers

    for attempt = 1, MAX_RETRIES + 1 do
        local current_url = url
        local net_err = false
        for _ = 1, 3 do
            sink = {}
            socketutil:set_timeout(
                socketutil.LARGE_BLOCK_TIMEOUT,
                socketutil.LARGE_TOTAL_TIMEOUT
            )
            ok, code, headers = https.request{
                url  = current_url,
                sink = ltn12.sink.table(sink),
            }
            socketutil:reset_timeout()

            if not ok then
                net_err = true
                break
            end
            if code == 301 or code == 302 or code == 303
            or code == 307 or code == 308 then
                local location = headers and headers["location"]
                if not location or location == "" then
                    logger.warn("QuickRSS: redirect with no Location:", url, code)
                    return false
                end
                logger.dbg("QuickRSS: image redirect", code, "→", location)
                current_url = location
            else
                break
            end
        end

        if net_err then
            if attempt <= MAX_RETRIES then
                logger.dbg("QuickRSS: image retry", attempt, "for:", url, code)
                os.execute("sleep 1")
            else
                logger.warn("QuickRSS: image download error:", url, code)
                return false
            end
        elseif code ~= 200 then
            logger.warn("QuickRSS: image download failed:", url, "HTTP", code)
            return false
        else
            break  -- success
        end
    end

    local f = io.open(fpath, "wb")
    if not f then return false end
    local write_ok, write_err = pcall(function()
        f:write(table.concat(sink))
    end)
    f:close()
    if not write_ok then
        os.remove(fpath)
        logger.warn("QuickRSS: image write failed:", fpath, write_err)
        return false
    end
    return true
end

-- ── Public download function ─────────────────────────────────────────────────
-- Download one image URL into IMAGE_DIR.  Returns the local filename (relative
-- to IMAGE_DIR) on success, or nil on failure.  Already-cached files are
-- returned immediately without a network request.
--
-- Tracks hosts where DNS has failed.  After 2 consecutive failures for the
-- same host, all remaining images from that host are skipped (DNS stays
-- broken for the rest of the session once it fails on these devices).
local _host_fails = {}   -- host → consecutive failure count
local _host_skipped = {} -- host → number of images skipped

local function downloadImage(url)
    -- Decode HTML entities that may be present in URLs extracted from RSS/HTML
    url = decodeUrl(url)

    local host = url:match("^https?://([^/]+)")

    -- Skip hosts with persistent DNS failure
    if host and (_host_fails[host] or 0) >= 2 then
        _host_skipped[host] = (_host_skipped[host] or 0) + 1
        return nil
    end

    local fname = urlHash(url) .. "." .. guessExt(url)
    local fpath = IMAGE_DIR .. "/" .. fname

    -- Cache hit
    local f = io.open(fpath, "rb")
    if f then f:close(); return fname end

    -- Pace downloads: 250ms delay avoids overwhelming DNS/WiFi on e-readers.
    -- Only applies to actual network requests, not cache hits above.
    os.execute("sleep 0.25")

    local ok
    if BACKEND == "wget" then
        ok = downloadImageWget(url, fpath)
    else
        ok = downloadImageLuaSec(url, fpath)
    end

    if ok then
        if host then _host_fails[host] = 0 end
        logger.dbg("QuickRSS: cached image", fname, "from:", url)
        return fname
    else
        if host then
            _host_fails[host] = (_host_fails[host] or 0) + 1
            if _host_fails[host] == 2 then
                logger.warn("QuickRSS: skipping remaining images from", host, "(DNS broken)")
            end
        end
        logger.warn("QuickRSS: image download failed:", url)
        return nil
    end
end

-- Reset host failure tracking (called at start of each fetch cycle).
local function resetHostTracking()
    for host, count in pairs(_host_skipped) do
        if count > 0 then
            logger.info("QuickRSS: skipped", count, "images from", host, "(DNS was broken)")
        end
    end
    _host_fails = {}
    _host_skipped = {}
end

-- Strip width/height/style attributes from <img> tags so CSS max-width can
-- take effect.  Publishers often embed explicit pixel dimensions that make
-- images overflow the viewport regardless of what the stylesheet says.
local function constrainImages(html)
    return html:gsub("(<[Ii][Mm][Gg]%s)([^>]*)(>)", function(open, attrs, close)
        attrs = attrs:gsub('%s*width%s*=%s*"[^"]*"', "")
        attrs = attrs:gsub("%s*width%s*=%s*'[^']*'", "")
        attrs = attrs:gsub('%s*height%s*=%s*"[^"]*"', "")
        attrs = attrs:gsub("%s*height%s*=%s*'[^']*'", "")
        attrs = attrs:gsub('%s*style%s*=%s*"[^"]*"', "")
        attrs = attrs:gsub("%s*style%s*=%s*'[^']*'", "")
        return open .. attrs .. close
    end)
end

-- Rewrite every remote <img src="https?://..."> in html to a local filename
-- relative to IMAGE_DIR.  Handles both double- and single-quoted src values.
local function localizeImages(html)
    -- double-quoted src
    html = html:gsub('([Ss][Rr][Cc]%s*=%s*)"(https?://[^"]+)"', function(eq, url)
        local fname = downloadImage(url)
        return eq .. '"' .. (fname or url) .. '"'
    end)
    -- single-quoted src
    html = html:gsub("([Ss][Rr][Cc]%s*=%s*)'(https?://[^']+)'", function(eq, url)
        local fname = downloadImage(url)
        return eq .. "'" .. (fname or url) .. "'"
    end)
    return html
end

return {
    IMAGE_DIR          = IMAGE_DIR,
    downloadImage      = downloadImage,
    localizeImages     = localizeImages,
    constrainImages    = constrainImages,
    resetHostTracking  = resetHostTracking,
}
