-- A blip's zone-map coordinates in the chat line (#27): the sweep's snapshot
-- (Scan.Where), the conversion (Scan.MapPosition: HereBeDragons-Pins' minimap
-- drawing inverted, measured within reach of two gathered nodes), and nil,
-- the name alone, whenever anything is missing, secret, rotating, in an
-- instance or off the map.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
local NR = loadAddon()
NR.db.learn = false
local Scan, Alert = NR.Scan, NR.Alert

WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.4 }, { 5287, 3525 }
WoW.viewRadius = { [0] = 233.3 }
local G = { w = 198, h = 198 }                             -- the map's own units
local K = 233.3 / 99                                       -- yards per unit at zoom 0

local function at(bx, by) return Scan.MapPosition({ where = Scan.Where(), geometry = G }, { x = bx, y = by }) end
local function close(a, b) return math.abs(a - b) < 1e-9 end

-- The conversion.
local map, x, y = at(30, 0)
eq(map, 1411, "the zone's uiMapID with the coordinates")
check(close(x, 0.5 + 30 * K / 5287) and close(y, 0.4), "right of the centre is east, over the map's width")
map, x, y = at(-30, 0)
check(close(x, 0.5 - 30 * K / 5287), "left is west")
map, x, y = at(0, 40)
check(close(y, 0.4 - 40 * K / 3525) and close(x, 0.5), "up is north: y falls, over the map's height")
map, x, y = at(0, -40)
check(close(y, 0.4 + 40 * K / 3525), "down is south")
WoW.viewRadius = { [0] = 66.7 }
map, x = at(30, 0)
check(close(x, 0.5 + 30 * (66.7 / 99) / 5287), "the zoom's radius scales it")
WoW.viewRadius = { [0] = 233.3 }
WoW.mapPos = { x = 0.999, y = 0.4 }
eq(at(60, 0), nil, "off the map's east edge: nil, never clamped")
WoW.mapPos = { x = 0.5, y = 0.001 }
eq(at(0, 40), nil, "...off its north edge too")
WoW.mapPos = { x = 0.5, y = 0.4 }

-- Nil whenever an input is missing, secret or unusable.
local function none(what, set, unset)
    set()
    eq(Scan.Where(), nil, what)
    unset()
    check(Scan.Where() ~= nil, "...and back once it's readable: " .. what)
end
none("no map", function() WoW.map = nil end, function() WoW.map = 1411 end)
none("a secret map", function() WoW.map = WoW.Secret("map") end, function() WoW.map = 1411 end)
none("no position", function() WoW.mapPos = nil end, function() WoW.mapPos = { x = 0.5, y = 0.4 } end)
none("a secret position", function() WoW.mapPos = { x = WoW.Secret("x"), y = 0.4 } end,
    function() WoW.mapPos = { x = 0.5, y = 0.4 } end)
none("a zero size", function() WoW.mapSize = { 0, 3525 } end, function() WoW.mapSize = { 5287, 3525 } end)
none("a secret size", function() WoW.mapSize = { 5287, WoW.Secret("h") } end, function() WoW.mapSize = { 5287, 3525 } end)
none("no view radius", function() WoW.viewRadius = { [0] = 0 } end, function() WoW.viewRadius = { [0] = 233.3 } end)
none("a rotating minimap", function() WoW.cvars.rotateMinimap = "1" end, function() WoW.cvars.rotateMinimap = "0" end)
none("rotation unreadable", function() WoW.cvars.rotateMinimap = nil end, function() WoW.cvars.rotateMinimap = "0" end)
none("rotation secret", function() WoW.cvars.rotateMinimap = WoW.Secret("rot") end,
    function() WoW.cvars.rotateMinimap = "0" end)
none("rotation not a 0 or 1", function() WoW.cvars.rotateMinimap = "yes" end, function() WoW.cvars.rotateMinimap = "0" end)
none("in an instance", function() WoW.instanced = true end, function() WoW.instanced = false end)
none("the instance unreadable", function() WoW.instanced = "throw" end, function() WoW.instanced = false end)
none("the instance secret", function() WoW.instanced = WoW.Secret("inst") end, function() WoW.instanced = false end)
-- A rotation the client ignores is north-up.
WoW.cvars.rotateMinimap, WoW.rotateIgnored = "1", true
check(Scan.Where() ~= nil, "rotation on but ignored: north-up, coordinates")
WoW.rotateIgnored = "maybe"
eq(Scan.Where(), nil, "...the ignored flag not a boolean: nil")
WoW.cvars.rotateMinimap, WoW.rotateIgnored = "0", false
local realGetCVar = C_CVar.GetCVar
C_CVar.GetCVar = function() error("GetCVar failed") end
eq(Scan.Where(), nil, "the rotation read throwing: nil")
C_CVar.GetCVar = realGetCVar

-- The sweep carries its snapshot; a missing one leaves the detection alone.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
local r = Scan.Sweep()
check(r.where and r.where.map == 1411, "the sweep's result carries where it was taken")
WoW.instanced = true
r = Scan.Sweep()
eq(r.where, nil, "in an instance: no snapshot")
eq(Scan.Count(r, "Wilted Peacebloom"), 1, "...and the blip still read")
WoW.instanced = false

-- The chat line.
local res = { where = Scan.Where(), geometry = G }
local one = { ["Peacebloom"] = { { x = 30, y = 0 } } }
local px = (0.5 + 30 * K / 5287) * 100
eq(Alert.ChatLine({ "Peacebloom" }, one, res), ("Peacebloom (%.1f, 40.0)"):format(px), "one blip: its coordinates")
local two = { ["Peacebloom"] = { { x = 30, y = 0 }, { x = 0, y = 40 } }, ["Copper Vein"] = { { x = -30, y = 0 } } }
local line = Alert.ChatLine({ "Copper Vein", "Peacebloom" }, two, res)
eq(select(2, line:gsub("Peacebloom %(", "")), 2, "a name with two blips: both listed: " .. line)
check(line:find("^Copper Vein %(4[0-9]%.%d, 40%.0%), Peacebloom"), "...every name, in order: " .. line)
eq(Alert.ChatLine({ "Peacebloom" }, one, { geometry = G }), "Peacebloom", "no snapshot: the name alone")
local edge = { where = { map = 1411, x = 0.5, y = 0.01, w = 5287, h = 3525, radius = 233.3 }, geometry = G }
eq(Alert.ChatLine({ "Peacebloom" }, { ["Peacebloom"] = { { x = 0, y = 98 } } }, edge), "Peacebloom",
    "...a blip past the map's north edge: the name alone")
eq(Alert.ChatLine({ "test" }, { test = { { x = 0, y = 0 } } }, nil), "test", "/nr test: unchanged")
eq(Alert.ChatLine({ "Peacebloom" }, {}, res), "Peacebloom", "a name without blips: still named")

-- End to end: an alert with the chat line on.
NR.db.sound, NR.db.ring, NR.db.chat = false, false, true
WoW.blips = {}
WoW.advance(6)
newChat()
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
WoW.advance(2.5)
local said = newChat()[1]
check(said and said:find("Wilted Peacebloom %(5[0-9]%.%d, 4[0-9]%.%d%)"), "the alert's chat line has coordinates: "
    .. tostring(said))
WoW.blips = {}
WoW.advance(25)                                            -- past the blink window: the next is a new node
WoW.instanced = true
newChat()
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
WoW.advance(2.5)
said = newChat()[1]
check(said and said:find("Wilted Peacebloom$"), "in an instance: the name alone: " .. tostring(said))
WoW.instanced = false

eq(next(NR.failures), nil, "no failure recorded: " .. tostring(next(NR.failures)))
checkMethods({})

done("test_coords")
