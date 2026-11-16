--[[--
Book list for the shelf: finds books, reads title, author, cover and progress.

Metadata comes from Cover Browser's cache (bookinfo_cache.sqlite3) even while
that plugin is disabled, then from the book's .sdr sidecar, then from the file name.
--]]--

local BookList = require("ui/widget/booklist")
local Covers = require("covers")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local SQ3 = require("lua-ljsqlite3/init")
local ReadHistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local BOOK_SUFFIXES = {
    epub = true, pdf = true, djvu = true, fb2 = true, mobi = true,
    azw = true, azw3 = true, cbz = true, cbr = true,
}
local SKIP_DIRS = { ["System Volume Information"] = true }
local MAX_DEPTH = 4
local STATS_DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local STATS_DEFAULT_MAX_SEC = 120
-- Fewer read pages than this give a guess too noisy to show.
local STATS_MIN_PAGES = 10
-- Same capped sum the statistics plugin uses: a page counts at most max_sec, so idle time is ignored.
local STATS_CAPPED_TOTALS = [[
    SELECT count(*), sum(durations) FROM (
        SELECT min(sum(duration), %d) AS durations FROM page_stat WHERE id_book = %d GROUP BY page
    );
]]

-- Placeholder titles some converters write; the file name says more.
local PLACEHOLDER_TITLES = { cover = true, default = true, untitled = true, unknown = true }

local Library = {}

-- Loads Cover Browser's BookInfoManager without enabling that plugin.
function Library.loadBookInfoManager(plugins_dir)
    local cb_dir = plugins_dir .. "/coverbrowser.koplugin"
    if lfs.attributes(cb_dir .. "/bookinfomanager.lua", "mode") ~= "file" then
        logger.warn("shelf: coverbrowser.koplugin not found, no covers")
        return nil
    end
    if not package.path:find(cb_dir, 1, true) then
        package.path = cb_dir .. "/?.lua;" .. package.path
    end
    local ok, bim = pcall(require, "bookinfomanager")
    if not ok then
        logger.warn("shelf: cannot load bookinfomanager:", bim)
        return nil
    end
    return bim
end

local function isBook(name)
    if name:sub(1, 1) == "." then return false end
    local suffix = util.getFileNameSuffix(name)
    return suffix and BOOK_SUFFIXES[suffix:lower()] or false
end

local function scan(dir, depth, out)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "file" and isBook(name) then
                table.insert(out, path)
            elseif mode == "directory" and depth < MAX_DEPTH
                    and name:sub(1, 1) ~= "." and not name:match("%.sdr$") and not SKIP_DIRS[name] then
                scan(path, depth + 1, out)
            end
        end
    end
end

-- "bart hopkin_ john scoville - musical instrument design_ practical..." → author, title
local function guessFromFileName(path)
    local _, name = util.splitFilePathName(path)
    name = name:gsub("%.kepub%.epub$", ""):gsub("%.[^.]+$", "")
    name = name:gsub("^_?oceanofpdf%.com_", ""):gsub("_", " "):gsub("%s+", " ")
    local author, title = name:match("^(.-) %- (.+)$")
    if author and #author < 60 then
        return util.trim(title), util.trim(author)
    end
    return util.trim(name), nil
end

-- "Hopkin, Bart" → "Bart Hopkin"
local function firstAuthor(authors)
    if not authors or authors == "" then return nil end
    local first = util.trim(authors:match("^[^\n]+") or "")
    local last, given = first:match("^([^,]+), ([^,]+)$")
    if last then first = given .. " " .. last end
    return first ~= "" and first or nil
end

-- PDF titles often keep the authoring app's file name: "Pocket Operations.pages"
local function cleanTitle(title)
    return (title:gsub("%.pages$", ""):gsub("%.docx?$", ""):gsub("%.indd$", ""):gsub("%.pdf$", ""))
end

function Library:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Library:readMeta(path, info)
    local title, authors
    if info and info.has_meta and not info.ignore_meta then
        title, authors = info.title, info.authors
    end
    if not title and DocSettings:hasSidecarFile(path) then
        local props = DocSettings:open(path):readSetting("doc_props")
        if props then
            title, authors = props.title, props.authors
        end
    end
    local guessed_title, guessed_author = guessFromFileName(path)
    if not title or title == "" or PLACEHOLDER_TITLES[util.trim(title):lower()] then
        title = guessed_title
        authors = authors or guessed_author
    end
    return cleanTitle(title), firstAuthor(authors)
end

function Library:needsExtraction(info)
    if not self.bim then return false end
    if not info then return true end
    if info.unsupported or info.ignore_cover then return false end
    return not info.cover_fetched
        or (info.has_cover and self.bim.isCachedCoverInvalid(info, self.cover_specs))
end

local function isbnOf(path)
    if not DocSettings:hasSidecarFile(path) then return nil end
    local props = DocSettings:open(path):readSetting("doc_props")
    return props and Covers.isbn(props.identifiers)
end

--- Returns a list of book entries, each { path, title, author, mtime, read_time }.
function Library:collect(root)
    local paths = {}
    scan(root, 1, paths)

    local read_times = {}
    for _, item in ipairs(ReadHistory.hist) do
        read_times[item.file] = item.time
    end

    local books, to_extract, to_fetch = {}, {}, {}
    for _, path in ipairs(paths) do
        local info = self.bim and self.bim:getBookInfo(path, false)
        local title, author = self:readMeta(path, info)
        table.insert(books, {
            path = path,
            title = title,
            author = author,
            mtime = lfs.attributes(path, "modification") or 0,
            read_time = read_times[path],
        })
        -- Online lookups wait for extraction: they need its title and author.
        if self:needsExtraction(info) then
            table.insert(to_extract, { filepath = path, cover_specs = self.cover_specs })
        else
            local own_cover = info ~= nil and info.has_cover and not info.ignore_cover
            if Covers.wanted(path, own_cover) then
                table.insert(to_fetch, { path = path, title = title, author = author, isbn = isbnOf(path), own_cover = own_cover })
            end
        end
    end
    self.pending_extraction = to_extract
    self.pending_covers = to_fetch
    return books
end

local function byRead(a, b)
    if a.read_time and b.read_time then return a.read_time > b.read_time end
    if a.read_time or b.read_time then return a.read_time ~= nil end
    return a.mtime > b.mtime
end

local function byNew(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.title < b.title
end

function Library.sort(books, mode)
    table.sort(books, mode == "new" and byNew or byRead)
end

--- percent (0..1) or nil when never opened; finished true when marked complete.
function Library.progress(path)
    local info = BookList.getBookInfo(path)
    if not info.been_opened then return nil, false end
    return info.percent_finished, info.status == "complete"
end

local function bookStats(md5, max_sec)
    local conn = SQ3.open(STATS_DB)
    local ok, id, pages = pcall(conn.rowexec, conn,
        string.format("SELECT id, pages FROM book WHERE md5 = '%s' ORDER BY last_open DESC LIMIT 1;", md5))
    local read_pages, read_time
    if ok and id then
        ok, read_pages, read_time = pcall(conn.rowexec, conn, string.format(STATS_CAPPED_TOTALS, max_sec, tonumber(id)))
    end
    conn:close()
    if not (ok and pages and read_pages and read_time) then return nil end
    return tonumber(pages), tonumber(read_pages), tonumber(read_time)
end

--- Seconds left at this book's average page time from KOReader's reading statistics, or nil without enough data.
function Library.timeLeft(path, percent)
    if not percent or percent >= 1 then return nil end
    if lfs.attributes(STATS_DB, "mode") ~= "file" or not DocSettings:hasSidecarFile(path) then return nil end
    local md5 = DocSettings:open(path):readSetting("partial_md5_checksum")
    if not (md5 and md5:match("^%x+$")) then return nil end
    local max_sec = (G_reader_settings:readSetting("statistics") or {}).max_sec or STATS_DEFAULT_MAX_SEC
    local pages, read_pages, read_time = bookStats(md5, max_sec)
    if not pages or read_pages < STATS_MIN_PAGES then return nil end
    return (1 - percent) * pages * read_time / read_pages
end

--- The book's own cover, else the online one; scans the other way round.
function Library:cover(path)
    if Covers.prefersOnline(path) then
        local online = Covers.load(path)
        if online then return online end
    end
    local info = self.bim and self.bim:getBookInfo(path, true)
    if info and info.has_cover and not info.ignore_cover then
        return info.cover_bb
    end
    return Covers.load(path)
end

return Library
