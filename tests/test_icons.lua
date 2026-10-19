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
NR.db.iconStyle = "plain"                                  -- #28's icon (the looks: test_styles)
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
eq(reads - plain, 33, "a new node: 32 reads to measure it (#47's walk: 31 to 33), 1 to put the mouseover back")
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
local original = records()[1]
local _, swept = step()
local b1 = swept.byName.Silverleaf[1]
check(b1.record == original, "one blip matches one record (the nearer), one to one")
eq(twin.misses, 0, "...the twin, 5 units off inside its square, is covered, not missed (the merged-pair rule)")

-- The owner's two Silverleafs: two of a name whose squares nearly touch come out
-- of a sweep as one blip between them (26 apart, here from x = 3; 7.5 units on,
-- the same pair splits). Their records stay, covered; the merged blip isn't measured.
reset()
NR.db.interval = 5
WoW.pos = { 0, 0, 1 }
local pa = node("Silverleaf", 3, 0)
step()
local ra = records()[1]
check(ra and near(ra.x, 3), "A measured alone")
local pb = node("Silverleaf", 29, 0)
local rb = {}
for k, v in pairs(ra) do rb[k] = v end                     -- B's record, as if measured from elsewhere
rb.frame, rb.west = nil, pb.west
table.insert(records(), rb)
NR.Set("compass", true)
local plainMerged = plainReads()
local readsMerged, sweptMerged = step()
local compassTarget = NR.Compass._test.target()
check(compassTarget == ra or compassTarget == rb, "the compass on one of the pair")
eq(#sweptMerged.byName.Silverleaf, 1, "the sweep merges them: one Silverleaf blip")
local mb = sweptMerged.byName.Silverleaf[1]
check(mb.points and #mb.points == mb.cells, "...its cells kept (b.points)")
local c1 = mb.points[1]
check(c1[1] - 99 > -40 and c1[1] - 99 < 60, "...in the map's coordinates (from the bottom left): " .. tostring(c1[1]))
eq(ra.misses, 0, "A covered, not missed")
eq(rb.misses, 0, "B covered, not missed")
eq(readsMerged, plainMerged, "...the merged blip not measured (no reads)")
for _ = 1, 7 do step() end                                 -- past RETRY
eq(#records(), 2, "over sweeps past RETRY: both records kept")
eq(NR.Compass._test.target(), compassTarget, "...the compass on the same record throughout (no flip)")
NR.Set("compass", false)
local readsLater = step()
eq(readsLater, plainReads(), "...and still no measuring reads")
-- One miss, then covered again: shown again, its height kept.
ra.misses, ra.height = 1, "above"
step()
eq(ra.misses, 0, "a record with one miss recovered by covering")
eq(ra.height, "above", "...its height kept")
check(ra.frame and ra.frame._shown, "...its icon shown")
ra.height = nil
-- Split again (the player 7.5 units on): matched one to one, the same records.
WoW.pos[2] = WoW.pos[2] + 7.5 * K()                        -- the dots 7.5 units left: from 10.5
local _, sweptSplit = step()
eq(#sweptSplit.byName.Silverleaf, 2, "7.5 units on: two blips")
local ka, kb
for _, bb in ipairs(sweptSplit.byName.Silverleaf) do
    if bb.record == ra then ka = true elseif bb.record == rb then kb = true end
end
check(ka and kb and #records() == 2, "...each matched to its own record, the same objects")
-- A record no cell covers is still missed.
pb.gone = true
local function placeLive() local l = {}; for _, n in ipairs(nodes) do if not n.gone then l[#l + 1] = n end end; return l end
nodes = placeLive()
step()
eq(rb.misses, 1, "B's node gone: missed (no cell in its square)")
step()
eq(#records() == 1 and records()[1] == ra, true, "...dropped at the second, A left")
-- A Silverleaf straight above, its column but not its square: covers nothing.
nodes = {}
local above = node("Silverleaf", 3, 30)
local _, sweptAbove = step()
eq(#sweptAbove.byName.Silverleaf, 1, "A gone, a Silverleaf 30 above its spot")
eq(ra.misses, 1, "...A not covered by it (same column, not its square)")
local _ = above
nodes = { pa }
step()
-- Another name's cells cover nothing.
local stale = {}
for k, v in pairs(ra) do stale[k] = v end
stale.frame, stale.name = nil, "Wilted Peacebloom"
table.insert(records(), stale)
step(); step()
local stillStale = false
for _, rr in ipairs(records()) do if rr == stale then stillStale = true end end
eq(stillStale, false, "a Silverleaf's cells don't keep a Wilted Peacebloom record")
-- The accepted limit: a stale record kept by a neighbour on the diagonal (12, 12 off;
-- up to 25 on each axis when a sample lands in the overlap).
reset()
WoW.pos = { 0, 0, 1 }
local gone1 = node("Silverleaf", 0, 30)
step()
local rg = records()[1]
nodes = {}
local nb = node("Silverleaf", 12, 42)                      -- 12 right and 12 up of the gone one
step(); step()
local keptStale = false
for _, rr in ipairs(records()) do if rr == rg then keptStale = true end end
check(keptStale, "the accepted limit: a gone node's record kept while a neighbour's square overlaps it (diagonal)")
local _ = gone1, nb
-- The rim: covered in the band, dropped past it.
reset()
WoW.pos = { 0, 0, 1 }
local inner = node("Silverleaf", 50, 0)
step()
local rr0 = records()[1]
nodes = {}
local rim = node("Silverleaf", 88, 0)
local band = {}
for k, v in pairs(rr0) do band[k] = v end
band.frame, band.west = nil, rim.west                      -- a record at the rim node, as if measured before
table.insert(records(), band)
step()
eq(band.misses, 0, "a record in the rim band (88 out) covered by its blip")
WoW.pos[2] = WoW.pos[2] + 6 * K()                          -- the node now 94 out: past the drop
step()
local stillBand = false
for _, rx in ipairs(records()) do if rx == band then stillBand = true end end
eq(stillBand, false, "...past the rim (94 out): dropped, covered or not")
local _ = inner
NR.db.interval = nil

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

-- Four refused nearer the centre and an isolated fifth (Codex, #28), at the
-- 5 s idle interval: the fifth is measured at the second sweep. The four are
-- too wide to be one node (40-unit areas): 35 apart, #47's walk measures them.
reset()
NR.db.interval = 5
for _, x in ipairs({ -67.5, -22.5, 22.5, 67.5 }) do
    local n = node("Wilted Peacebloom", x, 0)
    n.half = 20
end
local fifth = node("Wilted Peacebloom", 0, 70)
step()
eq(#records(), 0, "first sweep: the four nearest tried, all refused")
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

-- A gather drops the near record of its name. Its dot stays while the loot
-- window is open: left out, not measured again (the owner's video: the
-- compass took it for the nearest and hid); gone, a node there is measured.
reset()
WoW.pos = { 0, 0, 1 }
local picked = node("Silverleaf", 3, 2)
local other = node("Silverleaf", 3, 32)                   -- another of its name 30 units off
step()
eq(#records(), 2, "a node at the player's feet, another 30 units off")
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-1", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 2366)
eq(#records(), 1, "gathered: its record dropped, the other kept")
eq(#T.gone(), 1, "...remembered as gone")
plain = plainReads()
reads = step()
eq(reads - plain, 0, "its dot still there (the loot open): not measured")
eq(#records(), 1, "...no record of it")
step()
eq(#records(), 1, "...nor at the next sweep")
local beside = node("Wilted Peacebloom", -2, -1)           -- another herb by the same spot
step()
local besideRec
for _, rr in ipairs(records()) do if rr.name == "Wilted Peacebloom" then besideRec = rr end end
check(besideRec, "...a Wilted Peacebloom by it: measured all the same (only the gathered name is left out)")
for i, n in ipairs(nodes) do if n == beside then table.remove(nodes, i) end end
step(); step()
eq(#T.gone(), 1, "...still remembered while seen")
picked.gone = true                                         -- looted: the dot goes
local function placeGone() local list = {}; for _, n in ipairs(nodes) do if not n.gone then list[#list + 1] = n end end; return list end
nodes = placeGone()
step()
eq(#T.gone(), 0, "the dot gone: forgotten")
nodes[#nodes + 1] = picked                                  -- a node of the name there again
picked.gone = nil
plain = plainReads()
reads = step()
eq(reads - plain, 33, "...and a node there after is measured")
eq(#records(), 2, "...its record back")
local _ = other
-- Gathered before it was measured: left out by the player's position.
reset()
WoW.pos = { 0, 0, 1 }
node("Silverleaf", 3, 2)
NR.db.interval = 2
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-2", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", 2366)
eq(#T.gone(), 1, "gathered with no record: remembered at the player's position")
check(T.gone()[1].yards == Icons.GATHERED, "...within GATHERED yards")
step()
eq(#records(), 0, "...its dot not measured")
-- LINGER: an entry seen for good (loot left open) goes after 30 s.
for _ = 1, 31 do step() end
eq(#T.gone(), 0, "seen for 30 s: forgotten (LINGER)")
eq(#records(), 1, "...and the dot measured after all")
NR.db.interval = nil
-- Records cleared forget them.
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-3", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3", 2366)
eq(#T.gone(), 1, "gathered again: remembered")
Icons.Clear()
eq(#T.gone(), 0, "Icons.Clear: forgotten")
-- An instance change forgets them too: a node of the name there is measured (Codex).
step()
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-4", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-4", 2366)
eq(#T.gone(), 1, "gathered: remembered")
WoW.pos[3] = 2                                             -- another instance, same spot
step()
eq(#T.gone(), 0, "another instance: forgotten")
check(#records() == 1, "...the dot there measured in it")
WoW.pos[3] = 1

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
eq(reads - plain, 34, "a new instance: cleared and measured anew (33 + 1)")
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
check(m.why and m.why:find("^not one node: 3%d%.%d wide .*, 3%d%.%d tall"), "two merged diagonally (Codex's pair): refused, "
    .. "both widths said: " .. tostring(m.why))
WoW.blips = { { "Silverleaf", 0, 0 }, { "Silverleaf", 14, 0 } }
m = centre("Silverleaf", 7, 0)
check(m.why and m.why:find("^not one node: 3%d%.%d wide %(%d+%.%d left, %d+%.%d right%), 2%d%.%d tall"),
    "two merged along an axis: refused, too wide only: " .. tostring(m.why))
WoW.blips = { { "Silverleaf", 0, 0 }, { "Silverleaf", Scan.FAR, 0 } }
m = centre("Silverleaf", 0, 0)
eq(m.why, "crowded: its name again past the right", "another of its name at the far point: crowded, the side said")
-- Two of a name with a gap between their squares (#47's dumps: 35 apart): each measured.
local half = WoW.BLIP_HALF
WoW.BLIP_HALF = 12.5                                       -- the measured 25-unit square
for _, apart in ipairs({ 35, 30 }) do
    for _, axis in ipairs({ "x", "y" }) do
        local ox, oy = axis == "x" and apart or 0, axis == "y" and apart or 0
        WoW.blips = { { "Silverleaf", 0, 0 }, { "Silverleaf", ox, oy } }
        local a1 = centre("Silverleaf", 2, -3)                 -- centroids off their centres
        local a2 = centre("Silverleaf", ox - 3, oy + 2)
        check(near(a1.cx, 0) and near(a1.cy, 0) and near(a2.cx, ox) and near(a2.cy, oy),
            ("%d apart on %s: both measured on their centres (%s; %s)"):format(apart, axis, tostring(a1.why),
                tostring(a2.why)))
    end
end
-- A gap under a step (26 apart): measured from a centroid that steps into it,
-- refused from one that steps over it; never off-centre (Codex, #47).
WoW.blips = { { "Silverleaf", 0, 0 }, { "Silverleaf", 26, 0 } }
m = centre("Silverleaf", 1, 0)
check(near(m.cx, 0) and near(m.cy, 0), "26 apart, a centroid 1 off: steps into the gap, measured")
m = centre("Silverleaf", 0, 0)
eq(m.why, "crowded: its name again past the right", "26 apart, a centroid on the centre: steps over it, refused")
WoW.BLIP_HALF = half
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
