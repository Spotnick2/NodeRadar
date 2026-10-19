-- The compass3 procedure (/fp steps nr compass3, #29, third round): the
-- nearest-node compass on with the icons off; the ring, a gather moving it on,
-- the ride, a zoom, a clump, hidden near a node and shown again walking away,
-- a flight (true read first), the cost; both settings put back; the target's
-- changes logged with the candidates. Runs locally only (ForeverProbe is
-- private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
NR.db.icons = true                                         -- the player's own, to be put back
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 8 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/compass3"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y)
    nodes[#nodes + 1] = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    return nodes[#nodes]
end
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        local list = {}
        for _, n in ipairs(nodes) do
            list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
        end
        WoW.blips = list
        WoW.advance(0.1)
    end
end

walk(3)
fp("steps nr compass3")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.compass, true, "NodeRadar's compass on")
eq(NR.db.icons, false, "...its icons off")

-- The ring once a node is measured.
walk(2)
eq(result(2).status, nil, "no node: waits")
local leaf = node("Silverleaf", 0, 30)
local root = node("Earthroot", 0, -45)
walk(3)
eq(result(2).status, "done", "the ring: " .. detail(2))
check(detail(2):find("Silverleaf %d+") and detail(2):find("Earthroot %d+"), "...the candidates listed")
settle()
S.Answer(true)                                             -- 3
settle()
-- The gather: on to the Earthroot.
eq(record().at, 4, "the gather step")
WoW.pos[1] = leaf.north - 5
NR.Icons.Gathered("Silverleaf")
table.remove(nodes, 1)
walk(2)
local T = NR.Compass._test
check(T.target() and T.target().name == "Earthroot", "...the Earthroot after the gather")
S.Next()                                                   -- 4
settle()
S.Answer(true)                                             -- 5
settle()
S.Next()                                                   -- 6
settle()
S.Answer(true)                                             -- 7
settle()

-- A zoom with the ring up, the Earthroot 20 units off.
WoW.pos[1] = root.north + 20 * K()
walk(1.2)
eq(result(8).status, nil, "waits for a zoom")
Minimap._zoom = 1
walk(2.5)
eq(result(8).status, "done", "zoomed: " .. detail(8))
check(detail(8):find("the ring up"), "...the ring still up on a node in view")
Minimap._zoom = 0
settle()
S.Answer(true)                                             -- 9
settle()
S.Skip()                                                   -- 10: a clump
settle()
S.Skip()                                                   -- 11
-- Hidden near a node, shown again walking away.
walk(1.2)
eq(result(12).status, nil, "waits")
WoW.pos[1] = root.north + 10
walk(2.5)
eq(result(12).status, nil, "hidden near it: now walk away")
WoW.pos[1] = root.north + 40
walk(3)
eq(result(12).status, "done", "hidden then shown: " .. detail(12))

-- A flight: true read first.
poll()
eq(result(13).status, nil, "not flying: waits")
WoW.onTaxi = true
poll()
eq(result(13).status, nil, "one reading: not yet")
poll(); poll(); poll()
eq(result(13).status, "done", "on a flight: " .. detail(13))
check(detail(13):find("the ring down"), "...the ring down on the flight")
poll()
eq(result(14).status, nil, "still flying")
WoW.onTaxi = false
poll()
eq(result(14).status, "done", "landed: " .. detail(14))
check(detail(14):find("after landing"), "...the landing read")

-- The cost.
WoW.speed = 7
walk(62)
eq(result(15).status, "done", "the cost: " .. detail(15))
eq(db.icons.cost.compass3.icons, false, "...measured with the icons off")
WoW.speed = 0
eq(result(16).status, "done", "put back: " .. detail(16))
eq(rawget(NR.db, "compass"), nil, "NodeRadar's compass back to the default")
eq(rawget(NR.db, "icons"), true, "...its icons back on, as the player had them")
check(db.icons.compass3 and db.icons.compass3.changes >= 2, "the target's changes counted: "
    .. tostring(db.icons.compass3 and db.icons.compass3.changes))
eq(record().at, 17, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_compass3")
