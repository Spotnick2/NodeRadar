-- Scan: one sweep reads the blips, groups same-name hits into separate blips,
-- and turns the soft cursor off on every path.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local NR = loadAddon()
local Scan = NR.Scan

-- The cursor in the world; nothing on the map.
WoW.leaveMap()
local r = Scan.Sweep()
check(r ~= nil, "a sweep of an empty map succeeds")
eq(#r.blips, 0, "...with no blips")
eq(WoW.softCursor, false, "...and the soft cursor off")

-- Two herbs of one name, apart, and a quest: two blips of the name, each where it is.
WoW.blips = {
    { "Peacebloom", 30, -20 },
    { "Peacebloom", -60, 40 },
    { "Carry Your Weight", 80, -80 },
}
r = Scan.Sweep()
eq(Scan.Count(r, "Peacebloom"), 2, "two Peaceblooms: two blips, not one average")
eq(Scan.Count(r, "Carry Your Weight"), 1, "the quest")
eq(Scan.Count(r, "Silverleaf"), 0, "a name not there counts 0")
local near = {}
for _, b in ipairs(r.byName.Peacebloom) do
    if (b.x - 30) ^ 2 + (b.y + 20) ^ 2 < 16 then near.a = true end
    if (b.x + 60) ^ 2 + (b.y - 40) ^ 2 < 16 then near.b = true end
    check(b.cells >= 2, "a blip covers several cells: " .. b.cells)
end
check(near.a and near.b, "each blip at its herb (within 4 units)")
eq(WoW.softCursor, false, "the soft cursor off after a sweep")
eq(r.geometry.w, 198, "the geometry rides along")

-- With the cursor on the map, the mouseover goes back to it after the sweep.
WoW.hover(30, -20)
Scan.Sweep()
local tip = C_TooltipInfo.GetMinimapMouseover()
eq(tip and tip.lines[1].leftText, "Peacebloom", "the mouseover put back on the cursor")
WoW.leaveMap()

-- A throw inside the grid fails the sweep and still turns the soft cursor off.
WoW.mouseoverThrows = true
local none, why = Scan.Sweep()
WoW.mouseoverThrows = false
eq(none, nil, "a throwing read fails the sweep")
check(why and why:find("GetMinimapMouseover failed"), "...saying why: " .. tostring(why))
eq(WoW.softCursor, false, "...with the soft cursor off")
check(NR.failures.sweep, "...recorded as a failure")

-- A secret name fails the sweep (never a guessed name).
WoW.secretNames = true
none, why = Scan.Sweep()
WoW.secretNames = false
eq(none, nil, "a secret line fails the sweep")
check(why and why:find("secret"), "...saying so")
eq(WoW.softCursor, false, "...with the soft cursor off")

-- Unreadable geometry: no sweep, and the soft cursor never turned on.
local rect = Minimap._rect
Minimap._rect = nil
WoW.softCursor = nil
none = Scan.Sweep()
Minimap._rect = rect
eq(none, nil, "no geometry, no sweep")
eq(WoW.softCursor, nil, "...the soft cursor untouched")

-- The cost: one mouseover read per point, 25 x 25 on a 198-unit map.
local reads = 0
local real = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function() reads = reads + 1; return real() end
Scan.Sweep()
C_TooltipInfo.GetMinimapMouseover = real
eq(reads, 625, "625 points per sweep")

eq(#WoW.chat, 0, "nothing in chat")
done("test_scan")
