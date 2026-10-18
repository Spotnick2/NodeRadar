-- Tools/export_nodes.lua: the merge into the shipped library, its conflicts,
-- and a data file a re-run doesn't change.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local X = dofile("Tools/export_nodes.lua")

-- The shipped file is exactly what the tool writes (a re-run changes nothing).
local env = X.load("Data/Nodes.lua")
local lib = env.NodeRadar.LIBRARY
local fh = assert(io.open("Data/Nodes.lua", "rb"))
local text = fh:read("*a"):gsub("\r\n", "\n")
fh:close()
local info = env.NodeRadar.NODE_INFO
eq(X.render(lib, info), text, "Data/Nodes.lua is in the tool's own format")
for locale, names in pairs(lib) do
    check(X.LOCALES[locale], "a client locale: " .. locale)
    for name, kind in pairs(names) do check(X.KINDS[kind], name .. " is herbs or ore") end
end

-- What ships (#17): the classic names of Tools/Reference, all of them in, and
-- the doubtful ones left out.
local ref = X.load("Tools/Reference/classic-enUS.lua").NodeRadarDB.learned
local _, missing = X.merge(lib, { { file = "reference", learned = ref } })
eq(#missing, 0, "every reference name is in the shipped library")
local count = 0
for _ in pairs(lib.enUS) do count = count + 1 end
check(count >= 50, "the shipped library knows the classic nodes (" .. count .. " enUS)")
eq(lib.enUS["Copper Vein"], "ore", "...ore too")
eq(lib.enUS["Black Lotus"], "herbs", "...to the end")
eq(lib.enUS["Wilted Peacebloom"], "herbs", "...and the Forever starter herbs")
for _, doubtful in ipairs({ "Beached Sea Creature", "Skeletal Sea Turtle", "Incendia Agave", "Violet Tragan" }) do
    eq(lib.enUS[doubtful], nil, "left out as doubtful: " .. doubtful)
end
-- And every language GatherMate2 translates (#19), all of it in.
local gm = X.load("Tools/Reference/gathermate2.lua").NodeRadarDB.learned
local _, gmMissing = X.merge(lib, { { file = "gathermate2", learned = gm } })
eq(#gmMissing, 0, "every GatherMate2 name is in the shipped library")
for _, locale in ipairs({ "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
    check(lib[locale] and next(lib[locale]), "names for " .. locale)
end
eq(lib.deDE["Kupfervorkommen"], "ore", "deDE: the Vanilla name")
eq(lib.deDE["Kupferader"], "ore", "...and the Retail one")
eq(lib.enUS["Bloodvine"], "herbs", "Bloodvine, which the English reference missed")

-- Each name's skill and item (#26), joined by GatherMate2's node ID, in every language.
local function same(e, skill, item, what)
    eq(e and e.skill, skill, what .. ": skill")
    eq(e and e.item, item, what .. ": item")
end
same(info.enUS["Mageroyal"], 50, 785, "Mageroyal (measured: refused at 25)")
same(info.frFR["Mage royal"], 50, 785, "...in French")
same(info.enUS["Copper Vein"], 1, 2770, "Copper Vein")
same(info.deDE["Kupferader"], 1, 2770, "...its Retail German name")
same(info.deDE["Kupfervorkommen"], 1, 2770, "...and its Vanilla one")
same(info.deDE["Brühschlammbedecktes Silbervorkommen"], 75, 2775, "an ooze-covered vein, its own entry")
same(info.enUS["Black Lotus"], 300, 13468, "Black Lotus")
eq(info.enUS["Hakkari Thorium Vein"], nil, "only the English reference names it, without an ID: no entry")
eq(info.enUS["Bloodvine"], nil, "nothing known: no entry")
eq(info.enUS["Wilted Peacebloom"], nil, "Forever's own herb: no entry")
for locale, names in pairs(info) do
    for name in pairs(names) do check(lib[locale] and lib[locale][name], "info only for library names: " .. name) end
end

-- Two accounts' learned names, against the small library behaviour tests use.
local a = { file = "a.lua", learned = { enUS = {
    ["Earthroot"] = { kind = "herbs", source = "toggle", build = "70450" },
    ["Copper Vein"] = { kind = "ore", source = "gather", build = "70450" },
    ["Carry Your Weight"] = { kind = false, source = "toggle", build = "70450" },
    ["Silverleaf"] = { kind = "ore", source = "toggle", build = "70450" },          -- against the library
    ["Mageroyal"] = { kind = "herbs", source = "gather", build = "70450" },
    -- Saved before the escape codes came out: the same node as the clean name.
    ["|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:16:32|tCopper Vein"] =
        { kind = "ore", source = "toggle", build = "70450" },
} } }
local b = { file = "b.lua", learned = {
    enUS = {
        ["Earthroot"] = { kind = "herbs", source = "gather", build = "70451" },     -- agrees
        ["Mageroyal"] = { kind = "ore", source = "toggle", build = "70451" },       -- disagrees
    },
    deDE = { ["Friedensblume"] = { kind = "herbs", source = "gather", build = "70450" } },
    xxXX = { ["Nope"] = { kind = "herbs" } },
} }
local merged, added, conflicts, problems = X.merge(TEST_LIBRARY, { a, b })

local addedNames = {}
for _, x in ipairs(added) do addedNames[x.locale .. "/" .. x.name] = x.kind end
eq(addedNames["enUS/Earthroot"], "herbs", "a node both accounts agree on is added")
eq(addedNames["enUS/Copper Vein"], "ore", "an ore")
eq(addedNames["deDE/Friedensblume"], "herbs", "another locale")
eq(addedNames["enUS/Carry Your Weight"], nil, "'not a node' never ships")
eq(addedNames["enUS/Mageroyal"], nil, "two kinds across the inputs: left out")
eq(merged.enUS["Silverleaf"], "herbs", "a conflict with the library keeps the library's entry")
eq(merged.enUS["Wilted Peacebloom"], "herbs", "the library's other entries kept")
eq(merged.xxXX, nil, "an unknown locale is skipped")
check(problems[1] and problems[1]:find("unknown locale xxXX"), "...and reported")
local c = {}
for _, x in ipairs(conflicts) do c[x.name] = x end
check(c.Mageroyal and #c.Mageroyal.from == 2, "the Mageroyal conflict, with both sources")
check(c.Silverleaf and c.Silverleaf.existing == "herbs", "the Silverleaf conflict, with the library's kind")
eq(#added, 3, "three added (the arrow-prefixed Copper Vein merged into the clean one)")
for _, x in ipairs(added) do check(not x.name:find("|", 1, true), "no escape code ships: " .. x.name) end
eq(added[1].from[1].source ~= nil, true, "every addition carries its source for review")

-- The written file loads back to the same library, names quoted safely.
merged.enUS['Odd "Quoted"\\Name'] = "herbs"
local again = loadstring(X.render(merged))
local env2 = {}
setfenv(again, env2)
again()
eq(env2.NodeRadar.LIBRARY.enUS['Odd "Quoted"\\Name'], "herbs", "a name with quotes and backslashes survives")
eq(env2.NodeRadar.LIBRARY.deDE.Friedensblume, "herbs", "...and the rest")
eq(X.render(env2.NodeRadar.LIBRARY), X.render(merged), "rendering is stable")

-- The join (#26): by node ID, for every name of the merged library whose kind agrees.
local ids = { [401] = { skill = 1, item = 2447 }, [404] = { skill = 50, item = 785 }, [999] = {} }
local small = { enUS = { ["Peacebloom"] = "herbs", ["Mageroyal"] = "herbs", ["Lone"] = "herbs" },
                frFR = { ["Pacifique"] = "herbs", ["Mage royal"] = "ore" } }
local gmIn = { file = "gm", learned = {
    enUS = { ["Peacebloom"] = { kind = "herbs", node = 401 }, ["Mageroyal"] = { kind = "herbs", node = 404 },
             ["Lone"] = { kind = "herbs", node = 999 }, ["Absent"] = { kind = "herbs", node = 401 } },
    frFR = { ["Pacifique"] = { kind = "herbs", node = 401 }, ["Mage royal"] = { kind = "herbs", node = 404 } },
} }
local svIn = { file = "sv", learned = { enUS = { ["Peacebloom"] = { kind = "herbs", source = "gather" } } } }
local ni, niConflicts = X.nodeInfo(small, { svIn, gmIn }, ids)
same(ni.enUS["Peacebloom"], 1, 2447, "a library name enriched")
same(ni.frFR["Pacifique"], 1, 2447, "...in another locale, by the same ID")
eq(ni.frFR["Mage royal"], nil, "the library's kind disagrees: no info")
eq(ni.enUS["Lone"], nil, "an ID with nothing known: no entry")
eq(ni.enUS["Absent"], nil, "a name not in the library: no entry")
eq(#niConflicts, 0, "no conflict yet")
local other = { file = "other", learned = { enUS = { ["Peacebloom"] = { kind = "herbs", node = 404 } } } }
local ni2, niConflicts2 = X.nodeInfo(small, { gmIn, other }, ids)
eq(ni2.enUS["Peacebloom"], nil, "two different answers for a name: left out")
check(niConflicts2[1] and niConflicts2[1].name == "Peacebloom", "...and reported")
same(ni2.enUS["Mageroyal"], 50, 785, "...the others kept")
local ni3 = X.nodeInfo(small, { svIn }, ids)
eq(next(ni3), nil, "SavedVariables alone carry no node ID: no info from them")
local env3 = {}
local again3 = loadstring(X.render(small, ni))
setfenv(again3, env3)
again3()
same(env3.NodeRadar.NODE_INFO.enUS["Peacebloom"], 1, 2447, "NODE_INFO loads back")
eq(X.render(env3.NodeRadar.LIBRARY, env3.NodeRadar.NODE_INFO), X.render(small, ni), "...rendering is stable")

-- The wrapper's export, SavedVariables only, from the shipped file: NODE_INFO
-- survives (the references are read on every run), and nothing changes.
local tmp = os.tmpname()
local out = assert(io.open(tmp, "wb"))
out:write(text)
out:close()
local sv = os.tmpname()
local svf = assert(io.open(sv, "wb"))
svf:write('NodeRadarDB = { learned = { enUS = { ["Odd New Herb"] = { kind = "herbs", source = "gather", build = "70450" } } } }\n')
svf:close()
local realWrite = io.write
io.write = function() end
X.main({ sv, "--data", tmp, "--write" })
io.write = realWrite
local after = X.load(tmp).NodeRadar
same(after.NODE_INFO.enUS["Mageroyal"], 50, 785, "a SavedVariables-only export keeps NODE_INFO")
eq(after.LIBRARY.enUS["Odd New Herb"], "herbs", "...adds the new name")
eq(after.NODE_INFO.enUS["Odd New Herb"], nil, "...which has no info")
os.remove(tmp)
os.remove(sv)

done("test_export")
