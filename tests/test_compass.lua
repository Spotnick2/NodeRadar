-- The compass (#29, experimental; docs/PLAN.md "The compass, experimental"):
-- the nearest gatherable record, chosen again every sweep with a 5-yard
-- hysteresis and after a gather; the ring's arrow at bearing - facing; hidden
-- within 15 yards and every other way, shown again at the next usable sweep;
-- the records kept for the compass with the icons off, each setting doing its
-- own part; the learner in the same step. Off, nothing runs.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
TEST_LIBRARY.enUS["Mageroyal"] = "herbs"
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
        if not n.gone then
            list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs",
                                text = n.text }
        end
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
local function at(n) return target() and near(target().north, n.north, 1) and near(target().west, n.west, 1) end
local function fresh()
    nodes = {}
    Icons.Clear()
    WoW.dead, WoW.onTaxi, WoW.posSecret = false, false, false
    WoW.pos = { 0, 0, 1 }
    WoW.facing = 0
    step(1)
end

--------------------------------------------------------------------------------
-- Off: nothing
--------------------------------------------------------------------------------

eq(NR.db.compass, false, "off by default")
eq(NR.db.icons, false, "...with the icons off by default")
fresh()
node("Silverleaf", 30, 30)
step(1)
eq(target(), nil, "off: no target")
eq(shown(), false, "...no ring")
eq(#T.records(), 0, "...no records, nothing measured")
check(C.ring._parent == UIParent and C.ring._mouse == false, "the ring: a child of UIParent, no mouse")

--------------------------------------------------------------------------------
-- The nearest gatherable record
--------------------------------------------------------------------------------

NR.Set("compass", true)
NR.db.iconStyle = "glass"                                  -- resolving a look would try LibGlass, and fail here
fresh()
local frames = T.frames
local far = node("Silverleaf", 60, 0)
local close = node("Silverleaf", 0, 40)
step(1)
check(at(close), "two nodes: the nearer")
check(shown(), "...the ring shown")
eq(T.frames, frames, "the icons off: no icon frame made")
eq(T.driver._scripts.OnUpdate, nil, "...no icon driver")
eq(NR.failures.glass, nil, "...no look resolved, no glass tried")
NR.db.iconStyle = nil
-- Chosen again as the player moves.
WoW.pos[2] = WoW.pos[2] - 50 * K()                         -- east: the far one comes close
step(1)
check(at(far), "riding east: the other is nearer now")
-- None: hidden.
fresh()
step(1)
eq(target(), nil, "no record: no target")
eq(shown(), false, "...no ring")
-- A node the skill can't gather never; with skillOnly off, it can.
fresh()
WoW.skillLines[182] = { skillID = 182, rank = 10, modifier = 0, maxRank = 300 }
local mag = node("Mageroyal", 0, 30)                       -- needs 50
local leaf = node("Silverleaf", 0, -60)
step(1)
check(at(leaf), "Mageroyal above the skill: passed over, the farther Silverleaf")
NR.Set("skillOnly", false)
step(1)
check(at(mag), "skillOnly off: the Mageroyal")
NR.Set("skillOnly", true)
step(1)
check(at(leaf), "...and back: not gatherable, replaced outright")
WoW.skillLines[182] = nil

-- A record missed once still chosen; recovered still; dropped at the second miss.
fresh()
local a = node("Silverleaf", 0, 40)
local b = node("Earthroot", 0, -70)
step(1)
check(at(a), "the Silverleaf the target")
a.gone = true
step(1)
eq(rec("Silverleaf") and rec("Silverleaf").misses, 1, "missed once")
check(at(a), "...still the target")
a.gone = nil
step(1)
check(at(a), "...recovered: still")
a.gone = true
step(1); step(1)
eq(rec("Silverleaf"), nil, "missed twice: dropped")
check(at(b), "...the Earthroot now")

-- Hysteresis: 3 yards nearer doesn't take over, exactly 5 does, equal stays put.
local function pair(dA, dB)
    fresh()
    local na = node("Silverleaf", 0, dA / K())
    step(1)
    local nb = node("Earthroot", 0, -(dB / K()))
    step(1)
    return na, nb
end
local na, nb = pair(60, 57)
check(at(na), "another 3 yards nearer: the current one stays")
na, nb = pair(60, 53)
check(at(nb), "7 yards nearer: it takes over (measured positions are within about half a yard)")
na, nb = pair(60, 60)
check(at(na), "as far: the current one stays")
-- The incumbent gone, the replacement under 5 yards farther: replaced.
fresh()
na = node("Silverleaf", 0, 40)
step(1)
nb = node("Earthroot", 0, -45)
step(1)
check(at(na), "the nearer one first")
WoW.pos[1] = WoW.pos[1] + 3 * K()
na.gone = true
step(1); step(1)
check(at(nb), "its record gone: the other, though farther")

-- A zoom in pushes it past the rim: on to one still in view, or hidden.
fresh()
na = node("Silverleaf", 0, 80)
nb = node("Earthroot", 0, -85)
step(1)
check(at(na), "the nearer at 80 units")
WoW.viewRadius = { [0] = 150, [1] = 100 }
Minimap._zoom = 1
na.north, na.west = na.north, na.west                       -- (the nodes don't move; the view shrinks)
step(1)
eq(rec("Silverleaf"), nil, "zoomed in: its record past the rim")
eq(target(), nil, "...both past it: no target")
eq(shown(), false, "...hidden")
Minimap._zoom = 0

-- No timeout, no alert tie: chosen on a baseline, in the cooldown, past 60 s.
fresh()
na = node("Silverleaf", 0, 40)
step(30)                                                   -- the alert's silent baseline after the pause
check(at(na), "on the alert's silent baseline")
for _ = 1, 70 do step(1) end
check(at(na) and shown(), "70 s later: still")

--------------------------------------------------------------------------------
-- The gather
--------------------------------------------------------------------------------

fresh()
na = node("Silverleaf", 0, 30)
nb = node("Earthroot", 0, -70)
step(1)
check(at(na), "the Silverleaf the target")
-- An unrelated gather: the hysteresis kept.
WoW.pos[1] = WoW.pos[1] + 25 * K()
Icons.Gathered("Mageroyal")
check(at(na), "an unrelated gather: kept")
-- Its name gathered: its record gone, on to the next at once.
Icons.Gathered("Silverleaf")
na.gone = true
check(target() and target().name == "Earthroot", "its name gathered: the next at once, no sweep")
-- A gather never revives a stale ring.
fresh()
na = node("Silverleaf", 0, 40)
nb = node("Earthroot", 0, -60)
step(1)
WoW.now = WoW.now + NR.db.interval + 3                     -- no sweep since
C.frame()
eq(shown(), false, "no recent sweep: hidden")
WoW.pos[1] = na.north
Icons.Gathered("Silverleaf")
eq(shown(), false, "...a gather doesn't revive it")

--------------------------------------------------------------------------------
-- The ring
--------------------------------------------------------------------------------

fresh()
na = node("Silverleaf", 0, 40)
step(1)
local function aim(f)
    WoW.facing = f
    C.frame()
    local p = C.arrow._points[1]
    return p[4], p[5], C.arrow._rotation
end
local x, y, rot = aim(0)
check(near(x, 0, 0.5) and near(y, 48, 0.5) and near(rot, 0, 0.02), "the node ahead (north): the arrow at the top")
x, y, rot = aim(3 * math.pi / 2)
check(near(x, -48, 0.5) and near(y, 0, 0.5) and near(rot, math.pi / 2, 0.02), "facing east: on the left")
x, y = aim(math.pi)
check(near(x, 0, 0.5) and near(y, -48, 0.5), "facing south: behind")
x, y = aim(math.pi / 2)
check(near(x, 48, 0.5) and near(y, 0, 0.5), "facing west: on the right")
x, y = aim(2 * math.pi - 0.01)
check(near(x, 0, 1) and near(y, 48, 0.5), "just short of 2pi: still ahead")
local saved = { WoW.pos[1], WoW.pos[2], 1 }
WoW.pos = { target().north - 30, target().west + 30, 1 }   -- 30 yd south and 30 yd west of it
x, y = aim(7 * math.pi / 4)
check(near(x, 0, 0.5) and near(y, 48, 0.5), "a node north-east, facing north-east: ahead")
x, y = aim(0)
check(near(x, 48 * math.sin(math.pi / 4), 0.5) and near(y, 48 * math.cos(math.pi / 4), 0.5),
    "...facing north: up and to the right")
WoW.pos = saved
aim(0)
local d = math.floor(math.sqrt((target().north - WoW.pos[1]) ^ 2 + (target().west - WoW.pos[2]) ^ 2) + 0.5)
eq(C.text._text, d .. " yd", "the distance in whole yards")
check(C.circle._vertex and near(C.circle._vertex[1], NR.Alert.COLOURS.herbs[1]), "tinted as the sonar: herbs")

--------------------------------------------------------------------------------
-- Shown and hidden
--------------------------------------------------------------------------------

-- Within 15 yards: hidden, kept; walking away, shown at the next sweep.
fresh()
na = node("Silverleaf", 0, 40)
step(1)
WoW.pos[1] = na.north - 14
C.frame()
eq(shown(), false, "within 15 yards: hidden")
check(at(na), "...the target kept")
WoW.pos[1] = na.north - 30
C.frame()
eq(shown(), false, "walking away: still hidden until a sweep")
step(1)
check(shown(), "...shown at the next sweep")
-- A node above: not hidden within 15 yards; level again, hidden.
na.text = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16|tSilverleaf"
step(1)
eq(target().height, "above", "the node above")
WoW.pos[1] = na.north - 14
C.frame()
check(shown(), "...within 15 yards but above: still shown")
na.text = nil
step(1)
eq(target().height, nil, "...level again: no height")
eq(shown(), false, "...hidden within 15 yards")
-- The position or facing unreadable; no recent sweep; dead; a taxi: hidden, then shown again.
local function hides(label, set, unset)
    fresh()
    node("Silverleaf", 0, 40)
    step(1)
    set()
    C.frame()
    eq(shown(), false, label .. ": hidden")
    unset()
    step(1)
    check(shown(), "...shown again")
end
hides("the position unreadable", function() WoW.posSecret = true end, function() WoW.posSecret = false end)
hides("the facing unreadable", function() WoW.facing = nil end, function() WoW.facing = 0 end)
hides("no recent sweep", function() WoW.now = WoW.now + NR.db.interval + 3 end, function() end)
hides("dead", function() WoW.dead = true end, function() WoW.dead = false end)
hides("on a taxi", function() WoW.onTaxi = true end, function() WoW.onTaxi = false end)
-- Records cleared: hidden at once.
for _, ev in ipairs({ "PLAYER_DEAD", "LOADING_SCREEN_ENABLED", "MINIMAP_UPDATE_TRACKING" }) do
    fresh()
    node("Silverleaf", 0, 40)
    step(1)
    WoW.fire(ev)
    eq(target(), nil, ev .. ": no target")
    eq(shown(), false, "...hidden")
    if ev == "LOADING_SCREEN_ENABLED" then WoW.fire("LOADING_SCREEN_DISABLED") end
end
-- The compass or the radar off.
fresh()
node("Silverleaf", 0, 40)
step(1)
NR.Set("compass", false)
eq(target(), nil, "the compass off: no target")
eq(shown(), false, "...hidden")
NR.Set("compass", true)
step(1)
NR.Set("enabled", false)
eq(shown(), false, "the radar off: hidden")
NR.Set("enabled", true)

-- The learner starting in the same step, with no tracking event at all.
fresh()
node("Silverleaf", 0, 40)
step(1)
local consider, busy = NR.Learn.Consider, NR.Learn.Busy
local started = false
NR.Learn.Consider = function() started = true end
NR.Learn.Busy = function() return started end
step(1)
NR.Learn.Consider, NR.Learn.Busy = consider, busy
eq(target(), nil, "the learner starting, no event: no target")
eq(shown(), false, "...no ring")
eq(#T.records(), 0, "...no records")

--------------------------------------------------------------------------------
-- The records for both: each setting its own part
--------------------------------------------------------------------------------

fresh()
node("Silverleaf", 0, 40)
step(1)
local kept = #T.records()
check(kept > 0, "records kept for the compass alone")
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
eq(#T.records(), kept, "the compass off: the records kept for the icons")
NR.Set("icons", false)
eq(#T.records(), 0, "both off: cleared")
NR.Set("compass", true)

-- /nr compass and the Options page.
fresh()
node("Silverleaf", 0, 40)
step(1)
SlashCmdList.NODERADAR("compass")
eq(NR.db.compass, false, "/nr compass: off")
eq(shown(), false, "...the ring hidden")
SlashCmdList.NODERADAR("compass")
eq(NR.db.compass, true, "...and on")
NR.Options._test.panel:Show()
local cb = NR.Options._test.checks.compass
check(cb and cb:GetChecked(), "Options: the experimental checkbox reads on")
WoW.click(cb)
eq(NR.db.compass, false, "...a click turns it off")

eq(WoW.softCursor, false, "the soft cursor is off")
checkMethods({ "Texture:SetRotation", "FontString:SetText" })
done("test_compass")
