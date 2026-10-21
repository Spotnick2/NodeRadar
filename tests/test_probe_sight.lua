-- The sight procedure (/fp steps nr sight, #61): the navigation's state held in
-- each view, how far a node draws, the height arrow on a straight approach,
-- a waypoint's z; NodeRadar's marker and the CVar put back at the summary.
-- Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
WoW.pos = { 0, 0, 1 }
local NR = loadAddon()
NR.Track.SetSmart(false)
local FP = loadForeverProbe()
local NS = loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

-- The minimap's arrow for a node above the player (its upper half).
local ABOVE = "|TInterface\Minimap\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16|t"

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
        list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs",
            text = n.above and (ABOVE .. n.name) or nil }
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
local function record() return FP.db.steps.records["NodeRadarProbe/sight"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function tick(s) for _ = 1, math.floor(s / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end end
local function settle() for _ = 1, 4 do tick(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end end
local function run(i, s) for _ = 1, s * 2 do if result(i).status == nil then place(); NR.Step(WoW.now); tick(0.5) end end end

-- 1: set up.
fp("steps nr sight")
tick(1.2)
eq(result(1).status, "done", "set up: " .. detail(1))
check(NR.db.marker == true and detail(1):find("height none"), "...the marker on, no height from UnitPosition")

-- 2: the clear view, held 10 s; moving starts it again.
local a = node("Silverleaf", 0, 40)
WoW.navDistance, WoW.navState = yards(a), 1
run(2, 6)
eq(result(2).status, nil, "6 s held: still holding")
WoW.pos[1] = WoW.pos[1] + 3                                -- a step
WoW.navDistance = yards(a)
run(2, 6)
eq(result(2).status, nil, "moved: held again from the start")
run(2, 8)
eq(result(2).status, "done", "the clear view: " .. detail(2))
check(detail(2):find("clear: %d+ samples; state Occluded %d+; stars true %d+"), "...the state named, the stars: " .. detail(2))
settle()
S.Answer(true)                                             -- 3

-- 4: behind a crest, no stars needed, the state InRange.
WoW.navState = 2
run(4, 12)
eq(result(4).status, "done", "the crest: " .. detail(4))
check(detail(4):find("state InRange"), "...its own samples only: " .. detail(4))
check(not detail(4):find("Occluded"), "...none of the clear view's")
settle()
S.Answer(false)                                            -- 5
S.Skip()                                                   -- 6: a rock
S.Skip()                                                   -- 7
S.Skip()                                                   -- 8: a ledge
S.Skip()                                                   -- 9

-- 10: how far a node draws.
S.Run()
eq(result(10).status, "done", "gone: " .. detail(10))
check(detail(10):find("Silverleaf gone from view at %d+%.%d yards %(the navigation's %d+%.%d%)"), "...the distance to the target: " .. detail(10))

-- 11: the approach, from 40 yards up a slope to standing on the node.
WoW.posZ = 100
local r = NR.Marker._test.want().record
WoW.pos[1] = a.north - 45
run(11, 2)
eq(result(11).status, nil, "the approach started")
a.above = true
for step = 1, 9 do
    WoW.pos[1] = a.north - 45 + step * 5
    WoW.posZ = 100 + step                                  -- up the slope
    if step >= 8 then a.above = nil end
    WoW.navDistance = yards(a)
    place(); NR.Step(WoW.now); tick(1)
end
WoW.pos[1] = a.north - 1
WoW.posZ = 110
run(11, 4)
eq(result(11).status, "done", "the approach: " .. detail(11))
check(detail(11):find("the node's height 110%.0"), "...the node's height where the player stood")
check(detail(11):find("above %d+ %(the node 3%.0 to 9%.0 yd above you%); level %d+ %(the node 10%.0 to 10%.0"), "...the arrow against the difference: " .. detail(11))
check(NR.Marker._test.want() and NR.Marker._test.want().record == r, "...the same node")

-- 12, 13: a waypoint's z.
WoW.pos[1] = a.north - 40
WoW.navDistance = yards(a)
run(12, 2)
S.Run()                                                    -- 12: Test
eq(result(12).status, "done", "test pressed")
for _ = 1, 12 do if result(13).status == nil then tick(1) end end
eq(result(13).status, "done", "the waypoint's z: " .. detail(13))
check(detail(13):find("z none: .-; z 125%.0: .-read back z 125; z 95%.0: .-read back z 95"),
    "...no z, then above and below, read back: " .. detail(13))
eq(NR.db.marker, true, "...NodeRadar's marker back on")
settle()

-- 14: the summary, everything put back.
tick(1)
eq(result(14).status, "done", "the summary: " .. detail(14))
check(detail(14):find("clear: %d+ samples") and detail(14):find("rock: no samples"), "...each view")
eq(NR.db.marker, false, "...the marker off again, as it was")
eq(WoW.cvars.showInGameNavigation, "0", "...the CVar as it was")
eq(NS._sightTest.sampler.on, nil, "...the sampler gone")
fp("steps stop")

-- Stopped mid-round: the sampler goes too.
fp("steps nr sight")
tick(1.2)
check(NS._sightTest.sampler.on, "sampling")
fp("steps stop")
tick(1)
eq(NS._sightTest.sampler.on, nil, "stopped: the sampler gone")
NR.Set("marker", false)

eq(errors(), 0, "no step threw")
for _, l in ipairs(WoW.chat) do check(not l:find("sight"), "nothing of the probe in chat: " .. l) end
done("test_probe_sight")
