-- QuickRSS: OPML Module
-- Reads and writes the standard OPML 1.0 feed-list format so users can
-- manage their subscriptions from a computer (text editor, another RSS
-- reader, etc.) without touching the device UI.
--
-- The file is stored in the dedicated plugin data directory:
--   <koreader data dir>/quickrss/feeds.opml
--
-- Public API:
--   OPML.read([path])          → { {name, url}, … }  or nil if file missing
--   OPML.write([path], feeds)  → true on success, false on I/O error
--   OPML.OPML_FILE             default path (exposed for Config / README)

local DataStorage = require("datastorage")
local logger      = require("logger")

local OPML_FILE = DataStorage:getDataDir() .. "/quickrss/feeds.opml"

local OPML = {}

-- Reverse the five XML entity escapes.
local function unescAttr(s)
    return s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
            :gsub("&apos;", "'"):gsub("&amp;", "&")
end

-- Extract a named XML attribute value from a raw tag string.
-- Handles both double- and single-quoted values.  Entity-decodes the result
-- so round-trip write → read does not accumulate escaping.
local function getAttr(tag, name)
    local val = tag:match(name .. '%s*=%s*"([^"]*)"')
             or tag:match(name .. "%s*=%s*'([^']*)'")
    return val and unescAttr(val) or nil
end

-- Escape the five XML special characters for use inside an attribute value.
local function escAttr(s)
    return (s or "")
        :gsub("&",  "&amp;")
        :gsub('"',  "&quot;")
        :gsub("'",  "&apos;")
        :gsub("<",  "&lt;")
        :gsub(">",  "&gt;")
end

-- Read feeds from an OPML file.
-- Returns a list of { name = string, url = string } tables, or nil if the
-- file does not exist (so callers can distinguish "missing" from "empty").
function OPML.read(path)
    path = path or OPML_FILE
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    local feeds = {}
    -- Match every <outline …/> or <outline …> regardless of attribute order.
    for tag in content:gmatch("<outline%s+([^>]*)/?%s*>") do
        local name = getAttr(tag, "text")
        local url  = getAttr(tag, "xmlUrl")
        if name and url and url ~= "" then
            table.insert(feeds, { name = name, url = url })
        end
    end
    logger.dbg("QuickRSS: loaded", #feeds, "feeds from OPML")
    return feeds
end

-- Write a list of { name, url } feeds to an OPML file.
-- Returns true on success, false on I/O error.
function OPML.write(path, feeds)
    path = path or OPML_FILE
    local lines = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="1.0">',
        '  <head><title>QuickRSS Feeds</title></head>',
        '  <body>',
    }
    for _, feed in ipairs(feeds) do
        table.insert(lines, string.format(
            '    <outline text="%s" type="rss" xmlUrl="%s"/>',
            escAttr(feed.name), escAttr(feed.url)))
    end
    table.insert(lines, '  </body>')
    table.insert(lines, '</opml>')

    local f, err = io.open(path, "w")
    if not f then
        logger.warn("QuickRSS: could not write OPML file:", path, err)
        return false
    end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    logger.dbg("QuickRSS: wrote", #feeds, "feeds to OPML")
    return true
end

OPML.OPML_FILE = OPML_FILE

return OPML
