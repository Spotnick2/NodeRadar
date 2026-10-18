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
eq(X.render(lib), text, "Data/Nodes.lua is in the tool's own format")
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
eq(lib.deDE, nil, "English only: the other languages learn as they go")

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

done("test_export")
