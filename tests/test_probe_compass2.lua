-- The compass2 procedure (/fp steps nr compass2, #29, second round):
-- NodeRadar's own compass on with its icons off; an alert at the rim, its ring
-- once measured, a zoom, the ride to arrival, the optional steps, the cost of
-- the compass alone; both settings put back. Runs locally only (ForeverProbe
-- is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
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
local function settle()                                    -- short: the compass times out at 60 s
    for _ = 1, 6 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/compass2"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

local function K() return C_Minimap.GetViewRadius() / 99 end
local leaf
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        WoW.blips = leaf and { { "Silverleaf", -(leaf.west - WoW.pos[2]) / K(), (leaf.north - WoW.pos[1]) / K(),
                                 kind = "herbs" } } or {}
        WoW.advance(0.1)
    end
end

walk(8)                                                    -- the alert's baseline
fp("steps nr compass2")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.compass, true, "NodeRadar's compass on")
eq(NR.db.icons, false, "...its icons off")

-- An alert at the rim: pending, then the ring once measured.
walk(2)
eq(result(2).status, nil, "no alert yet: waits")
leaf = { north = WoW.pos[1] + 88 * K(), west = WoW.pos[2] }  -- a node at the north rim
walk(2)
eq(result(2).status, "done", "the alert: " .. detail(2))
check(detail(2):find("Silverleaf"), "...pending on Silverleaf")
eq(result(3).status, nil, "not measured yet: no ring")
for _ = 1, 10 do
    WoW.pos[1] = WoW.pos[1] + 4 * K()
    walk(0.5)
end
eq(result(3).status, "done", "the ring: " .. detail(3))
check(detail(3):find("s after the alert"), "...timed from the alert")
settle()
S.Answer(true)                                             -- 4
settle()

-- A zoom with the ring up.
walk(1.2)
eq(result(5).status, nil, "waits for a zoom")
WoW.posSecret = true                                       -- the ring down at the zoom (kept, hidden)
Minimap._zoom = 2
walk(2.5)
eq(result(5).status, nil, "zoomed with the ring down: waits")
WoW.posSecret = false
walk(2.5)                                                  -- measured again: the ring back
eq(result(5).status, "done", "zoomed: " .. detail(5))
Minimap._zoom = 0
settle()
S.Answer(true)                                             -- 6
settle()

-- The ride to it: gone about 15 yards from it.
for _ = 1, 40 do
    if result(7).status then break end
    WoW.pos[1] = math.min(WoW.pos[1] + 4, leaf.north - 2)
    walk(0.3)
end
eq(result(7).status, "done", "arrived: " .. detail(7))
local yd = tonumber(detail(7):match("at ([%d.]+) yd"))
check(yd and yd <= 15, "...gone within 15 yards: " .. detail(7))
settle()
S.Answer(true)                                             -- 8
settle()

-- The optional steps.
S.Skip()                                                   -- 9: a node above
poll()
eq(result(10).status, nil, "the timeout step: the arrival before it doesn't count")
S.Skip()                                                   -- 10: the timeout
eq(record().at, 11, "the camera step")
settle()
S.Next()                                                   -- 11
settle()
S.Answer(true)                                             -- 12: the click
settle()
S.Answer(true)                                             -- 13: Edit Mode
settle()
S.Answer(true)                                             -- 14: combat
settle()

-- A flight: must read true before the landing counts.
poll()
eq(result(15).status, nil, "not flying: waits")
WoW.onTaxi = true
poll()
eq(result(15).status, nil, "one reading on a flight: not yet")
poll(); poll(); poll()
eq(result(15).status, "done", "on a flight: " .. detail(15))
poll()
eq(result(16).status, nil, "still flying")
WoW.onTaxi = false
poll()
eq(result(16).status, "done", "landed: " .. detail(16))

-- The cost, the compass alone.
WoW.speed = 7
walk(62)
eq(result(17).status, "done", "the cost: " .. detail(17))
eq(db.icons.cost["compass alone"].icons, false, "...measured with the icons off")
WoW.speed = 0
eq(result(18).status, "done", "put back: " .. detail(18))
eq(rawget(NR.db, "compass"), nil, "NodeRadar's compass back to the default")
eq(rawget(NR.db, "icons"), true, "...its icons back on, as the player had them")
check(db.icons.compass2 and #db.icons.compass2 >= 3, "the compass's changes kept")
eq(record().at, 19, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_compass2")
