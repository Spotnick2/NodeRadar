-- The nodots procedure (/fp steps nr nodots, #67): a merged pair after a
-- reload, then a ride; NodeRadar's icons setting put back. Runs locally only
-- (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function logged(pattern)
    for _, l in ipairs(db.log) do if l:find(pattern) then return true end end
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function record() return FP.db.steps.records["NodeRadarProbe/nodots"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

eq(NR.db.icons, false, "the icons off before")
WoW.blips = { { "Silverleaf", 3, 0, kind = "herbs" }, { "Silverleaf", 29, 0, kind = "herbs" } }
fp("steps nr nodots")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.icons, true, "...the icons on for the round")
for _ = 1, 3 do poll() end
S.Run()                                                    -- 2: Ready, at the pair
poll()
eq(result(2).status, "done", "at the pair: " .. detail(2))
check(detail(2):find("2 records, 0 provisional, 0 unexplained %(Silverleaf 2%+0%)"), "...both measured")
check(logged("  blip Silverleaf at"), "...the dump logged")
FP.run = FP.run + 1                                        -- 3: the reload
S.Resume()
eq(result(3).status, "done", "reloaded: " .. detail(3))
NR.Icons.Clear()                                           -- a reload starts with no records
for _ = 1, 8 do poll() end
eq(result(4).status, "done", "after the reload: " .. detail(4))
check(detail(4):find("2 records"), "...the pair measured again from a standing start")
eq(WoW.shots and WoW.shots >= 1, true, "...a screenshot")
for _ = 1, 3 do WoW.advance(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end
S.Answer(true)                                             -- 5
for _ = 1, 4 do poll() end
eq(result(6).status, nil, "riding: waits")
WoW.advance(181)
poll()
eq(result(6).status, "done", "the ride: " .. detail(6))
check(detail(6):find("reads with provisional icons, at most %d+ at once; now %d+ records"), "...counted")
S.Answer(false)                                            -- 7
poll()
eq(result(8).status, "done", "put back: " .. detail(8))
eq(NR.db.icons, false, "the icons setting back")
eq(db.nodotsWas, nil, "...the saved setting cleared")
eq(record().at, 9, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_nodots")
