-- Tools/extract_gathermate.lua: the classic nodes from GatherMate2's node
-- table, their names from its locale files, nothing of those files run but
-- AceLocale's NewLocale (#19).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local G = dofile("Tools/extract_gathermate.lua")

-- A node table in GatherMate2's shape: classic and later nodes, commented ones.
local constants = [[
local node_ids = {
	["Fishing"] = {
		["Floating Wreckage"] 			= 101,
	},
	["Mining"] = {
		["Copper Vein"] 					= 201,
		--["Hakkari Thorium Vein"] 			= 216, -- found on in ZG
		["Indurium Mineral Vein"]			= 220,
-- bc nodes
		["Fel Iron Deposit"] 				= 221,
		["Large Obsidian Chunk"] 			= 225, -- found only in AQ20/40
	},
	["Herb Gathering"] = {
		["Peacebloom"] 						= 401,
		--["Swiftthistle"] 					= 406, -- found it briathorn nodes
		--["Bloodvine"] 					= 430, -- zg bush loot
		["Black Lotus"] 					= 431,
		["Felweed"] 						= 432,
		--["Old Herb"] 						= 410,
	},
}
]]
local nodes = G.parseNodes(constants)
local byName = {}
for _, n in ipairs(nodes) do byName[n[1]] = n[2] end
eq(byName["Copper Vein"], "ore", "a classic vein")
eq(byName["Indurium Mineral Vein"], "ore", "...to the last of the range")
eq(byName["Large Obsidian Chunk"], "ore", "the AQ obsidian, past the TBC marker")
eq(byName["Hakkari Thorium Vein"], "ore", "commented out, a classic name all the same")
eq(byName["Bloodvine"], "herbs", "...Bloodvine too")
eq(byName["Fel Iron Deposit"], nil, "TBC: left out")
eq(byName["Felweed"], nil, "...a TBC herb too")
eq(byName["Swiftthistle"], nil, "loot from other nodes: left out")
eq(byName["Old Herb"], nil, "another commented-out entry: left out")
eq(byName["Floating Wreckage"], nil, "fishing: left out")
eq(#nodes, 7, "seven classic nodes")

-- A locale file: only NewLocale is given; anything else it touches fails.
local de = G.readLocale([[
local L = LibStub("AceLocale-3.0"):NewLocale("GatherMate2", "deDE")
if not L then return end
L["Herbalism"] = "Kräuterkunde"
local NL = LibStub("AceLocale-3.0"):NewLocale("GatherMate2Nodes", "deDE")
NL["Copper Vein"] = "Kupferader"
NL["Peacebloom"] = "Friedensblume"
NL["Fel Iron Deposit"] = "Teufelseisenvorkommen"
]], "deDE")
eq(de.GatherMate2Nodes["Copper Vein"], "Kupferader", "a node name read")
local deV = G.readLocale([[
local NLV = LibStub("AceLocale-3.0"):NewLocale("GatherMate2NodesVanilla", "deDE", false, "raw")
NLV["Copper Vein"] = "Kupfervorkommen"
NLV["Bloodvine"] = "Blutrebe"
]], "deDE vanilla")
local ok = pcall(G.readLocale, 'os.execute("x")', "hostile")
check(not ok, "a locale file reaches nothing but LibStub")

local en = { NL = { ["Copper Vein"] = true, ["Peacebloom"] = true, ["Black Lotus"] = true } }
local learned = G.build(nodes, { enUS = en, deDE = { NL = de.GatherMate2Nodes, NLV = deV.GatherMate2NodesVanilla } }, "GatherMate2 test")
eq(learned.enUS["Copper Vein"].kind, "ore", "enUS: `true` means the key is the name")
eq(learned.deDE["Kupferader"].kind, "ore", "deDE: the Retail name")
eq(learned.deDE["Kupfervorkommen"].kind, "ore", "...and the Vanilla one")
eq(learned.deDE["Blutrebe"].kind, "herbs", "...a Vanilla-only node")
eq(learned.deDE["Teufelseisenvorkommen"], nil, "a TBC node's name: left out")
eq(learned.deDE["Friedensblume"].source, "gathermate2", "the source, for the export's review")
-- GatherMate2's node ID, the key of the skill and item (#26), on both spellings.
eq(learned.enUS["Copper Vein"].node, 201, "the node ID kept")
eq(learned.deDE["Kupferader"].node, 201, "...on the Retail name")
eq(learned.deDE["Kupfervorkommen"].node, 201, "...and the Vanilla one")
eq(learned.deDE["Blutrebe"].node, 430, "...a Vanilla-only node's too")

-- Two nodes sharing a translated name: the name keeps no ID, and it's reported.
local twin, shared = G.build(nodes, { frFR = { NL = { ["Peacebloom"] = "Fleur", ["Black Lotus"] = "Fleur",
    ["Copper Vein"] = "Filon" } } }, "GatherMate2 test")
eq(twin.frFR["Fleur"].node, nil, "a name two nodes share has no ID")
eq(twin.frFR["Fleur"].kind, "herbs", "...but is still a node")
eq(twin.frFR["Filon"].node, 201, "...the others keep theirs")
eq(#shared, 1, "...reported once")
check(shared[1] and shared[1]:find('frFR "Fleur": nodes'), "...naming it: " .. tostring(shared[1]))

-- The rendered file loads back, in the export tool's input shape.
local chunk = loadstring(G.render(learned, "GatherMate2 test"))
local env = {}
setfenv(chunk, env)
chunk()
eq(env.NodeRadarDB.learned.deDE["Kupfervorkommen"].kind, "ore", "the reference file loads back")
eq(env.NodeRadarDB.learned.deDE["Kupfervorkommen"].node, 201, "...with the node ID")

-- The committed reference is the one the tool writes from the real GatherMate2,
-- when it's here (local only).
local real = "../References/Addons/MapMinimap/GatherMate2/GatherMate2"
local f = io.open(real .. "/Constants.lua", "rb")
if f then
    f:close()
    local cf = io.open(real .. "/Constants.lua", "rb")
    local realNodes = G.parseNodes(cf:read("*a"))
    cf:close()
    eq(#realNodes, 51, "GatherMate2 1.52.3-10: 51 classic nodes")
else
    io.write("  real GatherMate2 check SKIPPED (no ../References)\n")
end

done("test_gathermate")
