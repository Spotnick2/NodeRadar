-- The world procedure (/fp steps nr world, #61): NodeRadar's marker in game,
-- its waypoint and stars, a switch timed, stepping aside for a pin, quests,
-- combat and the map, a reload, the CVar from 0; NodeRadar's setting and the
-- CVar put back at the summary. Runs locally only (ForeverProbe is private;
-- CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "1"                       -- on already: the summary must put back 1, not 0
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
WoW.pos = { 0, 0, 1 }
local NR = loadAddon()
NR.Track.SetSmart(false)
local FP = loadForeverProbe()
local NS = loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y)
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    nodes[#nodes + 1] = n
    return n
end
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
    end
    WoW.blips = list
end
local function yards(n) return math.sqrt((n.north - WoW.pos[1]) ^ 2 + (n.west - WoW.pos[2]) ^ 2) end
local function errors()
    local c = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then c = c + 1 end end
    return c
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function record() return FP.db.steps.records["NodeRadarProbe/world"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function tick(s) for _ = 1, math.floor(s / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end end
local function settle() for _ = 1, 4 do tick(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end end
local function waitFor(i) for _ = 1, 60 do if result(i).status == nil then place(); tick(0.5) end end end

-- 1: set up, the waypoint free.
WoW.waypoint, WoW.superTracked = { map = 1411, x = 0.1, y = 0.1 }, nil
fp("steps nr world")
tick(0.2)
eq(result(1).status, nil, "a waypoint of the player's: waits")
WoW.waypoint = nil
tick(1.2)
eq(result(1).status, "done", "free: " .. detail(1))
check(NR.db.marker == true and detail(1):find("1 %-> 1, NodeRadar will put back nil"), "...the marker on, the CVar at 1")
eq(NR.db.markerRange, 1000, "...the stars at every distance for the round")

-- 2: the stars on a node.
local a = node("Silverleaf", 0, 40)
WoW.navDistance = yards(a) + 50                            -- stale: no stars yet
for _ = 1, 8 do place(); tick(0.5) end
eq(result(2).status, nil, "NodeRadar's waypoint set, the stars not shown yet: waits")
WoW.navDistance = yards(a)
waitFor(2)
eq(result(2).status, "done", "the stars: " .. detail(2))
check(detail(2):find("NodeRadar's point %(50%.000, 48%.281%), the client's from the record %(50%.000, 48%.281%)"),
    "...NodeRadar's point against the client's conversion")
settle()
S.Answer(true)                                             -- 3
S.Skip()                                                   -- 4: far
S.Skip()                                                   -- 5

-- 6: a switch to a node as far, timed.
local b = node("Silverleaf", 0, -40)
place()
NR.Step(WoW.now)
NR.Compass.Snooze("session", NR.Compass.Chosen())
WoW.navFrame._center = { 960, 540 }
place()
NR.Step(WoW.now)
tick(0.2)
WoW.navFrame._center = { 960, 300 }                        -- the engine catches up
tick(2)
eq(result(6).status, "done", "the switch: " .. detail(6))
check(detail(6):find("moved 0%.[12]%d* s") and detail(6):find("showed at 0%.%d+ s"), "...timed: " .. detail(6))
S.Answer(false)                                            -- 7
S.Skip()                                                   -- 8: a slope
settle()

-- 9, 10: the player's pin, kept; then gone, ours back.
tick(5)
eq(result(9).status, nil, "NodeRadar's own waypoint isn't the player's: waits")
C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1411, 0.2, 0.3))
C_SuperTrack.SetSuperTrackedUserWaypoint(false)
WoW.worldMapShown = true
tick(5)
eq(result(9).status, nil, "the map open: waits")
WoW.worldMapShown = false
tick(5)
eq(result(9).status, "done", "your pin kept: " .. detail(9))
check(detail(9):find("NodeRadar's none") and detail(9):find("hidden"), "...not ours, no stars")
C_Map.ClearUserWaypoint()
C_SuperTrack.SetSuperTrackedUserWaypoint(false)
waitFor(10)
eq(result(10).status, "done", "ours back: " .. detail(10))

-- 11, 12: quests, the marker on, then off.
WoW.fire("QUEST_ACCEPTED", 783)
tick(2)
eq(result(11).status, "done", "a quest, the marker on: " .. detail(11))
check(detail(11):find("super%-tracking a quest false"), "...its super-track read")
tick(0.2)
eq(NR.db.marker, false, "the next step turns the marker off")
WoW.fire("QUEST_ACCEPTED", 784)
tick(2)
eq(result(12).status, "done", "a quest, the marker off: " .. detail(12))

-- 13: a fight, then the map.
tick(0.2)
eq(NR.db.marker, true, "the marker on again")
WoW.worldMapShown = true
tick(1)
WoW.worldMapShown = false
tick(1)
eq(result(13).status, nil, "the map before any fight: waits")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
tick(1)
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
tick(1)
eq(result(13).status, nil, "after the fight, no map yet: waits")
WoW.worldMapShown = true
tick(1)
WoW.worldMapShown = false
tick(1)
eq(result(13).status, "done", "the fight and the map: " .. detail(13))
check(detail(13):find("blocked 0"), "...nothing blocked")
S.Answer(false)                                            -- 14

-- 15, 16: a reload.
WoW.fire("PLAYER_LOGOUT")
eq(WoW.waypoint, nil, "the logout: NodeRadar's waypoint cleared")
FP.run = FP.run + 1
NR.Marker._test.reset()
WoW.fire("PLAYER_LOGIN")
S.Resume()
eq(result(15).status, "done", "reloaded: " .. detail(15))
waitFor(16)
eq(result(16).status, "done", "back after it: " .. detail(16))
check(detail(16):find("at load"), "...what NodeRadar found at load")
S.Skip()                                                   -- 17: the logout
S.Skip()                                                   -- 18

-- 19: the CVar from 0.
waitFor(19)
eq(result(19).status, "done", "from 0: " .. detail(19))
check(detail(19):find("now 1, NodeRadar will put back 0"), "...held at 1, 0 to put back")
settle()

-- 20: the summary, everything put back.
tick(0.5)
eq(result(20).status, "done", "the summary: " .. detail(20))
check(detail(20):find("something else super%-tracked %d+ of %d+ s"), "...the share of time tracked")
eq(NR.db.marker, false, "...the marker off again, as it was")
eq(NR.db.markerRange, 40, "...its range as it was")
eq(WoW.cvars.showInGameNavigation, "1", "...the CVar as it was")
eq(NR.db.markerCVar, nil, "...NodeRadar's restore as it was")
eq(NS._worldTest.watch.on, nil, "...the observer gone")
eq(record().at, 21, "at the last reload")
fp("steps stop")

-- Stopped mid-round: the observer goes too.
fp("steps nr world")
tick(0.2)
check(NS._worldTest.watch.on, "watching")
fp("steps stop")
tick(0.2)
eq(NS._worldTest.watch.on, nil, "stopped: the observer gone")
NR.Set("marker", false)

eq(errors(), 0, "no step threw")
for _, l in ipairs(WoW.chat) do check(not l:find("world"), "nothing of the probe in chat: " .. l) end
done("test_probe_world")
