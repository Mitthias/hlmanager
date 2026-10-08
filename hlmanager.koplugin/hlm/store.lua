--[[--
SQLite index of highlights across all books, plus the plugin's own data
(tags and Vagary history), which KOReader's sidecar files have no place for.

KOReader stays the source of truth for highlight text and notes: each book's
rows are replaced wholesale whenever its sidecar changes. Tags are keyed by a
stable highlight key (book checksum + creation time), so they survive
re-indexing, renaming or moving the book.
--]]

local SQ3 = require("lua-ljsqlite3/init")

local SCHEMA_VERSION = 1

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS book (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        md5           TEXT UNIQUE,
        file          TEXT,
        title         TEXT,
        authors       TEXT,
        pages         INTEGER,
        sidecar_mtime INTEGER,
        indexed_at    INTEGER
    )]],
    [[CREATE INDEX IF NOT EXISTS book_file ON book(file)]],
    [[CREATE TABLE IF NOT EXISTS highlight (
        hkey      TEXT PRIMARY KEY,
        book_id   INTEGER NOT NULL,
        pos       INTEGER,
        datetime  TEXT,
        ts        INTEGER,
        text      TEXT,
        note      TEXT,
        chapter   TEXT,
        pageno    INTEGER,
        pageref   TEXT,
        poskey    TEXT
    )]],
    [[CREATE INDEX IF NOT EXISTS highlight_book ON highlight(book_id)]],
    [[CREATE TABLE IF NOT EXISTS tag (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
        created_at INTEGER,
        used_at    INTEGER
    )]],
    [[CREATE TABLE IF NOT EXISTS highlight_tag (
        hkey   TEXT NOT NULL,
        tag_id INTEGER NOT NULL,
        PRIMARY KEY (hkey, tag_id)
    )]],
    [[CREATE INDEX IF NOT EXISTS highlight_tag_tag ON highlight_tag(tag_id)]],
    [[CREATE TABLE IF NOT EXISTS vagary_seen (
        sig  TEXT NOT NULL,
        hkey TEXT NOT NULL,
        PRIMARY KEY (sig, hkey)
    )]],
}

local function num(v)
    return v ~= nil and tonumber(v) or nil
end

local function str(v)
    if v == nil then return nil end
    return tostring(v)
end

local Store = {}
Store.__index = Store

function Store.new(path)
    local self = setmetatable({ path = path }, Store)
    self:_init()
    return self
end

function Store:_open()
    local conn = SQ3.open(self.path)
    conn:set_busy_timeout(2000)
    return conn
end

-- Run fn(conn) inside a transaction, always closing the connection.
function Store:_tx(fn)
    local conn = self:_open()
    conn:exec("BEGIN")
    local ok, res = pcall(fn, conn)
    if ok then
        conn:exec("COMMIT")
    else
        pcall(conn.exec, conn, "ROLLBACK")
    end
    conn:close()
    if not ok then error(res, 0) end
    return res
end

function Store:_read(fn)
    local conn = self:_open()
    local ok, res = pcall(fn, conn)
    conn:close()
    if not ok then error(res, 0) end
    return res
end

function Store:_init()
    local conn = self:_open()
    conn:exec("PRAGMA journal_mode=TRUNCATE")
    local version = num(conn:rowexec("PRAGMA user_version")) or 0
    if version < SCHEMA_VERSION then
        for __, stmt in ipairs(SCHEMA) do
            conn:exec(stmt)
        end
        conn:exec("PRAGMA user_version=" .. SCHEMA_VERSION)
    end
    conn:close()
end

-- Books ---------------------------------------------------------------------

-- Returns { id, md5, sidecar_mtime } for the book stored at this path, if any.
function Store:bookByFile(file)
    return self:_read(function(conn)
        local stmt = conn:prepare("SELECT id, md5, sidecar_mtime FROM book WHERE file = ?")
        local row = stmt:reset():bind(file):step()
        stmt:close()
        if row then
            return { id = num(row[1]), md5 = str(row[2]), sidecar_mtime = num(row[3]) }
        end
    end)
end

-- { [file] = sidecar_mtime } for every indexed book, in one query.
function Store:fileStates()
    return self:_read(function(conn)
        local states = {}
        local stmt = conn:prepare("SELECT file, sidecar_mtime FROM book WHERE file IS NOT NULL")
        for row in stmt:rows() do
            states[str(row[1])] = num(row[2]) or false
        end
        stmt:close()
        return states
    end)
end

--[[
Replace all highlights of one book.
book = { md5, file, title, authors, pages, sidecar_mtime }
items = array of { hkey, pos, datetime, ts, text, note, chapter, pageno, pageref, poskey }
]]
function Store:replaceBook(book, items)
    return self:_tx(function(conn)
        local find = conn:prepare("SELECT id FROM book WHERE md5 = ?")
        local row = find:reset():bind(book.md5):step()
        find:close()
        local book_id
        if row then
            book_id = num(row[1])
            local upd = conn:prepare([[UPDATE book SET file = ?, title = ?, authors = ?, pages = ?,
                sidecar_mtime = ?, indexed_at = ? WHERE id = ?]])
            upd:reset():bind(book.file, book.title, book.authors, book.pages,
                book.sidecar_mtime, os.time(), book_id):step()
            upd:close()
        else
            local ins = conn:prepare([[INSERT INTO book (md5, file, title, authors, pages, sidecar_mtime, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)]])
            ins:reset():bind(book.md5, book.file, book.title, book.authors, book.pages,
                book.sidecar_mtime, os.time()):step()
            ins:close()
            book_id = num(conn:rowexec("SELECT last_insert_rowid()"))
        end
        -- Another book row may still claim this path (file replaced by a new edition).
        local clear = conn:prepare("UPDATE book SET file = NULL WHERE file = ? AND id != ?")
        clear:reset():bind(book.file, book_id):step()
        clear:close()

        local del = conn:prepare("DELETE FROM highlight WHERE book_id = ?")
        del:reset():bind(book_id):step()
        del:close()
        local ins = conn:prepare([[INSERT OR REPLACE INTO highlight
            (hkey, book_id, pos, datetime, ts, text, note, chapter, pageno, pageref, poskey)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]])
        for __, h in ipairs(items) do
            ins:reset():bind(h.hkey, book_id, h.pos, h.datetime, h.ts, h.text, h.note,
                h.chapter, h.pageno, h.pageref, h.poskey):step()
        end
        ins:close()
        return book_id
    end)
end

-- Loading -------------------------------------------------------------------

-- Returns books (by id), highlights (array) and tags (array) in one go.
function Store:loadAll()
    return self:_read(function(conn)
        local books = {}
        local stmt = conn:prepare("SELECT id, md5, file, title, authors, pages FROM book")
        for row in stmt:rows() do
            local id = num(row[1])
            books[id] = {
                id = id, md5 = str(row[2]), file = str(row[3]), title = str(row[4]),
                authors = str(row[5]), pages = num(row[6]),
            }
        end
        stmt:close()

        local tags, tags_by_id = {}, {}
        stmt = conn:prepare("SELECT id, name, created_at, used_at FROM tag")
        for row in stmt:rows() do
            local t = { id = num(row[1]), name = str(row[2]), created_at = num(row[3]) or 0,
                used_at = num(row[4]) or 0, count = 0 }
            table.insert(tags, t)
            tags_by_id[t.id] = t
        end
        stmt:close()

        local items, by_key = {}, {}
        stmt = conn:prepare([[SELECT hkey, book_id, pos, datetime, ts, text, note, chapter,
            pageno, pageref, poskey FROM highlight]])
        for row in stmt:rows() do
            local h = {
                key = str(row[1]), book_id = num(row[2]), pos = num(row[3]) or 0,
                datetime = str(row[4]), ts = num(row[5]) or 0, text = str(row[6]) or "",
                note = str(row[7]), chapter = str(row[8]), pageno = num(row[9]),
                pageref = str(row[10]), poskey = str(row[11]), tag_ids = {},
            }
            table.insert(items, h)
            by_key[h.key] = h
        end
        stmt:close()

        stmt = conn:prepare("SELECT hkey, tag_id FROM highlight_tag")
        for row in stmt:rows() do
            local h = by_key[str(row[1])]
            local t = tags_by_id[num(row[2])]
            if h and t then
                h.tag_ids[t.id] = true
                t.count = t.count + 1
            end
        end
        stmt:close()
        return { books = books, items = items, tags = tags }
    end)
end

-- Tags ----------------------------------------------------------------------

-- Returns the tag id, creating the tag if needed. Names are case-insensitive.
function Store:ensureTag(name)
    return self:_tx(function(conn)
        local find = conn:prepare("SELECT id FROM tag WHERE name = ?")
        local row = find:reset():bind(name):step()
        find:close()
        if row then return num(row[1]) end
        local ins = conn:prepare("INSERT INTO tag (name, created_at, used_at) VALUES (?, ?, ?)")
        ins:reset():bind(name, os.time(), 0):step()
        ins:close()
        return num(conn:rowexec("SELECT last_insert_rowid()"))
    end)
end

function Store:tagIdByName(name)
    return self:_read(function(conn)
        local find = conn:prepare("SELECT id FROM tag WHERE name = ?")
        local row = find:reset():bind(name):step()
        find:close()
        return row and num(row[1]) or nil
    end)
end

function Store:renameTag(tag_id, name)
    self:_tx(function(conn)
        local upd = conn:prepare("UPDATE tag SET name = ? WHERE id = ?")
        upd:reset():bind(name, tag_id):step()
        upd:close()
    end)
end

-- Move every highlight from one tag to another, then drop the source tag.
function Store:mergeTag(from_id, into_id)
    self:_tx(function(conn)
        local copy = conn:prepare([[INSERT OR IGNORE INTO highlight_tag (hkey, tag_id)
            SELECT hkey, ? FROM highlight_tag WHERE tag_id = ?]])
        copy:reset():bind(into_id, from_id):step()
        copy:close()
        local del = conn:prepare("DELETE FROM highlight_tag WHERE tag_id = ?")
        del:reset():bind(from_id):step()
        del:close()
        del = conn:prepare("DELETE FROM tag WHERE id = ?")
        del:reset():bind(from_id):step()
        del:close()
        local upd = conn:prepare("UPDATE tag SET used_at = ? WHERE id = ?")
        upd:reset():bind(os.time(), into_id):step()
        upd:close()
    end)
end

function Store:deleteTag(tag_id)
    self:_tx(function(conn)
        local del = conn:prepare("DELETE FROM highlight_tag WHERE tag_id = ?")
        del:reset():bind(tag_id):step()
        del:close()
        del = conn:prepare("DELETE FROM tag WHERE id = ?")
        del:reset():bind(tag_id):step()
        del:close()
    end)
end

-- add/remove: arrays of tag ids, applied to every key in `keys`.
function Store:updateTags(keys, add, remove)
    self:_tx(function(conn)
        local ins = conn:prepare("INSERT OR IGNORE INTO highlight_tag (hkey, tag_id) VALUES (?, ?)")
        local del = conn:prepare("DELETE FROM highlight_tag WHERE hkey = ? AND tag_id = ?")
        for __, key in ipairs(keys) do
            for __, id in ipairs(add or {}) do
                ins:reset():bind(key, id):step()
            end
            for __, id in ipairs(remove or {}) do
                del:reset():bind(key, id):step()
            end
        end
        ins:close()
        del:close()
        if add and #add > 0 then
            local upd = conn:prepare("UPDATE tag SET used_at = ? WHERE id = ?")
            for __, id in ipairs(add) do
                upd:reset():bind(os.time(), id):step()
            end
            upd:close()
        end
    end)
end

function Store:forgetHighlight(key)
    self:_tx(function(conn)
        local del = conn:prepare("DELETE FROM highlight_tag WHERE hkey = ?")
        del:reset():bind(key):step()
        del:close()
        del = conn:prepare("DELETE FROM highlight WHERE hkey = ?")
        del:reset():bind(key):step()
        del:close()
        del = conn:prepare("DELETE FROM vagary_seen WHERE hkey = ?")
        del:reset():bind(key):step()
        del:close()
    end)
end

-- Vagary --------------------------------------------------------------------
-- "Seen" keys per filter signature, so no highlight repeats until all in
-- that draw have been shown — across restarts too.

function Store:seenKeys(sig)
    return self:_read(function(conn)
        local seen = {}
        local stmt = conn:prepare("SELECT hkey FROM vagary_seen WHERE sig = ?")
        stmt:bind(sig)
        for row in stmt:rows() do
            seen[str(row[1])] = true
        end
        stmt:close()
        return seen
    end)
end

function Store:markSeen(sig, key)
    self:_tx(function(conn)
        local ins = conn:prepare("INSERT OR IGNORE INTO vagary_seen (sig, hkey) VALUES (?, ?)")
        ins:reset():bind(sig, key):step()
        ins:close()
    end)
end

function Store:clearSeen(sig)
    self:_tx(function(conn)
        local del = conn:prepare("DELETE FROM vagary_seen WHERE sig = ?")
        del:reset():bind(sig):step()
        del:close()
    end)
end

return Store
