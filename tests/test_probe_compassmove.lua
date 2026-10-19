-- The compassmove procedure (/fp steps nr compassmove, #57): the grip with Alt
-- over the compass, a drag saved and placed, back after a reload, clamped at
-- the screen's edge, locked, reset; the place, lock and settings put back.
-- Runs locally only (ForeverProbe is private; CI skips it).
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
local function settle()
    for _ = 1, 6 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/compassmove"] end
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
local C = NR.Compass._test

walk(1)
fp("steps nr compassmove")
WoW.advance(1.1)
eq(result(1).status, "done", "ready: " .. detail(1))
leaf = { north = WoW.pos[1] + 40 * K(), west = WoW.pos[2] }
walk(3)
eq(result(2).status, "done", "shown: " .. detail(2))
walk(1.2)
eq(result(3).status, nil, "no Alt: waits")
WoW.altDown, WoW.mouseOver = true, C.hit
walk(1.2)
eq(result(3).status, "done", "the grip: " .. detail(3))
settle()
S.Answer(true)                                             -- 4
walk(1.2)
eq(result(5).status, nil, "not moved yet: waits")
C.grip._scripts.OnDragStart(C.grip)
WoW.dropAt = { 960 + 400, 540 + 200 }
C.grip._scripts.OnDragStop(C.grip)
walk(1.2)
eq(result(5).status, "done", "moved: " .. detail(5))
check(detail(5):find("saved 400, 200; anchored CENTER 400, 200"), "...saved and anchored: " .. detail(5))
settle()
S.Skip()                                                   -- 6: the reload
walk(2)
eq(result(7).status, "done", "after the reload: " .. detail(7))
settle()
S.Answer(true)                                             -- 8
walk(1.2)
eq(result(9).status, nil, "not at the edge: waits")
C.grip._scripts.OnDragStart(C.grip)
WoW.dropAt = { 2400, 540 }
C.grip._scripts.OnDragStop(C.grip)
walk(1.2)
eq(result(9).status, "done", "at the edge: " .. detail(9))
check(detail(9):find("saved 922, 0"), "...clamped: " .. detail(9))
settle()
S.Answer(true)                                             -- 10
S.Answer(true)                                             -- 11
walk(1.2)
eq(result(12).status, nil, "not locked: waits")
SlashCmdList.NODERADAR("compass lock")
walk(1.2)
eq(result(12).status, "done", "locked: " .. detail(12))
SlashCmdList.NODERADAR("compass reset")
walk(1.2)
eq(result(13).status, "done", "reset: " .. detail(13))
settle()
eq(result(14).status, "done", "put back: " .. detail(14))
eq(rawget(NR.db, "compassX"), nil, "the place back (home)")
eq(rawget(NR.db, "compassLock"), nil, "the lock back")
eq(rawget(NR.db, "compass"), nil, "the compass back")
eq(record().at, 15, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 2, "only the two commands' replies in chat")
done("test_probe_compassmove")
