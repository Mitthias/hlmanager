--[[--
Keeps the SQLite index in step with KOReader's sidecar files.

* Only books whose sidecar changed since the last run are re-read (cheap stat
  per book), so opening the plugin does not re-parse every metadata file.
* The book currently open in the reader is indexed from memory, because its
  sidecar on disk is only written when the book is closed.
--]]

local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Indexer = {}

local function bookInfo()
    return require("apps/filemanager/filemanagerbookinfo")
end

-- "YYYY-MM-DD HH:MM:SS" -> epoch seconds
function Indexer.parseDatetime(s)
    if type(s) ~= "string" then return 0 end
    local y, mo, d, h, mi, se = s:match("^(%d+)%-(%d+)%-(%d+)%s+(%d+):(%d+):(%d+)")
    if not y then return 0 end
    return os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se) } or 0
end

-- Stable textual form of a highlight's start position, for identity only.
function Indexer.posKey(a)
    local p = a.pos0
    if type(p) == "string" then return p end
    if type(p) == "table" then
        return string.format("%s:%s:%s", tostring(p.page or a.page), tostring(p.x), tostring(p.y))
    end
    return tostring(a.page)
end

local function isHighlight(a)
    -- Page bookmarks (dog-ears) have no drawer; skip them.
    return a.drawer ~= nil and ((a.text and a.text ~= "") or (a.note and a.note ~= ""))
end

-- Turn a sidecar "annotations" array into index rows.
function Indexer.rowsFromAnnotations(md5, annotations)
    local rows, seen = {}, {}
    for i, a in ipairs(annotations or {}) do
        if isHighlight(a) then
            local poskey = Indexer.posKey(a)
            local key = md5 .. "|" .. tostring(a.datetime)
            if seen[key] then
                -- Two highlights created in the same second: disambiguate by position.
                key = key .. "|" .. poskey
            end
            seen[key] = true
            table.insert(rows, {
                hkey = key,
                pos = i,
                datetime = a.datetime,
                ts = Indexer.parseDatetime(a.datetime),
                text = util.cleanupSelectedText(a.text or ""),
                note = (a.note and a.note ~= "") and a.note or nil,
                chapter = a.chapter,
                pageno = tonumber(a.pageno),
                pageref = a.pageref and tostring(a.pageref) or nil,
                poskey = poskey,
            })
        end
    end
    return rows
end

local function authorsText(props)
    local a = props and props.authors
    if type(a) == "table" then a = table.concat(a, "\n") end
    return a
end

-- Index one closed book from its sidecar. Returns true if it was (re)indexed.
-- known_mtime: the indexed sidecar time (from Store:fileStates), if any.
function Indexer.indexFile(store, file, force, known_mtime)
    local sidecar = DocSettings:findSidecarFile(file)
    if not sidecar then return false end
    local mtime = lfs.attributes(sidecar, "modification")
    if known_mtime == nil and not force then
        local known = store:bookByFile(file)
        known_mtime = known and known.sidecar_mtime
    end
    if not force and known_mtime == mtime then
        return false
    end
    local ds = DocSettings:open(file)
    local annotations = ds:readSetting("annotations")
    if annotations == nil then
        -- Pre-2024 sidecar format: KOReader converts it the next time the book is opened.
        return false
    end
    local md5 = ds:readSetting("partial_md5_checksum")
    if not md5 and lfs.attributes(file, "mode") == "file" then
        md5 = util.partialMD5(file)
    end
    md5 = md5 or ("path:" .. file)
    local props = bookInfo().extendProps(ds:readSetting("doc_props"), file)
    local pages = ds:readSetting("doc_pages")
    store:replaceBook({
        md5 = md5,
        file = file,
        title = props.display_title,
        authors = authorsText(props),
        pages = tonumber(pages),
        sidecar_mtime = mtime,
    }, Indexer.rowsFromAnnotations(md5, annotations))
    return true
end

-- Index the book open in `ui` from memory.
function Indexer.indexOpenDocument(store, ui)
    if not (ui and ui.document and ui.annotation) then return end
    local file = ui.document.file
    local md5 = ui.doc_settings:readSetting("partial_md5_checksum") or util.partialMD5(file) or ("path:" .. file)
    local props = ui.doc_props or bookInfo().extendProps(ui.doc_settings:readSetting("doc_props"), file)
    local pages = ui.document.getPageCount and ui.document:getPageCount()
    local sidecar = DocSettings:findSidecarFile(file)
    store:replaceBook({
        md5 = md5,
        file = file,
        title = props.display_title or props.title,
        authors = authorsText(props),
        pages = tonumber(pages),
        -- Force a re-read from disk once the book has been closed and flushed.
        sidecar_mtime = sidecar and -1 or nil,
    }, Indexer.rowsFromAnnotations(md5, ui.annotation.annotations))
end

-- Books to look at: reading history (the same source KOReader's own
-- "Export all notes" uses), skipping entries whose file is gone.
local function candidateFiles()
    local files = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        for __, item in ipairs(ReadHistory.hist) do
            if item.file and not item.dim then
                table.insert(files, item.file)
            end
        end
    end
    return files
end

-- Number of history books whose sidecar changed since the last index.
function Indexer.pendingCount(store)
    local states = store:fileStates()
    local n = 0
    for __, file in ipairs(candidateFiles()) do
        local sidecar = DocSettings:findSidecarFile(file)
        if sidecar and states[file] ~= lfs.attributes(sidecar, "modification") then
            n = n + 1
        end
    end
    return n
end

function Indexer.syncAll(store, ui, force)
    local current = ui and ui.document and ui.document.file
    local states = store:fileStates()
    local updated = 0
    for __, file in ipairs(candidateFiles()) do
        if file ~= current then
            local ok, res = pcall(Indexer.indexFile, store, file, force, states[file] or false)
            if not ok then
                logger.warn("Highlights: could not index", file, res)
            elseif res then
                updated = updated + 1
            end
        end
    end
    if current then
        local ok, err = pcall(Indexer.indexOpenDocument, store, ui)
        if not ok then logger.warn("Highlights: could not index open book", err) end
    end
    return updated
end

return Indexer
