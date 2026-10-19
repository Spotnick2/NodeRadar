-- Icons (#28): a new node's centre measured once (Scan.Centre) and kept in
-- world yards; matched by name and distance after; drawn every frame from the
-- player's position; hidden, dropped and cleared as docs/PLAN.md says. Off,
-- nothing of it runs.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5                                       -- a node's square: 25 units (#28's probe)
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Mageroyal"] = "herbs"
local NR = loadAddon()
local Icons, Scan = NR.Icons, NR.Scan
local T = Icons._test
WoW.itemCached[765] = true                                 -- Silverleaf's item: its icon answers

-- The world: nodes at fixed yards, blips where the minimap shows them from
-- the player (UnitPosition: north, west).
local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y, extra)                     -- at map offset (x, y) from the player now
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K(), kind = "herbs" }
    for k, v in pairs(extra or {}) do n[k] = v end
    nodes[#nodes + 1] = n
    return n
end
local function where(n) return -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K() end
local others = {}
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        local x, y = where(n)
        list[#list + 1] = { n.name, x, y, kind = n.kind, half = n.half }
    end
    for _, b in ipairs(others) do list[#list + 1] = b end
    WoW.blips = list
end
local function step()
    WoW.now = WoW.now + 1
    place()
    local before = WoW.reads
    local r = NR.Step(WoW.now)
    return WoW.reads - before, r
end
local function plainReads()                                -- what the sweep alone reads now
    place()
    local before = WoW.reads
    Scan.Sweep(function(n) return NR.Learn.Kind(n) and true or false end)
    return WoW.reads - before
end
local function records() return T.records() end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 0.4) end
local function at(f) local p = f._points[#f._points]; return p and p[4], p and p[5] end
local function reset()
    nodes, others = {}, {}
    Icons.Clear()
    WoW.now = WoW.now + 30                                 -- past the cooldown and the tries
end

-- Dots, the default: no records, no per-frame update, no extra reads.
eq(NR.db.icons, false, "Blizzard's dots by default")
node("Stunted Silverleaf", 31, -23)
local plain = plainReads()
local reads = step()
eq(reads, plain, "dots: the sweep's reads only")
eq(#records(), 0, "dots: no records")
eq(T.driver._scripts.OnUpdate, nil, "dots: no per-frame update")

-- Icons: a new node's centre measured once, in 29 reads.
reset()
NR.Set("icons", true)
local sonars = {}
local sonar = NR.Alert.Sonar
NR.Alert.Sonar = function(x, y, kind) sonars[#sonars + 1] = { x, y, kind }; return sonar(x, y, kind) end
step()                                                     -- the alert's baseline after the pause
local sl = node("Silverleaf", 31, -23)
plain = plainReads()
local _, r = nil, nil
reads, r = step()
eq(reads - plain, 30, "a new node: 29 reads to measure it, 1 to put the mouseover back")
eq(#records(), 1, "...one record")
local rec = records()[1]
check(near(rec.x, 31) and near(rec.y, -23), ("...at the node's centre: %.2f, %.2f"):format(rec.x, rec.y))
local b = r.byName.Silverleaf[1]
check(not near(b.x, 31) or not near(b.y, -23), ("the sweep's own blip was off it: %.2f, %.2f"):format(b.x, b.y))
local f = rec.frame
check(f and f._shown and f._parent == Minimap and f._mouse == false, "a shown, mouse-through child of Minimap")
local fx, fy = at(f)
check(near(fx, 31) and near(fy, -23), "...drawn at the centre")
eq(f.tex._file, 130765, "...with the item's icon")
eq(f._width, Icons.SIZE, "...12 units square")
check(T.driver._scripts.OnUpdate ~= nil, "the per-frame update on")
eq(#sonars, 1, "the alert's sonar")
check(sonars[1] and near(sonars[1][1], 31) and near(sonars[1][2], -23) and sonars[1][3] == "herbs",
    "...at the record, not the sweep's blip")

-- Matched after: no reads beyond the sweep's.
plain = plainReads()
reads = step()
eq(reads, plain, "matched: no extra reads")
eq(#records(), 1, "...still one record")
check(Scan.Sweep() and #records() == 1, "a sweep outside the radar (the learner's) touches no record")

-- Every frame, from the player's position and the current radius.
WoW.pos[1] = WoW.pos[1] + 10                               -- 10 yd north: the node 10 yd further south
T.draw()
fx, fy = at(f)
check(near(fx, 31) and near(fy, -23 - 10 / K()), ("drawn where the player's move puts it: %.2f, %.2f"):format(fx, fy))
WoW.viewRadius = { [0] = 150, [1] = 100 }
Minimap._zoom = 1
T.draw()
local x1, y1 = where(sl)
fx, fy = at(f)
check(near(fx, x1) and near(fy, y1), "a zoom between sweeps: drawn at the new scale the next frame")
plain = plainReads()
reads = step()
eq(reads, plain, "...and matched at the next sweep without measuring")
Minimap._zoom = 0
WoW.pos[1] = WoW.pos[1] - 10
step()

-- Missed: hidden at once, dropped at the second; its frame reused.
local frames = T.frames
nodes = {}
step()
eq(#records(), 1, "one miss: kept")
eq(f._shown, false, "...but hidden")
step()
eq(#records(), 0, "two misses: dropped")
node("Silverleaf", -20, 40)
step()
eq(#records(), 1, "a new node")
eq(T.frames, frames, "...on a reused frame")

-- Two of a name apart: one record each.
reset()
local a1, a2 = node("Silverleaf", -35, 30), node("Silverleaf", 15, 30)
step()
eq(#records(), 2, "two of a name 50 apart: two records")
local seen = {}
for _, rr in ipairs(records()) do
    for i, n in ipairs({ a1, a2 }) do
        local x, y = where(n)
        if near(rr.x, x) and near(rr.y, y) then seen[i] = true end
    end
end
check(seen[1] and seen[2], "...each at its node")

-- One to one: two records within reach of one blip, one matched, the other missed.
reset()
node("Silverleaf", 20, -20)
step()
local twin = {}
for k, v in pairs(records()[1]) do twin[k] = v end
twin.frame, twin.north = nil, twin.north + 5 * K()          -- a record 5 units off the same blip
table.insert(records(), twin)
step()
local shownCount = 0
for _, rr in ipairs(records()) do if rr.misses == 0 then shownCount = shownCount + 1 end end
eq(shownCount, 1, "one blip matches one record")

-- Crowded: two of a name 30 apart; no record, Blizzard's dots.
reset()
node("Silverleaf", -15, 30)
node("Silverleaf", 15, 30)
step()
eq(#records(), 0, "two of a name 30 apart: crowded, no record")
eq(#T.tries(), 1, "...the one blip they make, its try remembered")
plain = plainReads()
reads = step()
eq(reads, plain, "...and not tried again within 5 s")

-- Four crowded nearer the centre and an isolated fifth (Codex, #28), at the
-- 5 s idle interval: the fifth is measured at the second sweep.
reset()
NR.db.interval = 5
for _, x in ipairs({ -52.5, -17.5, 17.5, 52.5 }) do node("Wilted Peacebloom", x, 0) end
local fifth = node("Wilted Peacebloom", 0, 70)
step()
eq(#records(), 0, "first sweep: the four nearest tried, all crowded")
WoW.now = WoW.now + 4                                      -- the next sweep, 5 s later
step()
eq(#records(), 1, "second sweep: the fifth measured")
local fx5, fy5 = where(fifth)
check(records()[1] and near(records()[1].x, fx5) and near(records()[1].y, fy5), "...at its centre")
NR.db.interval = nil

-- The rim: a blip not whole isn't measured; a record fades out past it.
reset()
local rimNode = node("Silverleaf", 85, 0)
plain = plainReads()
reads = step()
eq(reads, plain, "a blip 85 units out (not 18 inside the rim): not measured")
eq(#records(), 0, "...no record")
WoW.pos[2] = WoW.pos[2] - 20 * K()                         -- 20 units east: the node 65 out
step()
eq(#records(), 1, "whole: measured")
f = records()[1].frame
WoW.pos[2] = WoW.pos[2] + 26 * K()                         -- back west: the node 91 out
T.draw()
check(f._shown and near(f._alpha, 0.5, 0.05), "91 units out: fading (" .. tostring(f._alpha) .. ")")
WoW.pos[2] = WoW.pos[2] + 3 * K()                          -- 94 out: past the icon's edge
T.draw()
eq(f._shown, false, "94 units out: hidden")
step()
eq(#records(), 0, "...and dropped at the sweep")
local _ = rimNode

-- A gather drops the near record of its name, so it's measured anew.
reset()
WoW.pos = { 0, 0, 1 }
node("Silverleaf", 3, 2)
step()
eq(#records(), 1, "a node at the player's feet")
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-1", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 2366)
eq(#records(), 0, "gathered: its record dropped")
plain = plainReads()
reads = step()
eq(reads - plain, 30, "...and the next node there measured, not matched")

-- Skill: a node the player can't gather is dimmed (#26's rule); no item: the
-- tracking spell's icon.
reset()
WoW.skillLines[182] = { skillID = 182, rank = 10, modifier = 0, maxRank = 300 }
node("Mageroyal", -30, -30)
node("Wilted Peacebloom", 30, 30)
step()
local mag, wp
for _, rr in ipairs(records()) do
    if rr.name == "Mageroyal" then mag = rr elseif rr.name == "Wilted Peacebloom" then wp = rr end
end
check(mag and mag.frame.tex._desaturated == true and near(mag.frame._alpha, Icons.DIM), "Mageroyal at 10 skill: dimmed")
check(wp and wp.frame.tex._desaturated == false and near(wp.frame._alpha, 1), "Wilted Peacebloom: not")
eq(wp and wp.frame.tex._file, 136000 + 2383, "...with Find Herbs' icon (no NODE_INFO item)")
WoW.skillLines[182] = nil

-- Hidden while no radar sweep succeeds for the idle interval plus 2 s.
reset()
NR.db.interval = 5
node("Silverleaf", 20, 20)
step()
f = records()[1].frame
WoW.now = WoW.now + 6.5
T.draw()
eq(f._shown, true, "6.5 s after a sweep at a 5 s interval: still shown")
WoW.now = WoW.now + 1
T.draw()
eq(f._shown, false, "7.5 s: hidden")
eq(T.driver._scripts.OnUpdate, nil, "...and the per-frame update off")
step()
eq(f._shown, true, "the next sweep shows it again")
NR.db.interval = nil

-- Cleared: events, the instance, an unreadable position, an instance map, the settings.
local function made()
    reset()
    node("Silverleaf", 20, 20)
    step()
    return #records() == 1
end
for _, ev in ipairs({ "LOADING_SCREEN_ENABLED", "PLAYER_DEAD", "MINIMAP_UPDATE_TRACKING" }) do
    check(made(), "a record before " .. ev)
    WoW.fire(ev)
    eq(#records(), 0, ev .. " clears")
    if ev == "LOADING_SCREEN_ENABLED" then WoW.fire("LOADING_SCREEN_DISABLED") end
end
check(made(), "a record before PLAYER_ENTERING_WORLD")
WoW.fire("PLAYER_ENTERING_WORLD", false, false)
eq(#records(), 0, "PLAYER_ENTERING_WORLD clears")
check(made(), "a record before the instance changes")
WoW.pos[3] = 2
plain = plainReads()
reads = step()
eq(reads - plain, 30, "a new instance: cleared and measured anew")
WoW.pos[3] = 1
check(made(), "a record before the position goes secret")
WoW.posSecret = true
step()
eq(#records(), 0, "a secret position clears")
WoW.posSecret = false
check(made(), "a record before entering an instance")
WoW.instanced = true
step()
eq(#records(), 0, "in an instance: cleared")
WoW.instanced = false
check(made(), "a record before the setting goes off")
f = records()[1].frame
NR.Set("icons", false)
eq(#records(), 0, "icons off: cleared")
eq(f._shown, false, "...the icon hidden")
NR.Set("icons", true)
check(made(), "a record before the radar goes off")
NR.Set("enabled", false)
eq(#records(), 0, "the radar off: cleared")
NR.Set("enabled", true)

-- The learner, after the icons in NR.Step, can clear them at once (Codex, #28).
reset()
node("Silverleaf", 20, 20)
local consider = NR.Learn.Consider
NR.Learn.Consider = function(...) WoW.fire("MINIMAP_UPDATE_TRACKING"); return consider(...) end
step()
NR.Learn.Consider = consider
eq(#records(), 0, "tracking changed by the learner in the same step: nothing left")

-- Scan.Centre alone: merged pairs refused, an overlap of another name fine, a secret read.
local function centre(name, x, y)
    local bb = { name = name, x = x, y = y }
    local ok, why = Scan.Centre({ bb })
    return bb, ok, why
end
WoW.blips = { { "Silverleaf", -7, -7 }, { "Silverleaf", 7, 7 } }
local m = centre("Silverleaf", 0, 0)
eq(m.why, "not one node", "two merged diagonally (Codex's pair): refused")
WoW.blips = { { "Silverleaf", 0, 0 }, { "Silverleaf", 14, 0 } }
m = centre("Silverleaf", 7, 0)
eq(m.why, "not one node", "two merged along an axis: refused")
WoW.blips = { { "Silverleaf", 4, -3 }, { "Carry Your Weight", 10, 0, half = 40 } }
m = centre("Silverleaf", 0, 0)
check(near(m.cx, 4) and near(m.cy, -3), "another name over it: still measured")
WoW.blips = { { "Silverleaf", 0, 0 } }
m = centre("Silverleaf", 40, 40)
eq(m.why, "its centroid reads nothing", "a centroid off the node: refused")
WoW.secretNames = true
local _, ok = centre("Silverleaf", 0, 0)
WoW.secretNames = false
eq(ok, nil, "a secret read fails the measure")
eq(WoW.softCursor, false, "...with the soft cursor off")
check(NR.failures.centre, "...recorded")
eq(WoW.softCursor, false, "the soft cursor off at the end")

done("test_icons")
