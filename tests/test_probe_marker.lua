-- The marker procedure (/fp steps nr marker, NodeSight's far sparkles): our
-- waypoint on the nearest node, our gold square anchored to Blizzard's
-- navigation frame, read with showInGameNavigation as it was and on; turned,
-- behind, far; everything put back (the option, our waypoint). Runs locally
-- only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
local NR = loadAddon()
NR.db.enabled = false                                      -- the probe sweeps; the radar stays out of it
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") and not l:find("UI_ERROR_MESSAGE") then n = n + 1 end end
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
local function record() return FP.db.steps.records["NodeRadarProbe/marker"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.4 }, { 5287, 3525 }
WoW.navFrame = CreateFrame("Frame")
WoW.navFrame._center = { 960 + 40, 540 + 120 }            -- the node ahead, a little right and up
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }

fp("steps nr marker")
poll()
eq(result(1).status, "done", "free: " .. detail(1))
S.Run()                                                    -- 2: Set
eq(result(2).status, "done", "set: " .. detail(2))
eq(WoW.superTracked, "waypoint", "...our waypoint super-tracked")
poll()
eq(result(3).status, "done", "the square: " .. detail(3))
check(detail(3):find("our square at 40, 120 from the screen's centre; showInGameNavigation 0"),
    "...on the navigation frame, the option as it was: " .. detail(3):sub(1, 90))
settle()
S.Answer(true)                                             -- 4
eq(WoW.cvars.showInGameNavigation, "1", "the option turned on (5)")
poll()
eq(result(6).status, "done", "read again: " .. detail(6))
check(detail(6):find("showInGameNavigation 1"), "...with the option on")
settle()
S.Answer(true)                                             -- 7
poll()
eq(result(8).status, nil, "not turned: waits")
WoW.navFrame._center = { 960 - 200, 540 + 120 }           -- turned: the node 240 left
poll()
eq(result(8).status, "done", "turned: " .. detail(8))
check(detail(8):find("our square at %-200, 120"), "...the square followed it")
settle()
S.Answer(true)                                             -- 9
poll()
eq(result(10).status, nil, "not behind: waits")
WoW.navClamped = true
poll()
eq(result(10).status, "done", "behind: " .. detail(10))
settle()
S.Answer(true)                                             -- 11
WoW.navDistance = 60
poll()
eq(result(12).status, nil, "60 yards: waits")
WoW.navDistance = 130
poll()
eq(result(12).status, "done", "far: " .. detail(12))
settle()
S.Answer(true)                                             -- 13
eq(result(14).status, "done", "put back: " .. detail(14))
eq(WoW.cvars.showInGameNavigation, "0", "the option as it was")
eq(WoW.superTracked, nil, "our waypoint's tracking off")
eq(WoW.waypoint, nil, "...and the waypoint cleared")
eq(db.markerCVar, nil, "nothing left saved")
eq(record().at, 15, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_marker")
