-- Never a yellow dot (#67, docs/PLAN.md): a blip's cells no record explains are
-- measured a node at a time (peeled from the outside), and what stays
-- unexplained gets provisional icons; the stated limits pinned.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5                                       -- a node's square: 25 units (#28's probe)
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.db.iconStyle = "plain"
local Icons, Scan = NR.Icons, NR.Scan
local T = Icons._test
WoW.itemCached[765] = true

-- The world, as in test_icons: nodes at fixed yards, blips where the minimap
-- shows them from the player.
local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y, extra)
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K(), kind = "herbs" }
    for k, v in pairs(extra or {}) do n[k] = v end
    nodes[#nodes + 1] = n
    return n
end
local function where(n) return -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K() end
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        local x, y = where(n)
        list[#list + 1] = { n.name, x, y, kind = n.kind, half = n.half }
    end
    WoW.blips = list
end
local function plainReads()
    place()
    local before = WoW.reads
    Scan.Sweep(function(n) return NR.Learn.Kind(n) and true or false end)
    return WoW.reads - before
end
local function step(dt)
    WoW.now = WoW.now + (dt or 1)
    place()
    local plain = plainReads()
    local before = WoW.reads
    local r = NR.Step(WoW.now)
    return WoW.reads - before - plain, r
end
local function records() return T.records() end
local function provisional() return T.provisional() end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 0.4) end
local function reset()
    nodes = {}
    Icons.Clear()
    WoW.pos = { 0, 0, 1 }
    WoW.now = WoW.now + 30
end
-- Whether every node has a record on its centre; the records' count.
local function exact(list)
    local all = true
    for _, n in ipairs(list) do
        local x, y = where(n)
        local hit = false
        for _, r in ipairs(records()) do
            if r.name == n.name and near(r.x, x) and near(r.y, y) then hit = true end
        end
        all = all and hit
    end
    return all, #records()
end
-- The sweep's blips of a name (merged or not).
local function blipsOf(name)
    place()
    local r = Scan.Sweep(function(n) return NR.Learn.Kind(n) and true or false end)
    return r and r.byName[name] and #r.byName[name] or 0
end

NR.Set("icons", true)
NR.db.interval = 1

-- Pairs merged in the sweep, from a standing start: both exact, at several
-- phases of the grid (the same pair shifted by 1, 3 and 5 units).
local merged = 0
for _, case in ipairs({
    { "on x, 26 apart", 3, 0, 29, 0 },
    { "on x, 30 apart", -15, 30, 15, 30 },
    { "on y, 28 apart", 10, -14, 10, 14 },
    { "on the diagonal", -14, -14, 14, 14 },
    { "lopsided (Codex)", -19, -16, -6, 11 },
}) do
    for _, shift in ipairs({ 0, 1, 3, 5 }) do
        reset()
        local a = node("Silverleaf", case[2] + shift, case[3] + shift)
        local b = node("Silverleaf", case[4] + shift, case[5] + shift)
        local one = blipsOf("Silverleaf") == 1
        if one then merged = merged + 1 end
        local reads = step()
        local ok, count = exact({ a, b })
        check(ok and count == 2, ("a pair %s, shifted %d (%s): two exact records (%d)"):format(case[1], shift,
            one and "merged" or "apart", count))
        check(reads <= Icons.MEASURE_READS, ("...within the ceiling: %d reads (%s, shifted %d)"):format(reads,
            case[1], shift))
        eq(#provisional(), 0, "...no provisional icon left")
    end
end
check(merged >= 12, ("the sweep merged most of those pairs (%d of 20)"):format(merged))

-- The owner's pair, merged: about 30 reads a node peeled after the single
-- measure fails, once; then nothing more.
reset()
node("Silverleaf", 3, 0)
node("Silverleaf", 29, 0)
local reads = step()
check(reads >= 40 and reads <= 110, ("the owner's pair: %d reads to measure both"):format(reads))
for _ = 1, 8 do
    local again = step()
    eq(again, 0, "...then no measuring reads")
end
eq(#records(), 2, "...two records kept")

-- A pair with one record already: the other peeled, no duplicate.
reset()
local pa = node("Silverleaf", 3, 0)
step()
eq(#records(), 1, "A measured alone")
local pb = node("Silverleaf", 29, 0)
eq(blipsOf("Silverleaf"), 1, "B beside it: one blip")
step()
local ok, count = exact({ pa, pb })
check(ok and count == 2, "...B peeled, A kept, no duplicate (" .. count .. ")")

-- Codex's boundary column: explained by the tolerance, no retry, no stray provisional.
reset()
node("Silverleaf", -10, -5)
node("Silverleaf", 16, -5)
step()
eq(#records(), 2, "the boundary pair: two records")
for _ = 1, 8 do eq(step(), 0, "...no measuring past RETRY") end
eq(#provisional(), 0, "...no stray provisional icon")
eq(#T.tries(), 0, "...nothing left to try")

-- A compact triple, at two phases: the outer two exact, the middle exact or
-- under provisional icons (the stated limit).
for _, shift in ipairs({ 0, 1 }) do
    reset()
    local t1 = node("Silverleaf", shift, shift)
    local t2 = node("Silverleaf", 13 + shift, 13 + shift)
    local t3 = node("Silverleaf", 26 + shift, 26 + shift)
    step()
    local outer = exact({ t1, t3 })
    check(outer, "a compact triple shifted " .. shift .. ": the outer two exact")
    local middle = exact({ t2 })
    check(middle or #provisional() > 0, ("...the middle exact (%s) or provisional (%d)"):format(tostring(middle),
        #provisional()))
end

-- A close pair (under a node's half apart): one icon over both, the stated limit.
reset()
node("Silverleaf", 2.75, 2.75)
node("Silverleaf", 10.95, 10.95)
step()
eq(#records() + #provisional(), 1, "a close pair: one icon (the stated limit)")

-- Three in a row 12 apart: the middle wholly inside the others, not found.
reset()
local r1, _, r3 = node("Silverleaf", 0, 0), node("Silverleaf", 12, 0), node("Silverleaf", 24, 0)
step()
local both = exact({ r1, r3 })
check(both and #records() == 2 and #provisional() == 0, "three in a row 12 apart: the outer two, the middle not found (the limit)")

-- Provisional icons: a node waiting for its measure (four a sweep) gets one.
reset()
local five = {}
for i, at in ipairs({ { -50, 40 }, { 0, 40 }, { 50, 40 }, { -50, -40 }, { 50, -40 } }) do
    five[i] = node("Silverleaf", at[1], at[2])
end
step()
eq(#records(), 4, "five new nodes: four measured")
eq(#provisional(), 1, "...the fifth under a provisional icon")
local p = provisional()[1]
check(p and p.frame and p.frame._shown and p.provisional, "...shown")
local fifth
for _, n in ipairs(five) do if not exact({ n }) then fifth = n end end
local fx, fy
if fifth then fx, fy = where(fifth) end
check(p and fx and near(p.x, fx, 6) and near(p.y, fy, 6), "...near the fifth")
local inRecords = false
for _, r in ipairs(Icons.Records()) do if r == p then inRecords = true end end
eq(inRecords, false, "...not a record (the compass never sees it)")
local frames = T.frames
step()
eq(#records(), 5, "the next sweep: the fifth measured")
eq(#provisional(), 0, "...its provisional icon gone")
eq(p.frame, nil, "...its frame released")
eq(T.frames, frames, "...no new frame")

-- A wide shape no peel explains (a 40-unit area of a node's name): two
-- provisional icons; frames reused sweep after sweep.
reset()
node("Silverleaf", 0, 30, { half = 20 })
step()
eq(#records(), 0, "a 40-unit area: no record")
eq(#provisional(), 2, "...two provisional icons (wider than a node)")
frames = T.frames
for _ = 1, 10 do step() end
eq(T.frames, frames, "...rebuilt each sweep on the same frames")
eq(#provisional(), 2, "...still two")

-- Suspension: retried at 5, 10, 20, 40, then every 60 s, no reads between;
-- the player riding back and forth doesn't re-arm it.
reset()
node("Silverleaf", 0, 30, { half = 20 })
local first = step()
check(first > 0, "the area tried once: " .. first .. " reads")
local tried, t0 = {}, WoW.now
for s = 1, 140 do
    if s % 2 == 0 then WoW.pos[2] = WoW.pos[2] + 7 * K() else WoW.pos[2] = WoW.pos[2] - 7 * K() end
    local n = step()
    if n > 0 then tried[#tried + 1] = WoW.now - t0 end
end
local want = { 5, 15, 35, 75, 135 }
local sameTimes = #tried == #want
for i, v in ipairs(want) do sameTimes = sameTimes and tried[i] ~= nil and math.abs(tried[i] - v) <= 1 end
check(sameTimes, "...retried at 5, 15, 35, 75, 135 s while riding: " .. table.concat(tried, ", "))
-- A zoom (the view's radius) re-arms it at 5 s.
reset()
node("Silverleaf", 0, 30, { half = 20 })
step()
for _ = 1, 40 do step() end                                -- tried at 5, 15, 35: the next wait 40 s
WoW.viewRadius = { [0] = 150, [1] = 100 }
Minimap._zoom = 1
local rearmed
for s = 1, 12 do if step() > 0 then rearmed = s; break end end
check(rearmed and rearmed <= 6, "...a zoom: re-armed, tried within 5 s (" .. tostring(rearmed) .. ")")
Minimap._zoom = 0

-- Scan.Centre by hand: a peel's node must hold the cell it started from (the
-- walk out crossed a 1-unit gap into a neighbour: refused), and a node already
-- known (a record 3 units off) is never found again.
local function blipAt(name, cells, extra)
    local b = { name = name, points = {} }
    for i, c in ipairs(cells) do b.points[i] = { c[1] + 99, c[2] + 99, col = i, row = 0 } end
    b.x, b.y = cells[1][1], cells[1][2]
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end
WoW.blips = { { "Silverleaf", 20, 0 }, { "Silverleaf", -6, 0 } }
local hb = blipAt("Silverleaf", { { 8.5, 0 } })
Scan.Centre({ hb }, 1000, 8)
check(#hb.found == 1 and near(hb.found[1][1], 20) and near(hb.found[1][2], 0),
    ("a cell by a gap: only its own node found (%d)"):format(#hb.found))
WoW.blips = { { "Silverleaf", 0, 0 } }
local kb = blipAt("Silverleaf", { { -12, 0 } }, { known = { { 3, 0 } } })
Scan.Centre({ kb }, 1000, 8)
eq(#kb.found, 0, "a node 3 units from a record: known, not found again")
check(kb.why and kb.why:find("is known"), "...said: " .. tostring(kb.why))

-- The read ceiling: many shapes no peel explains, measuring stops near 200 a sweep.
reset()
for _, x in ipairs({ -60, -15, 30 }) do node("Silverleaf", x, -40, { half = 20 }) end
node("Silverleaf", 0, 45, { half = 20 })
reads = step()
check(reads <= Icons.MEASURE_READS + 60, ("four areas: %d reads, the ceiling %d (a try finishes)"):format(reads,
    Icons.MEASURE_READS))
check(reads >= Icons.MEASURE_READS, "...the ceiling reached")

-- The rim: a merged pair reaching it, the inner node peeled, the outer refused
-- (its square past the round map): a provisional icon, under the rim exception.
reset()
local inner = node("Silverleaf", 61, 0)
local outer = node("Silverleaf", 86, 0)                    -- its square's corners 99.3 out: past 97
eq(blipsOf("Silverleaf"), 1, "an inner node and one at the rim: one blip")
step()
check(exact({ inner }), "...the inner node exact")
check(not exact({ outer }), "...the outer one not measured (the rim)")
eq(#provisional(), 1, "...a provisional icon for it")

-- Filtered blips get none: a gathered dot lingering.
reset()
node("Silverleaf", 40, 40, { half = 20 })
step()
check(#provisional() > 0, "provisional icons for an area")
WoW.pos = { 40 * K(), -40 * K(), 1 }                       -- the player on it
NR.Icons.Gathered("Silverleaf")
eq(#provisional(), 0, "a gather: the near provisional icons go at once")
step()
eq(#provisional(), 0, "...and the lingering dot gets none")

-- Cleared with the records; gone with the icons off, the compass on.
reset()
node("Silverleaf", 0, 30, { half = 20 })
step()
local pf = provisional()[1] and provisional()[1].frame
Icons.Clear()
eq(#provisional(), 0, "Icons.Clear: no provisional icon")
check(pf and not pf._shown, "...its frame hidden")
step()
NR.Set("compass", true)
pf = provisional()[1] and provisional()[1].frame
check(pf and pf._shown, "a provisional icon shown")
NR.Set("icons", false)
eq(#provisional(), 0, "the icons off, the compass on: no provisional icon at once")
check(not pf._shown, "...its frame hidden")
step()
eq(#provisional(), 0, "...nor at the next sweep")
NR.Set("icons", true)
NR.Set("compass", false)
step()
check(#provisional() > 0, "the icons on again: provisional icons back")
WoW.fire("MINIMAP_UPDATE_TRACKING")
eq(#provisional(), 0, "a clear (the learner's): none")

-- A secret read inside a peel fails the measure, the soft cursor off.
reset()
place()
WoW.blips = { { "Silverleaf", 3, 0 }, { "Silverleaf", 29, 0 } }
local sw = Scan.Sweep(function() return true end)
local mb = sw.byName.Silverleaf[1]
mb.known = { { 3, 0 } }                                    -- A known: peeling starts at once
WoW.secretNames = true
local okC = Scan.Centre({ mb }, 200, 8)
WoW.secretNames = false
eq(okC, nil, "a secret read in a peel: the measure fails")
eq(WoW.softCursor, false, "...the soft cursor off")
eq(mb.found and #mb.found or 0, 0, "...nothing found")

done("test_nodots")
