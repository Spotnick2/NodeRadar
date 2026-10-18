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
    if (b.x - 30) ^ 2 + (b.y + 20) ^ 2 < 49 then near.a = true end
    if (b.x + 60) ^ 2 + (b.y - 40) ^ 2 < 49 then near.b = true end
end
check(near.a and near.b, "each blip at its herb (within half a step, 7 units)")
eq(WoW.softCursor, false, "the soft cursor off after a sweep")
eq(r.geometry.w, 198, "the geometry rides along")

-- Escape codes out (release check, 70450): a node above the player reads with
-- the position arrow's texture first, quest lines with colours.
WoW.blips = {
    { "Peacebloom", 30, -20, text = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:16:32|tPeacebloom" },
    { "Peacebloom", -60, 40 },
    { "For Honor", 80, -80, text = "For Honor|cffffffff" },
    { "Raider's Bow", -80, -80, text = "- 0/1 Raider's Bow|r" },
}
r = Scan.Sweep()
eq(Scan.Count(r, "Peacebloom"), 2, "a node above the player is the same name: two Peaceblooms")
eq(Scan.Count(r, "For Honor"), 1, "a colour code out")
eq(Scan.Count(r, "- 0/1 Raider's Bow"), 1, "a reset code out")
eq(Scan.Plain("|cnGREEN_FONT_COLOR:Silverleaf|r"), "Silverleaf", "a named colour out")
eq(Scan.Plain("|Hitem:2447|h[Peacebloom]|h"), "[Peacebloom]", "a link keeps its text")
eq(Scan.Plain("|A:atlas:16:16|a Earthroot  "), "Earthroot", "an atlas out, spaces trimmed")
eq(Scan.Plain("|T.:0|t"), "", "nothing but a code: empty")
for name in pairs(r.byName) do check(not name:find("|", 1, true), "no escape left: " .. name) end
WoW.blips = { { "Peacebloom", 30, -20 }, { "Peacebloom", -60, 40 }, { "Carry Your Weight", 80, -80 } }

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

-- A node's blip is never missed (#11): a 17-unit square, wherever it sits
-- against the grid.
local missed = 0
for dx = 0, 13 do
    for dy = 0, 13 do
        WoW.blips = { { "Peacebloom", -40 + dx, 10 + dy } }
        if Scan.Count(Scan.Sweep(), "Peacebloom") ~= 1 then missed = missed + 1 end
    end
end
eq(missed, 0, "a 17-unit blip read at every offset against the grid")
WoW.blips = {}

-- The cost: one mouseover read per point, 14 x 14 on a 198-unit map.
local reads = 0
local real = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function() reads = reads + 1; return real() end
Scan.Sweep()
C_TooltipInfo.GetMinimapMouseover = real
eq(reads, 196, "196 points per sweep, not 625 (#11)")

eq(#WoW.chat, 0, "nothing in chat")
done("test_scan")
