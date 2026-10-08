--[[--
Writes highlights to files. Formats:

* md       one Markdown file, grouped by book in reading order
* obsidian a folder with one note per book (YAML front matter, #tags)
* txt      one plain-text file
* csv      UTF-8 with BOM so Excel shows CJK text correctly
* json     full data
--]]

local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Export = {}

Export.FORMATS = {
    { id = "md", text = _("Markdown"), hint = _(".md, one file"), ext = ".md" },
    { id = "obsidian", text = _("Obsidian"), hint = _("note per book"), ext = "/" },
    { id = "txt", text = _("Plain text"), hint = _(".txt"), ext = ".txt" },
    { id = "csv", text = _("CSV"), hint = _("spreadsheet"), ext = ".csv" },
    { id = "json", text = _("JSON"), hint = _("full data"), ext = ".json" },
}

function Export.format(id)
    for __, f in ipairs(Export.FORMATS) do
        if f.id == id then return f end
    end
    return Export.FORMATS[1]
end

-- Obsidian tags: no spaces or punctuation; "/" keeps nesting (a/b).
function Export.obsidianTag(name)
    local t = name:gsub("%s+", "-"):gsub("[#,%.;:'\"!%?%(%)%[%]{}<>|\\`~@%$%%%^&%*=%+]", "")
    t = t:gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    if t == "" then return nil end
    -- A tag cannot be purely numeric.
    if t:match("^[%d/]+$") then t = "_" .. t end
    return t
end

local function dateText(ts)
    return ts and ts > 0 and os.date("%Y-%m-%d %H:%M", ts) or ""
end

local function where(h, opts)
    local parts = {}
    if opts.page then
        if h.chapter and h.chapter ~= "" then table.insert(parts, h.chapter) end
        if h.pageref and h.pageref ~= "" then
            table.insert(parts, T(_("p. %1"), h.pageref))
        elseif h.pageno then
            table.insert(parts, T(_("p. %1"), h.pageno))
        end
    end
    if opts.date then table.insert(parts, dateText(h.ts)) end
    return table.concat(parts, " · ")
end

-- Group items by book, keeping reading order inside each book.
local function groupByBook(model, items)
    local list = {}
    for __, h in ipairs(items) do table.insert(list, h) end
    model:sort(list, "book")
    local groups, current = {}, nil
    for __, h in ipairs(list) do
        if not current or current.book_id ~= h.book_id then
            current = { book_id = h.book_id, book = h.book, items = {} }
            table.insert(groups, current)
        end
        table.insert(current.items, h)
    end
    return groups
end

local function authorsLine(book)
    return book and book.author_list and table.concat(book.author_list, ", ") or ""
end

local function quoteMd(text)
    return "> " .. text:gsub("\n", "\n> ")
end

local function buildMarkdown(model, items, opts)
    local out = { "# " .. _("Highlights"), "", T(_("Exported %1 · %2 highlights"), os.date("%Y-%m-%d"), #items), "" }
    for __, g in ipairs(groupByBook(model, items)) do
        table.insert(out, "## " .. (g.book and g.book.title or _("Unknown book")))
        local authors = authorsLine(g.book)
        if authors ~= "" then table.insert(out, "*" .. authors .. "*") end
        table.insert(out, "")
        for __, h in ipairs(g.items) do
            table.insert(out, quoteMd(h.text))
            local w = where(h, opts)
            if w ~= "" then
                table.insert(out, ">")
                table.insert(out, "> — " .. w)
            end
            table.insert(out, "")
            if opts.notes and h.note then
                table.insert(out, "**" .. _("Note:") .. "** " .. h.note)
                table.insert(out, "")
            end
            if opts.tags then
                local tags = {}
                for __, name in ipairs(model:tagNames(h)) do
                    local t = Export.obsidianTag(name)
                    if t then table.insert(tags, "#" .. t) end
                end
                if #tags > 0 then
                    table.insert(out, table.concat(tags, " "))
                    table.insert(out, "")
                end
            end
        end
    end
    return table.concat(out, "\n")
end

local function yamlString(s)
    return '"' .. tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ") .. '"'
end

local function buildObsidianNote(model, group, opts)
    local book = group.book
    local out = {
        "---",
        "title: " .. yamlString(book and book.title),
        "author: " .. yamlString(authorsLine(book)),
        "highlights: " .. #group.items,
        "exported: " .. os.date("%Y-%m-%d"),
        "tags:",
        "  - highlights",
        "---",
        "",
        "# " .. (book and book.title or _("Unknown book")),
        "",
    }
    for __, h in ipairs(group.items) do
        local w = where(h, opts)
        table.insert(out, "> [!quote]" .. (w ~= "" and (" " .. w) or ""))
        table.insert(out, quoteMd(h.text))
        table.insert(out, "")
        if opts.notes and h.note then
            table.insert(out, h.note)
            table.insert(out, "")
        end
        if opts.tags then
            local tags = {}
            for __, name in ipairs(model:tagNames(h)) do
                local t = Export.obsidianTag(name)
                if t then table.insert(tags, "#" .. t) end
            end
            if #tags > 0 then
                table.insert(out, table.concat(tags, " "))
                table.insert(out, "")
            end
        end
    end
    return table.concat(out, "\n")
end

local function buildText(model, items, opts)
    local out = {}
    for __, g in ipairs(groupByBook(model, items)) do
        local title = g.book and g.book.title or _("Unknown book")
        local authors = authorsLine(g.book)
        table.insert(out, authors ~= "" and (title .. " — " .. authors) or title)
        table.insert(out, string.rep("=", 40))
        table.insert(out, "")
        for __, h in ipairs(g.items) do
            table.insert(out, "“" .. h.text .. "”")
            local w = where(h, opts)
            if w ~= "" then table.insert(out, "(" .. w .. ")") end
            if opts.notes and h.note then
                table.insert(out, _("Note:") .. " " .. h.note)
            end
            if opts.tags then
                local names = model:tagNames(h)
                if #names > 0 then table.insert(out, _("Tags:") .. " " .. table.concat(names, ", ")) end
            end
            table.insert(out, "")
            table.insert(out, "---")
            table.insert(out, "")
        end
    end
    return table.concat(out, "\n")
end

local function csvField(v)
    v = tostring(v or "")
    if v:find('[,"\r\n]') then
        v = '"' .. v:gsub('"', '""') .. '"'
    end
    return v
end

local function buildCsv(model, items, opts)
    local header = { "book", "author", "text" }
    if opts.notes then table.insert(header, "note") end
    if opts.tags then table.insert(header, "tags") end
    if opts.page then
        table.insert(header, "chapter")
        table.insert(header, "page")
    end
    if opts.date then table.insert(header, "date") end
    local lines = { table.concat(header, ",") }
    for __, g in ipairs(groupByBook(model, items)) do
        for __, h in ipairs(g.items) do
            local row = {
                csvField(g.book and g.book.title),
                csvField(authorsLine(g.book)),
                csvField(h.text),
            }
            if opts.notes then table.insert(row, csvField(h.note)) end
            if opts.tags then table.insert(row, csvField(table.concat(model:tagNames(h), "; "))) end
            if opts.page then
                table.insert(row, csvField(h.chapter))
                table.insert(row, csvField(h.pageref or h.pageno))
            end
            if opts.date then table.insert(row, csvField(dateText(h.ts))) end
            table.insert(lines, table.concat(row, ","))
        end
    end
    return "\239\187\191" .. table.concat(lines, "\r\n") .. "\r\n"
end

local function buildJson(model, items, opts)
    local books = {}
    for __, g in ipairs(groupByBook(model, items)) do
        local entries = {}
        for __, h in ipairs(g.items) do
            local e = { text = h.text }
            if opts.notes then e.note = h.note end
            if opts.tags then e.tags = model:tagNames(h) end
            if opts.page then
                e.chapter = h.chapter
                e.page = h.pageref or h.pageno
            end
            if opts.date then e.datetime = h.datetime end
            table.insert(entries, e)
        end
        table.insert(books, {
            title = g.book and g.book.title,
            authors = g.book and g.book.author_list,
            file = g.book and g.book.file,
            highlights = entries,
        })
    end
    return rapidjson.encode({
        exported = os.date("%Y-%m-%dT%H:%M:%S"),
        count = #items,
        books = books,
    }, { pretty = true })
end

local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(data)
    f:close()
    return true
end

-- Default folder: <KOReader data dir>/data/HLexport, which on Android is
-- /storage/emulated/0/koreader/data/HLexport (works on Kobo/Kindle too).
function Export.defaultDir()
    return require("datastorage"):getFullDataDir() .. "/data/HLexport"
end

-- Base name for today's export, e.g. "highlights-2026-10-08".
function Export.baseName()
    return "highlights-" .. os.date("%Y-%m-%d")
end

function Export.targetPath(dir, fmt_id, base)
    local fmt = Export.format(fmt_id)
    base = base or Export.baseName()
    if fmt.ext == "/" then
        return dir .. "/" .. base
    end
    return dir .. "/" .. base .. fmt.ext
end

function Export.exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

-- A free name next to `path`: "...-2", "...-3", …
function Export.uniquePath(dir, fmt_id)
    local base = Export.baseName()
    local path = Export.targetPath(dir, fmt_id, base)
    local i = 2
    while Export.exists(path) do
        path = Export.targetPath(dir, fmt_id, base .. "-" .. i)
        i = i + 1
    end
    return path
end

--[[
opts = { format = id, notes, tags, page, date (booleans) }
Returns the written path, or nil + error message.
]]
function Export.write(model, items, path, opts)
    local dir = path:match("^(.*)/[^/]*$")
    if dir and dir ~= "" and lfs.attributes(dir, "mode") ~= "directory" then
        local ok, err = util.makePath(dir)
        if not ok then return nil, err end
    end
    if opts.format == "obsidian" then
        if lfs.attributes(path, "mode") ~= "directory" then
            local ok, err = util.makePath(path)
            if not ok then return nil, err end
        end
        for __, g in ipairs(groupByBook(model, items)) do
            local title = g.book and g.book.title or _("Unknown book")
            local authors = authorsLine(g.book)
            local name = authors ~= "" and (title .. " - " .. authors) or title
            name = util.getSafeFilename(name, path, 120) .. ".md"
            local ok, err = writeFile(path .. "/" .. name, buildObsidianNote(model, g, opts))
            if not ok then return nil, err end
        end
        return path
    end
    local data
    if opts.format == "txt" then
        data = buildText(model, items, opts)
    elseif opts.format == "csv" then
        data = buildCsv(model, items, opts)
    elseif opts.format == "json" then
        data = buildJson(model, items, opts)
    else
        data = buildMarkdown(model, items, opts)
    end
    local ok, err = writeFile(path, data)
    if not ok then return nil, err end
    return path
end

return Export
