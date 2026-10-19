-- The compass (#29, experimental; docs/PLAN.md "The compass, experimental"):
-- an alert leaves a pending target that the first record of its names made
-- after it resolves; the ring's arrow at bearing - facing; every dismissal and
-- hide; the records kept for the compass with the icons off, each setting doing
-- its own part; the order in NR.Step and the learner. Off, nothing runs.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
local Icons, Compass = NR.Icons, NR.Compass
local C, T = Compass._test, Icons._test
WoW.itemCached[765] = true

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y)                            -- at map offset (x, y) from the player now
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    nodes[#nodes + 1] = n
    return n
end
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs",
                            text = n.text }
    end
    WoW.blips = list
end
local function step(dt)
    WoW.now = WoW.now + (dt or 1)
    place()
    local before = WoW.reads
    NR.Step(WoW.now)
    return WoW.reads - before
end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 0.05) end
local function target() return C.target() end
local function shown() return C.ring._shown end
local function rec(name)
    for _, r in ipairs(T.records()) do if r.name == name then return r end end
end
-- A fresh start: no nodes, the alert's baseline taken, past its cooldown.
local function fresh()
    nodes = {}
    Compass.Dismiss()
    Icons.Clear()
    WoW.dead, WoW.onTaxi = false, false
    WoW.pos = { 0, 0, 1 }
    WoW.facing = 0
    step(30)                                               -- the alert's silent baseline after the pause
    for _ = 1, 6 do step(1) end                            -- past the alert's cooldown, its history fresh
end

--------------------------------------------------------------------------------
-- Off: nothing
--------------------------------------------------------------------------------

eq(NR.db.compass, false, "off by default")
eq(NR.db.icons, false, "...with the icons off by default")
fresh()
node("Silverleaf", 40, 30)
local plainReads = step(1)
eq(target(), nil, "off: no target")
eq(C.pending(), nil, "...nor a pending one")
eq(shown(), false, "...no ring")
eq(#T.records(), 0, "...no records, nothing measured")
check(C.ring._parent == UIParent and C.ring._mouse == false, "the ring: a child of UIParent, no mouse")

--------------------------------------------------------------------------------
-- An alert at the rim: pending until its node is measured
--------------------------------------------------------------------------------

NR.Set("compass", true)
NR.db.iconStyle = "glass"                                  -- resolving a look would try LibGlass, and fail here
fresh()
local frames = T.frames
local sl = node("Silverleaf", 0, 88)                       -- at the rim: not whole, not measured
step(1)
eq(rec("Silverleaf"), nil, "a rim blip: no record yet")
check(C.pending() and C.pending().names.Silverleaf, "the alert leaves a pending target")
eq(target(), nil, "...nothing to point at")
eq(shown(), false, "...no ring")
local alertAt = C.pending().at
WoW.pos[1] = WoW.pos[1] + 30 * K()                         -- 30 units north: the node comes in
step(1)
local r = rec("Silverleaf")
check(r, "measured once whole")
check(target() and target().record == r, "the pending target resolves to it")
eq(target().at, alertAt, "...timed from the alert")
eq(C.pending(), nil, "...no longer pending")
check(shown(), "the ring shown")
eq(T.frames, frames, "the icons off: no icon frame made")
eq(T.driver._scripts.OnUpdate, nil, "...no icon driver")
eq(NR.failures.glass, nil, "...no look resolved, no glass tried")
NR.db.iconStyle = nil

-- The arrow: ahead, left, behind, right, and across north.
local function aim(f)
    WoW.facing = f
    C.frame()
    local p = C.arrow._points[1]
    return p[4], p[5], C.arrow._rotation
end
local x, y, rot = aim(0)
check(near(x, 0, 0.5) and near(y, 48, 0.5) and near(rot, 0, 0.02), "the node ahead (north): the arrow at the top")
x, y, rot = aim(3 * math.pi / 2)
check(near(x, -48, 0.5) and near(y, 0, 0.5) and near(rot, math.pi / 2, 0.02), "facing east: on the left, a quarter turn")
x, y = aim(math.pi)
check(near(x, 0, 0.5) and near(y, -48, 0.5), "facing south: behind, at the bottom")
x, y = aim(math.pi / 2)
check(near(x, 48, 0.5) and near(y, 0, 0.5), "facing west: on the right")
x, y = aim(2 * math.pi - 0.01)
check(near(x, 0, 1) and near(y, 48, 0.5), "just short of 2pi: still ahead")
-- Off an axis: the node north-east, 7pi/4 counter-clockwise from north.
local savedPos = { WoW.pos[1], WoW.pos[2], WoW.pos[3] }
WoW.pos = { r.north - 30, r.west + 30, 1 }                 -- 30 yd south and 30 yd west of it
x, y = aim(7 * math.pi / 4)
check(near(x, 0, 0.5) and near(y, 48, 0.5), "a node north-east, facing north-east: ahead")
x, y = aim(0)
check(near(x, 48 * math.sin(math.pi / 4), 0.5) and near(y, 48 * math.cos(math.pi / 4), 0.5),
    "...facing north: up and to the right")
WoW.pos = savedPos
aim(0)
local d = math.floor(math.sqrt((r.north - WoW.pos[1]) ^ 2 + (r.west - WoW.pos[2]) ^ 2) + 0.5)
eq(C.text._text, d .. " yd", "the distance in whole yards")
check(C.circle._vertex and near(C.circle._vertex[1], NR.Alert.COLOURS.herbs[1]), "tinted as the sonar: herbs")

--------------------------------------------------------------------------------
-- Choosing
--------------------------------------------------------------------------------

local function cool() for _ = 1, 6 do step(1) end end      -- past the alert's 5 s cooldown

-- Measured the same sweep as the alert: the target at once.
fresh()
node("Silverleaf", 30, 30)
step(1)
check(target() and target().record == rec("Silverleaf"), "measured at the alert: the target at once")
eq(C.pending(), nil, "...nothing pending")
-- The nearest of two made in one sweep.
fresh()
local far = node("Silverleaf", 60, 0)
local close = node("Silverleaf", -30, 0)
step(1)
local tr = target() and target().record
check(tr and near(tr.west, close.west, 2), "two measured at once: the nearer")
-- Records made before the alert never: an old Silverleaf, an Earthroot.
fresh()
node("Silverleaf", -40, 0)
node("Earthroot", 30, -30)
step(1)
Compass.Dismiss()
cool()
node("Silverleaf", 0, 88)                                  -- the new one, at the rim
step(1)
check(C.pending() and C.pending().names.Silverleaf and not C.pending().names.Earthroot, "Silverleaf pending")
eq(target(), nil, "...neither the old Silverleaf nor the Earthroot is the target")
-- A record of another name measured while it's pending: never the target.
fresh()
local er = node("Earthroot", -88, 0)                       -- an old Earthroot at the west rim
step(1)
Compass.Dismiss()
cool()
node("Silverleaf", 88, 0)                                  -- the new one at the east rim
step(1)
check(C.pending(), "Silverleaf pending")
WoW.pos[2] = WoW.pos[2] + 30 * K()                         -- west: the Earthroot comes in, the Silverleaf goes
step(1)
check(rec("Earthroot") and rec("Earthroot").born == WoW.now, "the Earthroot measured this sweep")
eq(target(), nil, "...not the target: not an alerted name")
WoW.pos[2] = 0
-- Lapsed after 15 s without one.
step(16)
eq(C.pending(), nil, "no node measured within 15 s: lapsed")
eq(target(), nil, "...and nothing shown")
-- The heuristic, stated: an old node of the name measured late after the alert is chosen.
fresh()
local old = node("Silverleaf", 0, 88)                      -- an old one at the rim, never measured
step(1)
Compass.Dismiss()                                          -- (its own alert done with)
cool()
local new = node("Silverleaf", 88, 0)                      -- a new one at another rim
step(1)
check(C.pending(), "the new one's alert: pending")
WoW.pos[1] = WoW.pos[1] + 30 * K()                         -- toward the old one
step(1)
tr = target() and target().record
check(tr and near(tr.north, old.north, 2), "the first measured after the alert wins, old or not (stated)")

--------------------------------------------------------------------------------
-- Dismissed and hidden
--------------------------------------------------------------------------------

local function aimed(x0, y0)
    fresh()
    local n = node("Silverleaf", x0 or 0, y0 or 40)
    step(1)
    check(target() and shown(), "a target shown")
    return n
end
-- Arrival within 15 yards, not with a height.
local n = aimed()
WoW.pos[1] = n.north - 14
C.frame()
eq(target(), nil, "within 15 yards: arrived, dismissed")
eq(shown(), false, "...the ring hidden")
n = aimed()
n.text = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16|tSilverleaf"
step(1)
eq(target() and target().height, "above", "the node above: its height followed")
WoW.pos[1] = n.north - 14
C.frame()
check(target(), "...within 15 yards but above: not arrived")
n.text = nil
step(1)
eq(target() and target().height, nil, "...level again: no height")
C.frame()
eq(target(), nil, "...then arrived")
-- The gather of its name near it.
n = aimed()
WoW.pos[1] = n.north - 10
Icons.Gathered("Earthroot")
check(target(), "a gather of another name: kept")
Icons.Gathered("Silverleaf")
eq(target(), nil, "its name gathered within 15 yards: dismissed")
-- The timeout, while shown and while hidden.
n = aimed()
WoW.now = WoW.now + 61
C.frame()
eq(target(), nil, "60 s after the alert: dismissed")
n = aimed()
WoW.posSecret = true
C.frame()
eq(shown(), false, "the position unreadable: hidden")
check(target(), "...kept")
WoW.posSecret = false
step(61)
eq(target(), nil, "expired while hidden: never shown again")
eq(shown(), false, "...hidden")
-- Hidden without a sweep, shown again after one.
n = aimed()
WoW.now = WoW.now + NR.db.interval + 3
C.frame()
eq(shown(), false, "no sweep for the interval + 2 s: hidden")
check(target(), "...kept")
step(1)
check(shown(), "...shown after the next sweep")
-- The facing unreadable.
WoW.facing = nil
C.frame()
eq(shown(), false, "the facing unreadable: hidden")
WoW.facing = 0
step(1)
check(shown(), "...shown again")
-- A taxi.
WoW.onTaxi = true
C.frame()
eq(target(), nil, "on a taxi: dismissed")
-- Its record dropped at the rim, by riding away: dismissed, never switched.
n = aimed(0, 60)
node("Silverleaf", 0, -60)                                 -- another of the name behind
step(1)
WoW.pos[1] = WoW.pos[1] - 40 * K()                         -- away from it
step(1); step(1)
eq(target(), nil, "its record dropped past the rim: dismissed")
-- The events and settings that end it.
local function endsOn(label, fn, after)
    aimed()
    fn()
    eq(target(), nil, label .. ": dismissed")
    if after then after() end
end
endsOn("death", function() WoW.dead = true; WoW.fire("PLAYER_DEAD") end, function() WoW.dead = false end)
endsOn("a loading screen", function() WoW.fire("LOADING_SCREEN_ENABLED") end,
    function() WoW.fire("LOADING_SCREEN_DISABLED") end)
endsOn("entering the world", function() WoW.fire("PLAYER_ENTERING_WORLD", false, false) end)
endsOn("tracking changed", function() WoW.fire("MINIMAP_UPDATE_TRACKING") end)
endsOn("a new instance", function() WoW.pos[3] = 2; step(1) end, function() WoW.pos[3] = 1 end)
endsOn("the compass off", function() NR.Set("compass", false) end, function() NR.Set("compass", true) end)
endsOn("the radar off", function() NR.Set("enabled", false) end, function() NR.Set("enabled", true) end)
-- No pending target while dead.
fresh()
WoW.dead = true
node("Silverleaf", 0, 88)
step(1)
eq(C.pending(), nil, "dead: an alert leaves no pending target")
WoW.dead = false

-- A passing clear (no map position): kept, hidden, bound again within 3 yards,
-- not to another of the name measured first.
n = aimed()
local before = target().record
node("Silverleaf", 30, 0)                                  -- another, nearer the centre: measured first
step(1)
WoW.map = nil                                              -- Scan.Where reads nothing: no `where`
step(1)
eq(#T.records(), 0, "no where: the records cleared")
check(target() and target().record == nil, "...the target kept, unbound")
eq(shown(), false, "...hidden")
WoW.map = 1411
step(1)
check(target() and target().record and target().record ~= before, "measured again: bound to the new record")
check(near(target().north, before.north, 3) and near(target().west, before.west, 3), "...its own node's")
check(shown(), "...shown again")
eq(target().at, before.born, "...the alert's time unchanged")

-- A later alert replaces it once its own pending target resolves.
n = aimed(0, 40)
local first = target().record
cool()
node("Earthroot", 0, -88)                                  -- a new alert, at the rim
step(1)
check(C.pending() and target() and target().record == first, "a later alert pending: the current target stays")
WoW.pos[1] = WoW.pos[1] - 30 * K()
step(1)
check(target() and target().name == "Earthroot", "...replaced once it resolves")

--------------------------------------------------------------------------------
-- NR.Step's order, and the learner
--------------------------------------------------------------------------------

-- The learner starting in the same step, with no tracking event at all.
aimed()
local consider, busy = NR.Learn.Consider, NR.Learn.Busy
local started = false
NR.Learn.Consider = function() started = true end
NR.Learn.Busy = function() return started end
step(1)
NR.Learn.Consider, NR.Learn.Busy = consider, busy
eq(target(), nil, "the learner starting, no event: no target")
eq(C.pending(), nil, "...nothing pending")
eq(shown(), false, "...no ring")
eq(#T.records(), 0, "...no records")

--------------------------------------------------------------------------------
-- The records for both: each setting its own part
--------------------------------------------------------------------------------

aimed()
eq(NR.db.icons, false, "the compass alone")
local kept = #T.records()
check(kept > 0, "records kept for the compass")
NR.Set("icons", true)
local f = rec("Silverleaf").frame
check(f and f._shown, "icons on: the kept records drawn at once")
check(T.driver._scripts.OnUpdate, "...the icon driver on")
NR.Set("icons", false)
eq(#T.records(), kept, "icons off, the compass on: the records kept")
eq(f._shown, false, "...the icon hidden")
eq(T.driver._scripts.OnUpdate, nil, "...the driver off")
check(target(), "...the target untouched")
NR.Set("icons", true)
NR.Set("compass", false)
eq(target(), nil, "the compass off: the target dismissed")
eq(#T.records(), kept, "...the records kept for the icons")
NR.Set("icons", false)
eq(#T.records(), 0, "both off: cleared")
NR.Set("compass", true)

-- /nr compass and the Options page.
aimed()
SlashCmdList.NODERADAR("compass")
eq(NR.db.compass, false, "/nr compass: off")
eq(target(), nil, "...the target dismissed")
SlashCmdList.NODERADAR("compass")
eq(NR.db.compass, true, "...and on")
NR.Options._test.panel:Show()
local cb = NR.Options._test.checks.compass
check(cb and cb:GetChecked(), "Options: the experimental checkbox reads on")
WoW.click(cb)
eq(NR.db.compass, false, "...a click turns it off")

eq(#WoW.chat > 0, true, "the /nr lines said")
eq(WoW.softCursor, false, "the soft cursor is off")
checkMethods({ "Texture:SetRotation", "FontString:SetText" })
done("test_compass")
