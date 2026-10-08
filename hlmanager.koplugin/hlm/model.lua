--[[--
In-memory view of the index: filtering, sorting and summaries.

A filter is a plain table (so it can be saved in settings):
    books    = { [book_id] = true }   -- Source
    authors  = { [name] = true }      -- Author
    tags     = { [tag_id] = true }
    untagged = true|nil
    tag_mode = "any" | "all"
    time     = "all" | "7d" | "30d" | "year" | "range"
    from, to = epoch seconds (range only, inclusive days)
    search   = string|nil

Books and authors are one "source" dimension: a highlight matches when its
book OR its author is selected, so picking Thoreau and "Essays" never gives
an empty list by accident.
--]]

local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Model = {}
Model.__index = Model

function Model.new(store)
    local self = setmetatable({ store = store }, Model)
    self:reload()
    return self
end

local function splitAuthors(s)
    local list = {}
    if s and s ~= "" then
        for a in s:gmatch("[^\n]+") do
            a = util.trim(a)
            if a ~= "" then table.insert(list, a) end
        end
    end
    return list
end

function Model:reload()
    local data = self.store:loadAll()
    self.books = data.books
    self.items = data.items
    self.tags = data.tags
    self.tags_by_id = {}
    for __, t in ipairs(self.tags) do
        self.tags_by_id[t.id] = t
    end
    self.by_key = {}
    self.author_counts = {}
    for __, b in pairs(self.books) do
        b.count = 0
        b.author_list = splitAuthors(b.authors)
        b.title = b.title or _("Unknown book")
    end
    for __, h in ipairs(self.items) do
        local b = self.books[h.book_id]
        h.book = b
        if b then
            b.count = b.count + 1
            if h.pageno and b.pages and b.pages > 0 then
                h.percent = math.min(1, (h.pageno - 1) / b.pages)
            end
            for __, a in ipairs(b.author_list) do
                self.author_counts[a] = (self.author_counts[a] or 0) + 1
            end
        end
        self.by_key[h.key] = h
    end
    self.untagged_count = 0
    for __, h in ipairs(self.items) do
        if next(h.tag_ids) == nil then
            self.untagged_count = self.untagged_count + 1
        end
    end
end

function Model:total()
    return #self.items
end

function Model:get(key)
    return self.by_key[key]
end

function Model:tagNames(h)
    local names = {}
    for id in pairs(h.tag_ids) do
        local t = self.tags_by_id[id]
        if t then table.insert(names, t.name) end
    end
    table.sort(names, function(a, b) return util.stringLower(a) < util.stringLower(b) end)
    return names
end

-- Filtering -----------------------------------------------------------------

function Model.emptyFilter()
    return { tag_mode = "any", time = "all" }
end

function Model.copyFilter(f)
    f = f or Model.emptyFilter()
    local c = {}
    for k, v in pairs(f) do
        if type(v) == "table" then
            local t = {}
            for kk, vv in pairs(v) do t[kk] = vv end
            c[k] = t
        else
            c[k] = v
        end
    end
    c.tag_mode = c.tag_mode or "any"
    c.time = c.time or "all"
    return c
end

local function setSize(s)
    local n = 0
    if s then for _ in pairs(s) do n = n + 1 end end
    return n
end
Model.setSize = setSize

local function dayStart(ts)
    local t = os.date("*t", ts)
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }
end

function Model.timeBounds(f, now)
    now = now or os.time()
    if f.time == "7d" then
        return dayStart(now) - 6 * 86400, nil
    elseif f.time == "30d" then
        return dayStart(now) - 29 * 86400, nil
    elseif f.time == "year" then
        local t = os.date("*t", now)
        return os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }, nil
    elseif f.time == "range" then
        local from = f.from and dayStart(f.from) or nil
        local to = f.to and (dayStart(f.to) + 86399) or nil
        return from, to
    end
end

function Model:matcher(f)
    f = f or {}
    local n_books, n_authors = setSize(f.books), setSize(f.authors)
    local has_source = n_books + n_authors > 0
    local n_tags = setSize(f.tags)
    local has_tags = n_tags > 0 or f.untagged
    local from, to = Model.timeBounds(f)
    local search = f.search and f.search ~= "" and f.search or nil
    local tag_all = f.tag_mode == "all"

    return function(h)
        if has_source then
            local ok = f.books and f.books[h.book_id]
            if not ok and f.authors and h.book then
                for __, a in ipairs(h.book.author_list) do
                    if f.authors[a] then ok = true break end
                end
            end
            if not ok then return false end
        end
        if has_tags then
            local tagged = next(h.tag_ids) ~= nil
            local ok = f.untagged and not tagged
            if not ok and n_tags > 0 then
                if tag_all then
                    ok = true
                    for id in pairs(f.tags) do
                        if not h.tag_ids[id] then ok = false break end
                    end
                else
                    for id in pairs(f.tags) do
                        if h.tag_ids[id] then ok = true break end
                    end
                end
            end
            if not ok then return false end
        end
        if from and h.ts < from then return false end
        if to and h.ts > to then return false end
        if search then
            local hay = h.text
            if h.note then hay = hay .. "\n" .. h.note end
            if h.book then hay = hay .. "\n" .. h.book.title .. "\n" .. (h.book.authors or "") end
            if util.stringSearch(hay, search, false) == 0 then return false end
        end
        return true
    end
end

function Model:filter(f)
    local match = self:matcher(f)
    local out = {}
    for __, h in ipairs(self.items) do
        if match(h) then table.insert(out, h) end
    end
    return out
end

function Model:count(f)
    local match = self:matcher(f)
    local n = 0
    for __, h in ipairs(self.items) do
        if match(h) then n = n + 1 end
    end
    return n
end

function Model.isActive(f)
    if not f then return false end
    return setSize(f.books) + setSize(f.authors) + setSize(f.tags) > 0
        or f.untagged or (f.time and f.time ~= "all")
        or (f.search and f.search ~= "")
end

-- Sorting -------------------------------------------------------------------

Model.SORTS = {
    { id = "newest", text = _("Newest first") },
    { id = "oldest", text = _("Oldest first") },
    { id = "book", text = _("By book, in reading order") },
}

function Model:sort(list, mode)
    if mode == "oldest" then
        table.sort(list, function(a, b)
            if a.ts ~= b.ts then return a.ts < b.ts end
            return a.key < b.key
        end)
    elseif mode == "book" then
        local lower = util.stringLower
        table.sort(list, function(a, b)
            if a.book_id ~= b.book_id then
                local ba, bb = a.book, b.book
                local ka = ba and lower((ba.author_list[1] or "") .. "\0" .. ba.title) or ""
                local kb = bb and lower((bb.author_list[1] or "") .. "\0" .. bb.title) or ""
                if ka ~= kb then return ka < kb end
                return (a.book_id or 0) < (b.book_id or 0)
            end
            -- KOReader keeps each book's annotations in position order.
            return a.pos < b.pos
        end)
    else
        table.sort(list, function(a, b)
            if a.ts ~= b.ts then return a.ts > b.ts end
            return a.key > b.key
        end)
    end
    return list
end

-- Lists for the filter screens ------------------------------------------------

function Model:bookList()
    local list = {}
    for __, b in pairs(self.books) do
        if b.count > 0 then table.insert(list, b) end
    end
    local lower = util.stringLower
    table.sort(list, function(a, b)
        local ka = lower((a.author_list[1] or "\u{FFFF}") .. "\0" .. a.title)
        local kb = lower((b.author_list[1] or "\u{FFFF}") .. "\0" .. b.title)
        return ka < kb
    end)
    return list
end

function Model:authorList()
    local list = {}
    for name, count in pairs(self.author_counts) do
        table.insert(list, { name = name, count = count })
    end
    local lower = util.stringLower
    table.sort(list, function(a, b) return lower(a.name) < lower(b.name) end)
    return list
end

function Model:tagList(mode)
    local list = {}
    for __, t in ipairs(self.tags) do table.insert(list, t) end
    local lower = util.stringLower
    if mode == "az" then
        table.sort(list, function(a, b) return lower(a.name) < lower(b.name) end)
    elseif mode == "recent" then
        table.sort(list, function(a, b)
            local ua, ub = math.max(a.used_at, a.created_at), math.max(b.used_at, b.created_at)
            if ua ~= ub then return ua > ub end
            return lower(a.name) < lower(b.name)
        end)
    else
        table.sort(list, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return lower(a.name) < lower(b.name)
        end)
    end
    return list
end

-- Summaries for chips ---------------------------------------------------------

local TIME_LABELS = {
    all = _("All"), ["7d"] = _("7 days"), ["30d"] = _("30 days"), year = _("Year"), range = _("Range"),
}
Model.TIME_ORDER = { "all", "7d", "30d", "year", "range" }
Model.TIME_LABELS = TIME_LABELS

local function firstKey(s)
    for k in pairs(s) do return k end
end

function Model:sourceLabel(f)
    local n = setSize(f.books)
    if n == 0 then return nil end
    if n == 1 then
        local b = self.books[firstKey(f.books)]
        return b and b.title or T(_("Books: %1"), 1)
    end
    return T(_("Books: %1"), n)
end

function Model:authorLabel(f)
    local n = setSize(f.authors)
    if n == 0 then return nil end
    if n == 1 then return firstKey(f.authors) end
    return T(_("Authors: %1"), n)
end

function Model:tagLabel(f)
    local n = setSize(f.tags) + (f.untagged and 1 or 0)
    if n == 0 then return nil end
    if n == 1 then
        if f.untagged then return _("Untagged") end
        local t = self.tags_by_id[firstKey(f.tags)]
        return t and T(_("Tag: %1"), t.name) or T(_("Tags: %1"), 1)
    end
    return T(_("Tags: %1"), n)
end

function Model:timeLabel(f)
    if not f.time or f.time == "all" then return nil end
    if f.time == "range" then
        local a = f.from and os.date("%Y-%m-%d", f.from) or "…"
        local b = f.to and os.date("%Y-%m-%d", f.to) or "…"
        return a .. " – " .. b
    end
    return TIME_LABELS[f.time]
end

-- Deterministic text form of a filter (identifies a Vagary draw).
function Model.signature(f)
    f = f or {}
    local parts = {}
    local function addSet(name, s)
        local keys = {}
        for k in pairs(s or {}) do table.insert(keys, tostring(k)) end
        table.sort(keys)
        table.insert(parts, name .. "=" .. table.concat(keys, ","))
    end
    addSet("b", f.books)
    addSet("a", f.authors)
    addSet("t", f.tags)
    table.insert(parts, "u=" .. tostring(f.untagged and 1 or 0))
    table.insert(parts, "m=" .. tostring(f.tag_mode or "any"))
    table.insert(parts, "time=" .. tostring(f.time or "all") .. ":" .. tostring(f.from) .. ":" .. tostring(f.to))
    return table.concat(parts, ";")
end

return Model
