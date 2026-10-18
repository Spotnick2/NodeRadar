-- The coords procedure (/fp steps nr coords, #27): the view radius at every
-- zoom, a blip's predicted map coordinates north-up and rotating (the
-- conversion HereBeDragons-Pins draws with, inverted), and the error to where
-- the player stands when gathering that node. Runs locally only (ForeverProbe
-- is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
local NR = loadAddon()
NR.db.enabled = false                                      -- the probe sweeps; the radar stays out of it
local FP = loadForeverProbe()
local T = loadProbe()._test
local S = FP.Steps
local db = NodeRadarProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function record() return FP.db.steps.records["NodeRadarProbe/coords"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail) end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

-- HereBeDragons' outdoor sizes (diameters) per zoom, as radii.
WoW.viewRadius = { [0] = 233.33, [1] = 200, [2] = 166.67, [3] = 133.33, [4] = 100, [5] = 66.67 }
WoW.cvars.rotateMinimap = "0"
WoW.mapPos, WoW.mapSize = { x = 0.5, y = 0.5 }, { 1000, 800 }

fp("steps nr coords")
eq(result(1).status, "done", "coords: the snapshot on arrival")
check(detail(1):find("zoom 0, radius 233.3 yd over 99.0 units"), "...radius over the half-width: " .. detail(1))

-- Every zoom, outdoors.
poll()
eq(record().at, 2, "waits for every zoom")
for z = 1, 5 do Minimap._zoom = z; poll() end
eq(result(2).status, "done", "all six zooms seen")
check(detail(2):find("0=233.3 1=200.0 2=166.7 3=133.3 4=100.0 5=66.7"), "...their radii: " .. detail(2))
eq(db.coordsRadii.outdoor[3], 133.33, "...saved")
Minimap._zoom = 4                                          -- radius 100 over 99 units

-- North-up: a herb 30 units right, 20 down = east and south.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
S.Run()
eq(result(3).status, "done", "predicted: " .. tostring(result(3).lastError))
local p = T.state.coordsPredicted.nodes[1]
check(p, "a node predicted")
-- Against where NodeRadar's sweep reads the blip: yards = units x 100/99.
local k = 100 / 99
local seen = NR.Scan.Sweep().blips[1]
check(near(p.x, 0.5 + seen.x * k / 1000) and near(p.y, 0.5 - seen.y * k / 800),
    ("...east and south, each over its own map side: (%.4f, %.4f) from (%.1f, %.1f)"):format(p.x, p.y, seen.x, seen.y))
check(seen.x > 0 and seen.y < 0, "...(the blip read right of and below the centre)")
check(logged("coords north%-up: zoom 4, radius 100.0"), "...logged with the snapshot")

-- The gather, standing on it: the error in yards.
poll()
eq(record().at, 4, "waits for the gather")
WoW.mapPos = { x = p.x + 2 / 1000, y = p.y }                -- two yards east of the prediction
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Wilted Peacebloom", "Cast-1", 2366)
poll()
eq(result(4).status, "done", "a gather of that name completes it")
check(detail(4):find("2%.0 yd apart"), "...two yards apart: " .. detail(4))
check(db.coordsChecked and db.coordsChecked[1]:find("north%-up"), "...saved")

-- A gather of another name doesn't count as a check of this one.
WoW.cvars.rotateMinimap = "1"
poll()
eq(result(5).status, "done", "Rotate Minimap on")

-- Rotating, facing west (pi/2): up on the map is west.
WoW.facing = math.pi / 2
WoW.mapPos = { x = 0.5, y = 0.5 }
WoW.blips = { { "Wilted Peacebloom", 0, 30, kind = "herbs" } }
S.Run()
local r = T.state.coordsPredicted.nodes[1]
seen = NR.Scan.Sweep().blips[1]
check(r and near(r.x, 0.5 - seen.y * k / 1000) and near(r.y, 0.5 - seen.x * k / 800),
    ("rotating, facing west: up is west, right is north: (%.4f, %.4f)"):format(r and r.x or -1, r and r.y or -1))
poll()
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-2", 2366)
poll()
check(detail(7):find("none of that name was predicted"), "a gather of another name: said so")
WoW.cvars.rotateMinimap = "0"
poll()
eq(result(8).status, "done", "Rotate Minimap back off")

-- Indoors.
WoW.indoors = true
S.Run()
check(detail(9):find("indoors"), "indoors: read")
fp("steps stop")

-- Rotating without a facing (an instance): the snapshot says why, no maths.
WoW.cvars.rotateMinimap, WoW.facing = "1", nil
fp("steps nr coords")
check(tostring(result(1).lastError):find("rotating, but no facing"), "no facing: refused, saying why")
fp("steps stop")
WoW.cvars.rotateMinimap, WoW.facing = "0", 0

eq(#WoW.chat, 0, "nothing in chat")
eq(WoW.softCursor, false, "the soft cursor is off")

done("test_probe_coords")
