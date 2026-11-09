-- The health round (/fp steps nr health): every read wrapped, the lines saved.
-- Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
rawset(_G, "Screenshot", function() end)
rawset(_G, "EnumerateFrames", function() return nil end)
local NR = loadAddon()
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end

fp("steps nr health")
poll()
local rec = FP.db.steps.records["NodeRadarProbe/health"]
check(rec ~= nil, "the health round starts")
S.Run()
poll()
local lines = NodeRadarProbeDB.health and NodeRadarProbeDB.health.lines or {}
local function has(p) for _, l in ipairs(lines) do if l:find(p, 1, true) then return true end end end
check(has("health: build"), "the build line is saved")
check(has("Learn.AnyOn()"), "the gates are saved")
check(has("NR.Step"), "NR.Step's outcome is saved")
check(not has("SECTION FAILED"), "no section failed on the stub")

-- Steps A and B: the soft cursor is off on every path, and each sub-check is logged.
WoW.cursor = { 600, 400 }
WoW.cursorOnMap = true
for _ = 1, 4 do poll() end                                 -- A measures after its 3 s hold
for _, l in ipairs({ "A1", "A2", "A3", "A4", "A5", "A6" }) do check(has("health: " .. l .. " "), l .. " is logged") end
check(has("A3 dot offset"), "A3 remembers the dot")
check(not WoW.softCursor, "the soft cursor is off after A")
WoW.cursor = { 100, 100 }
WoW.cursorOnMap = false
for _ = 1, 4 do poll() end                                 -- B measures; B3b waits for the next frame
check(has("B3b soft cursor on"), "B3b turned the soft cursor on")
check(WoW.softCursor == true, "...and it is on until the next frame")
WoW.flushTimers()
poll()
for _, l in ipairs({ "B1", "B2", "B3a", "B3b a frame later", "B4" }) do check(has("health: " .. l), l .. " is logged") end
check(not WoW.softCursor, "the soft cursor is off after B")

-- Step C: waits while the cursor is on the minimap, then reads in the spaces.
WoW.cursorOnMap = true
for _ = 1, 5 do poll() end
check(has("health: C: waiting: move the mouse off the minimap"), "C waits while the mouse is on the minimap")
check(not has("health: C1 "), "...and reads nothing yet")
WoW.cursorOnMap = false
poll(); poll()
for _, l in ipairs({ "C1 screen", "C2 ui", "C3 local", "C4 local*es", "C5 unit", "C6 centre", "C7 screen", "C8 screen (", "C9 sweep" }) do
    check(has("health: " .. l), l .. " is logged")
end
WoW.flushTimers()
poll()
check(has("C8 screen next frame: read"), "C8 reads on the next frame")
check(not WoW.softCursor, "the soft cursor is off after C")

done("test_probe_health")