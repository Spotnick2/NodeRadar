-- extract_gathermate.lua: the classic herb and ore node names, in every
-- language GatherMate2 translates, as a reference for the library (#19).
--
--   lua5.1 Tools/extract_gathermate.lua <GatherMate2 folder> [--write]
--
-- Reads GatherMate2's node table (Constants.lua) and its locale files; copies
-- nothing of GatherMate2 but the names, which are Blizzard's own (the owner's
-- call). Writes Tools/Reference/gathermate2.lua, an input to
-- Tools/export_nodes.lua in NodeRadar's SavedVariables shape. Every name
-- GatherMate2 maps to a node ships: its Retail name and its Vanilla one where
-- they differ (Forever's tooltips may use either; one that never shows is
-- harmless). Each name keeps GatherMate2's node ID (`node`), the key of
-- Tools/Reference/node-info.lua's skill and item (#26). tests/test_gathermate.lua
-- pins it.

local M = {}

M.KINDS = { ["Herb Gathering"] = "herbs", ["Mining"] = "ore" }
-- GatherMate2's IDs for the classic nodes: mining 201-220 and the AQ obsidian
-- chunks, herbs 401-431. Two it comments out are classic names all the same:
-- Hakkari Thorium Vein (Zul'Gurub) and Bloodvine (its Vanilla locales translate it).
M.CLASSIC = { ["Mining"] = { { 201, 220 }, { 225, 226 } }, ["Herb Gathering"] = { { 401, 431 } } }
M.COMMENTED = { ["Hakkari Thorium Vein"] = true, ["Bloodvine"] = true }
M.SKIP = { ["Swiftthistle"] = true, ["Wildvine"] = true }   -- loot from other nodes, not nodes
M.LOCALES = { "enUS", "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }

local function classic(dbType, id)
    for _, r in ipairs(M.CLASSIC[dbType]) do
        if id >= r[1] and id <= r[2] then return true end
    end
    return false
end

-- A line's braces, its strings and trailing comment left out: opened minus closed.
local function depth(line)
    local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
    local _, opened = code:gsub("{", "")
    local _, closed = code:gsub("}", "")
    return opened - closed
end

-- Constants.lua's text -> { { english, kind, id }, ... }, the classic nodes only.
-- An entry is `["Name"] = 201` or, from GatherMate2 1.52.5, a table over one or
-- more lines, `["Name"] = { id = 201, variants = { "Other name", ... }, old_ids = {...} }`:
-- each variant is the same node under another name (Forever's "Poor Copper Vein"),
-- so it ships with the base node's ID.
function M.parseNodes(text)
    -- section: nil outside a profession's table, its name inside one we read, false
    -- inside another (fishing, treasure).
    local out, section, entry = {}, nil, nil
    local function add(commented, name, id)
        id = tonumber(id)
        if section and name and id and classic(section, id) and not M.SKIP[name]
            and (commented == "" or M.COMMENTED[name]) then
            out[#out + 1] = { name, M.KINDS[section], id }
        end
    end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        if entry then
            -- A commented-out entry's lines are all commented: read through the marks.
            local code = entry.commented ~= "" and line:gsub("^%s*%-%-", "") or line
            entry.body = entry.body .. "\n" .. code
            entry.depth = entry.depth + depth(code)
        else
            local commented, name, rest = line:match('^%s*(%-*)%s*%["([^"]+)"%]%s*=%s*(.-)%s*$')
            if name and rest:match("^%d") then
                add(commented, name, rest:match("^%d+"))
            elseif name and rest:match("^{") and section == nil then
                if commented == "" then section = M.KINDS[name] and name or false end   -- a profession's table
            elseif name and rest:match("^{") then
                entry = { commented = commented, name = name, body = rest, depth = depth(rest) }
            elseif not name and section ~= nil and depth(line) < 0 then
                section = nil                                      -- the profession's table closed
            end
        end
        if entry and entry.depth <= 0 then
            local id = entry.body:match("id%s*=%s*(%d+)")
            add(entry.commented, entry.name, id)
            local variants = entry.body:match("variants%s*=%s*(%b{})")
            for variant in (variants or ""):gmatch('"([^"]+)"') do add(entry.commented, variant, id) end
            entry = nil
        end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
end

-- A locale file's text -> { [app] = { [key] = value } }: AceLocale's
-- NewLocale recorded, nothing else of it run.
function M.readLocale(text, name)
    local chunk, err = loadstring(text, name)
    if not chunk then error(err, 0) end
    local apps = {}
    local ace = { NewLocale = function(_, app)
        apps[app] = apps[app] or {}
        return apps[app]
    end }
    setfenv(chunk, { LibStub = function() return ace end })
    chunk()
    return apps
end

-- nodes, { [locale] = { NL = {...}, NLV = {...} } } -> learned, in the
-- SavedVariables shape, and the names two nodes share. enUS's `true` means
-- the key is the name. A name two nodes share keeps no ID: neither node's
-- skill can be said to be its.
function M.build(nodes, locales, build)
    local learned, shared = {}, {}
    for locale, t in pairs(locales) do
        local names, many = {}, {}
        for _, node in ipairs(nodes) do
            for _, tbl in ipairs({ t.NL or {}, t.NLV or {} }) do
                local v = tbl[node[1]]
                if v == true then v = node[1] end
                if type(v) == "string" and v ~= "" then
                    local e = names[v]
                    if not e then
                        names[v] = { kind = node[2], source = "gathermate2", build = build, node = node[3] }
                    elseif e.node ~= node[3] and not many[v] then
                        shared[#shared + 1] = ("%s %q: nodes %s and %d"):format(locale, v, tostring(e.node), node[3])
                        e.node, many[v] = nil, true
                    end
                end
            end
        end
        if next(names) then learned[locale] = names end
    end
    table.sort(shared)
    return learned, shared
end

function M.render(learned, build)
    local out = { ([[
-- Tools/Reference/gathermate2.lua: the classic herb and ore node names in every
-- language %s translates (#19). Generated by
-- Tools/extract_gathermate.lua; never loaded by the addon. The names are
-- Blizzard's; GatherMate2's code isn't copied.

NodeRadarDB = {
    learned = {
]]):format(build) }
    local locales = {}
    for locale in pairs(learned) do locales[#locales + 1] = locale end
    table.sort(locales)
    for _, locale in ipairs(locales) do
        out[#out + 1] = "        " .. locale .. " = {\n"
        local names = {}
        for name in pairs(learned[locale]) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local e = learned[locale][name]
            out[#out + 1] = ("            [%q] = { kind = %q, source = %q, build = %q%s },\n")
                :format(name, e.kind, e.source, e.build, e.node and (", node = " .. e.node) or "")
        end
        out[#out + 1] = "        },\n"
    end
    out[#out + 1] = "    },\n}\n"
    return table.concat(out)
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function M.main(args)
    local dir, write = nil, false
    for _, a in ipairs(args) do
        if a == "--write" then write = true else dir = a end
    end
    if not dir then
        io.stderr:write("usage: lua5.1 Tools/extract_gathermate.lua <GatherMate2 folder> [--write]\n")
        return 1
    end
    local toc = read(dir .. "/GatherMate2.toc") or ""
    local build = "GatherMate2 " .. (toc:match("## Version:%s*([^\r\n]+)") or "?")
    local nodes = M.parseNodes(assert(read(dir .. "/Constants.lua"), "no Constants.lua in " .. dir))
    local locales = {}
    for _, locale in ipairs(M.LOCALES) do
        local main = read(("%s/Locales/GatherMate2-%s.lua"):format(dir, locale))
        local vanilla = read(("%s/Locales/Vanilla/GatherMate2-Vanilla-%s.lua"):format(dir, locale))
        locales[locale] = {
            NL = main and M.readLocale(main, locale).GatherMate2Nodes,
            NLV = vanilla and M.readLocale(vanilla, locale).GatherMate2NodesVanilla,
        }
    end
    local learned, shared = M.build(nodes, locales, build)
    for _, s in ipairs(shared) do io.write("shared name, no node ID: " .. s .. "\n") end
    for _, locale in ipairs(M.LOCALES) do
        local n = 0
        for _ in pairs(learned[locale] or {}) do n = n + 1 end
        io.write(("%s: %d names\n"):format(locale, n))
    end
    io.write(("%d classic nodes from %s\n"):format(#nodes, build))
    if write then
        local f = assert(io.open("Tools/Reference/gathermate2.lua", "wb"))
        f:write(M.render(learned, build))
        f:close()
        io.write("wrote Tools/Reference/gathermate2.lua\n")
    end
    return 0
end

if arg and arg[0] and arg[0]:find("extract_gathermate") then os.exit(M.main(arg)) end
return M
