-- export_nodes.lua: merge the nodes learned in game into Data/Nodes.lua, the
-- library NodeRadar ships (docs/PLAN.md, "The library").
--
--   lua5.1 Tools/export_nodes.lua <SavedVariables/NodeRadar.lua>... [--data Data/Nodes.lua] [--write]
--
-- Prints every name it would add, with its source and build, for review; writes
-- only with --write. Nodes only (a learned "not a node" never ships). A name
-- with two kinds, across the inputs or against the library, is reported and left
-- out; an existing entry is never replaced. tests/test_export.lua pins it.

local M = {}

-- The client's GetLocale() values.
M.LOCALES = { enUS = true, enGB = true, deDE = true, frFR = true, esES = true, esMX = true, ptBR = true,
              ruRU = true, koKR = true, zhCN = true, zhTW = true, itIT = true }
M.KINDS = { herbs = true, ore = true }

-- A name without the client's escape codes: the same rule as Scan.Plain (a
-- SavedVariables file written before that rule still has them).
function M.plain(s)
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", ""):gsub("|n", " ")
    return (s:match("^%s*(.-)%s*$"))
end

-- Runs a Lua file in its own environment and returns that environment.
function M.load(path)
    local chunk, err = loadfile(path)
    if not chunk then error(err, 0) end
    local env = {}
    setfenv(chunk, env)
    chunk()
    return env
end

-- lib: { [locale] = { [name] = kind } }; inputs: { { file, learned = { [locale] = { [name] =
-- { kind, source, build } } } } }. Returns the merged library, what was added, and the conflicts.
function M.merge(lib, inputs)
    local out, added, conflicts, problems = {}, {}, {}, {}
    for locale, names in pairs(lib or {}) do
        out[locale] = {}
        for name, kind in pairs(names) do out[locale][name] = kind end
    end
    -- Every kind each name was learned as, across the inputs.
    local seen = {}
    for _, input in ipairs(inputs) do
        for locale, names in pairs(input.learned or {}) do
            if not M.LOCALES[locale] then
                problems[#problems + 1] = input.file .. ": unknown locale " .. tostring(locale)
            else
                for raw, e in pairs(names) do
                    local name = type(raw) == "string" and M.plain(raw) or ""
                    if type(e) == "table" and M.KINDS[e.kind] and name ~= "" then
                        seen[locale] = seen[locale] or {}
                        local s = seen[locale][name] or { kinds = {}, from = {} }
                        seen[locale][name] = s
                        s.kinds[e.kind] = true
                        s.from[#s.from + 1] = { kind = e.kind, source = e.source, build = e.build, file = input.file }
                    end
                end
            end
        end
    end
    for locale, names in pairs(seen) do
        for name, s in pairs(names) do
            local existing = out[locale] and out[locale][name]
            local kinds = {}
            for k in pairs(s.kinds) do kinds[#kinds + 1] = k end
            if existing then kinds[#kinds + 1] = existing end
            local distinct = {}
            for _, k in ipairs(kinds) do distinct[k] = true end
            local n = 0
            for _ in pairs(distinct) do n = n + 1 end
            if n > 1 then
                conflicts[#conflicts + 1] = { locale = locale, name = name, existing = existing, from = s.from }
            elseif not existing then
                out[locale] = out[locale] or {}
                out[locale][name] = kinds[1]
                added[#added + 1] = { locale = locale, name = name, kind = kinds[1], from = s.from }
            end
        end
    end
    local function order(a, b) return a.locale == b.locale and a.name < b.name or a.locale < b.locale end
    table.sort(added, order)
    table.sort(conflicts, order)
    return out, added, conflicts, problems
end

-- Each name's required skill and item (#26): an input entry's GatherMate2
-- `node` looked up in `info` (Tools/Reference/node-info.lua), for every name
-- of the merged library whose kind the entry agrees with, new or not. Rebuilt
-- whole on every run. Two different answers for one name: reported, left out.
-- Returns { [locale] = { [name] = { skill, item } } } and the conflicts.
function M.nodeInfo(lib, inputs, info)
    local found, conflicts = {}, {}
    for _, input in ipairs(inputs) do
        for locale, names in pairs(input.learned or {}) do
            for raw, e in pairs(names) do
                local name = type(raw) == "string" and M.plain(raw) or ""
                local i = type(e) == "table" and type(e.node) == "number" and info and info[e.node]
                if i and (i.skill or i.item) and lib[locale] and lib[locale][name] == e.kind then
                    found[locale] = found[locale] or {}
                    local per = found[locale][name] or {}
                    found[locale][name] = per
                    per[("%s:%s"):format(tostring(i.skill), tostring(i.item))] = { skill = i.skill, item = i.item }
                end
            end
        end
    end
    local out = {}
    for locale, names in pairs(found) do
        for name, per in pairs(names) do
            local keys = {}
            for k in pairs(per) do keys[#keys + 1] = k end
            if #keys == 1 then
                out[locale] = out[locale] or {}
                out[locale][name] = per[keys[1]]
            else
                table.sort(keys)
                conflicts[#conflicts + 1] = { locale = locale, name = name, values = keys }
            end
        end
    end
    table.sort(conflicts, function(a, b) return a.locale == b.locale and a.name < b.name or a.locale < b.locale end)
    return out, conflicts
end

local HEADER = [[
-- Data/Nodes.lua: gathering-node names, per GetLocale(): learned on Forever, and
-- the classic names of Tools/Reference (English #17, every language from
-- GatherMate2 #19); NODE_INFO, each name's required skill and item (#26).
-- Generated by Tools/export_nodes.lua from those inputs; edit with the tool.

NodeRadar = NodeRadar or {}
NodeRadar.LIBRARY = {
]]

-- The data file, sorted, so a re-run changes nothing.
function M.render(lib, nodeInfo)
    local locales = {}
    for locale in pairs(lib) do locales[#locales + 1] = locale end
    table.sort(locales)
    local out = { HEADER }
    for _, locale in ipairs(locales) do
        local names = {}
        for name in pairs(lib[locale]) do names[#names + 1] = name end
        table.sort(names)
        if #names > 0 then
            out[#out + 1] = "    " .. locale .. " = {\n"
            for _, name in ipairs(names) do
                out[#out + 1] = ("        [%q] = %q,\n"):format(name, lib[locale][name])
            end
            out[#out + 1] = "    },\n"
        end
    end
    out[#out + 1] = "}\n"
    if nodeInfo and next(nodeInfo) then
        out[#out + 1] = "\nNodeRadar.NODE_INFO = {\n"
        local infoLocales = {}
        for locale in pairs(nodeInfo) do infoLocales[#infoLocales + 1] = locale end
        table.sort(infoLocales)
        for _, locale in ipairs(infoLocales) do
            local names = {}
            for name in pairs(nodeInfo[locale]) do names[#names + 1] = name end
            table.sort(names)
            out[#out + 1] = "    " .. locale .. " = {\n"
            for _, name in ipairs(names) do
                local e, fields = nodeInfo[locale][name], {}
                if e.skill then fields[#fields + 1] = "skill = " .. e.skill end
                if e.item then fields[#fields + 1] = "item = " .. e.item end
                out[#out + 1] = ("        [%q] = { %s },\n"):format(name, table.concat(fields, ", "))
            end
            out[#out + 1] = "    },\n"
        end
        out[#out + 1] = "}\n"
    end
    return table.concat(out)
end

local function sources(from)
    local parts = {}
    for _, f in ipairs(from) do
        parts[#parts + 1] = ("%s by %s on %s (%s)"):format(f.kind, tostring(f.source), tostring(f.build), f.file)
    end
    return table.concat(parts, "; ")
end

-- Read on every run, besides the files given: NODE_INFO is rebuilt whole from
-- them, so an export of SavedVariables alone keeps it (Codex, #26).
M.REFERENCES = { "Tools/Reference/gathermate2.lua", "Tools/Reference/classic-enUS.lua",
                 "Tools/Reference/node-info.lua" }

function M.main(args)
    local data, write, files = "Data/Nodes.lua", false, {}
    local i = 1
    while i <= #args do
        if args[i] == "--data" then
            data, i = args[i + 1], i + 1
        elseif args[i] == "--write" then
            write = true
        else
            files[#files + 1] = args[i]
        end
        i = i + 1
    end
    if #files == 0 then
        io.write("usage: lua5.1 Tools/export_nodes.lua <SavedVariables/NodeRadar.lua>... [--data Data/Nodes.lua] [--write]\n")
        return 2
    end
    local lib = M.load(data).NodeRadar.LIBRARY
    local given = {}
    for _, f in ipairs(files) do given[(f:gsub("\\", "/"))] = true end
    for _, f in ipairs(M.REFERENCES) do
        if not given[f] then files[#files + 1] = f end
    end
    local inputs, info = {}, nil
    for _, f in ipairs(files) do
        local env = M.load(f)
        local db = env.NodeRadarDB
        if type(env.NodeRadarNodeInfo) == "table" then info = env.NodeRadarNodeInfo end
        inputs[#inputs + 1] = { file = f, learned = type(db) == "table" and db.learned or {} }
    end
    local merged, added, conflicts, problems = M.merge(lib, inputs)
    local nodeInfo, infoConflicts = M.nodeInfo(merged, inputs, info)
    for _, p in ipairs(problems) do io.write("skipped: " .. p .. "\n") end
    for _, a in ipairs(added) do io.write(("add %s %q = %s: %s\n"):format(a.locale, a.name, a.kind, sources(a.from))) end
    for _, c in ipairs(conflicts) do
        io.write(("CONFLICT %s %q (library: %s): %s\n"):format(c.locale, c.name, tostring(c.existing), sources(c.from)))
    end
    for _, c in ipairs(infoConflicts) do
        io.write(("INFO CONFLICT %s %q: %s\n"):format(c.locale, c.name, table.concat(c.values, " or ")))
    end
    local withInfo = 0
    for _, names in pairs(nodeInfo) do for _ in pairs(names) do withInfo = withInfo + 1 end end
    io.write(("%d to add, %d conflicts; %d names with a skill or item, %d info conflicts\n")
        :format(#added, #conflicts, withInfo, #infoConflicts))
    -- Written when anything changes: a name added, NODE_INFO, or the format (a new header).
    local text = M.render(merged, nodeInfo)
    local cur = io.open(data, "rb")
    local same = cur and cur:read("*a"):gsub("\r\n", "\n") == text
    if cur then cur:close() end
    if write and not same then
        local fh = assert(io.open(data, "wb"))
        fh:write(text)
        fh:close()
        io.write("wrote " .. data .. "\n")
    elseif not same then
        io.write("review the names above, then re-run with --write\n")
    end
    return 0
end

if arg and arg[0] and arg[0]:match("export_nodes%.lua$") then os.exit(M.main(arg)) end
return M
