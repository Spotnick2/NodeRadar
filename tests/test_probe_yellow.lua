-- The yellow procedure (/fp steps nr yellow, #50): Blizzard's dots with the
-- icons off, the icons in yellow at each size, the height arrow and the dim,
-- the compass's rim in yellow, the narrower arrow at the four diagonals; the
-- settings put back. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
WoW.itemCached[765] = true
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
    for _ = 1, 6 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/yellow"] end
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

walk(1)
WoW.facing = 0
fp("steps nr yellow")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.icons, false, "...the icons off for the dots")
eq(NR.db.iconStyle, "yellow", "...the frame yellow")
eq(NR.db.compass, true, "...the compass on")
leaf = { north = WoW.pos[1] + 40 * K(), west = WoW.pos[2] }
walk(2)
settle(); S.Next(); settle()                               -- 2 the dots
walk(2)
eq(result(3).status, "done", "medium: " .. detail(3))
check(detail(3):find("yellow 12"), "...yellow at 12: " .. detail(3))
settle(); poll(); settle(); poll(); settle()
check(detail(4):find("yellow 10") and detail(5):find("yellow 14"), "the sizes: " .. detail(4) .. ", " .. detail(5))
eq(record().at, 6, "asked")
S.Answer(true)                                             -- 6
walk(1.2)
eq(result(7).status, nil, "a level node: waits for an arrow")
S.Skip(); S.Skip()                                         -- 7 the arrow, 8 dimmed
walk(1.2)
eq(result(9).status, "done", "the compass: " .. detail(9))
check(detail(9):find("^true, \"yellow medium"), "...yellow medium: " .. detail(9))
settle()
S.Answer(true)                                             -- 10
-- The diagonals: the node due north, the facing turned.
for i, case in ipairs({ { 11, -math.pi / 4 }, { 12, math.pi / 4 }, { 13, 5 * math.pi / 4 }, { 14, 3 * math.pi / 4 } }) do
    if i == 1 then
        walk(1.2)
        eq(result(11).status, nil, "the node ahead isn't ahead-left: waits")
    end
    WoW.facing = case[2]
    walk(1.2)
    eq(result(case[1]).status, "done", "diagonal " .. i .. ": " .. detail(case[1]))
    settle()
end
eq(NR.db.iconStyle, "yellow", "the headings kept yellow")
S.Answer(true)                                             -- 15
eq(result(16).status, "done", "put back: " .. detail(16))
eq(rawget(NR.db, "compass"), nil, "the compass back")
eq(rawget(NR.db, "icons"), nil, "the icons back")
eq(rawget(NR.db, "iconStyle"), nil, "the frame back")
eq(rawget(NR.db, "iconSize"), nil, "the size back")
eq(record().at, 17, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_yellow")
