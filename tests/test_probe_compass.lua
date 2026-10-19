-- The compass procedure (/fp steps nr compass, #29, first round): the facing
-- in the four directions and across north, a draft ring's arrow toward one of
-- #28's records (ahead, then on the left), the walk to it against the distance
-- at the start, a flight, the icons put back. Runs locally only (ForeverProbe
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
NR.db.iconSize = "large"                                   -- the player's own, to be put back
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
    for _ = 1, 30 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/compass"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 0.01) end

-- One Silverleaf 30 units north and 30 east of the start (north-east: a
-- bearing of 7pi/4 counter-clockwise from north); the blips follow the player.
local function K() return C_Minimap.GetViewRadius() / 99 end
local leaf = { north = 30 * K(), west = -30 * K() }
local NE = 7 * math.pi / 4
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        WoW.blips = { { "Silverleaf", -(leaf.west - WoW.pos[2]) / K(), (leaf.north - WoW.pos[1]) / K(),
                        kind = "herbs" } }
        WoW.advance(0.1)
    end
end
local function face(f) WoW.facing = f; poll(); poll() end

WoW.facing = 1
walk(1)
fp("steps nr compass")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.icons, true, "NodeRadar's icons on")

-- The facing convention: north 0, west pi/2, south pi, east 3pi/2; held two polls.
WoW.facing = 0
S.Poll()                                                   -- one poll, by hand
eq(result(2).status, nil, "north for one poll: hold still")
S.Poll()
eq(result(2).status, "done", "north: " .. detail(2))
face(math.pi / 2)
eq(result(3).status, "done", "west: " .. detail(3))
face(3 * math.pi / 2)
eq(result(4).status, nil, "east isn't south")
face(math.pi)
eq(result(4).status, "done", "south: " .. detail(4))
face(3 * math.pi / 2)
eq(result(5).status, "done", "east: " .. detail(5))
check(near(db.icons.compass.west, math.pi / 2), "...the facings kept")
-- Across north.
face(6.0)
eq(result(6).status, nil, "turning, not across north yet")
face(0.2)
eq(result(6).status, "done", "across north: " .. detail(6))

-- The target: the nearest icon, the compass shown.
walk(3)
eq(result(7).status, "done", "a target: " .. detail(7))
-- (The record's measured centre is within 0.4 units of the node: bearings and
-- the arrow are checked to that.)
local b = tonumber(detail(7):match("bearing ([%d.]+)"))
check(b and near(b, NE, 0.02), "...north-east, 7pi/4: " .. detail(7))
local d = tonumber(detail(7):match("([%d.]+) yd"))
local want = math.sqrt(2) * 30 * K()
check(d and near(d, want, 1), ("...%.1f yd away: %s"):format(want, detail(7)))
settle()

-- Ahead: the arrow at the ring's top, unturned.
face(NE)
walk(1)
eq(result(8).status, "done", "ahead: " .. detail(8))
local frame
for _, w in ipairs(WoW.frames) do
    if w._parent == UIParent and w._width == 120 then frame = w end
end
check(frame and frame._shown, "the compass shown on UIParent")
eq(frame and frame._mouse, false, "...taking no mouse")
local arrow
for _, t in ipairs(frame and frame._regions or {}) do if t._layer == "OVERLAY" and t._file then arrow = t end end
WoW.tick(0.016)
local p = arrow and arrow._points[1]
check(p and near(p[4], 0, 0.5) and near(p[5], 48, 0.5), "...the arrow at the top")
check(arrow and near(arrow._rotation, 0, 0.02), "...not turned")
settle()
S.Answer(true)                                             -- 9
settle()

-- The node on the left: facing south-east, the node north-east.
face(NE - math.pi / 2)
walk(1)
eq(result(10).status, "done", "on the left: " .. detail(10))
WoW.tick(0.016)
p = arrow._points[1]
check(near(p[4], -48, 0.5) and near(p[5], 0, 0.5), "the arrow on the ring's left")
check(near(arrow._rotation, math.pi / 2, 0.02), "...turned a quarter counter-clockwise")
settle()
S.Answer(true)                                             -- 11
settle()

-- The walk: straight to the node, then the gather.
for _ = 1, 20 do
    WoW.pos[1] = WoW.pos[1] + 30 * K() / 20
    WoW.pos[2] = WoW.pos[2] - 30 * K() / 20
    walk(0.2)
end
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-1", 2366)
poll()
eq(result(12).status, "done", "the walk: " .. detail(12))
local w = db.icons.compass.walk
check(w and near(w.start, w.walked, 1) and w.off < 1, "...walked as far as the start's distance, at the record")
settle()
S.Answer(true)                                             -- 13
settle()

-- A flight.
poll()
eq(result(14).status, nil, "not on a flight: waits")
WoW.onTaxi = true
poll()
eq(result(14).status, "done", "on a flight: " .. detail(14))
poll()
eq(result(15).status, nil, "still flying")
WoW.onTaxi = false
poll()
eq(result(15).status, "done", "landed: " .. detail(15))
eq(result(16).status, "done", "put back: " .. detail(16))
eq(frame._shown, false, "the compass down")
eq(rawget(NR.db, "icons"), nil, "NodeRadar's icons back")
eq(rawget(NR.db, "iconSize"), "large", "...the player's size kept")
eq(record().at, 17, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
checkMethods({ "Texture:SetRotation" })
done("test_probe_compass")
