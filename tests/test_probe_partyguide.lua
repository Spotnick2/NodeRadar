-- The partyguide procedure (/fp steps nr partyguide, #83 step 2), run on the receiver M:
-- the compass, the beacon, the stars and the sonar on a node H shares. Runs locally
-- only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB
WoW.itemCached[765] = true
WoW.itemCached[2449] = true
WoW.units.player = { name = "Kalizo", realm = "Mistwalker", full = "Kalizo Mistwalker" }
WoW.units.party1 = { name = "Drakuza", realm = "Memphisto", full = "Drakuza Memphisto" }
local HERB = "Drakuza Memphisto"
WoW.group = true
WoW.pos = { 0, 0, 1 }
NR.Set("partyNodes", true)
NR.Set("ring", true)
NR.Share.OnRoster()
local session = math.floor(GetServerTime())
local originalSonar = NR.Alert.Sonar

local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function logLines(pattern)
    local n = 0
    for _, l in ipairs(db.party and db.party.lines or {}) do if l:find(pattern) then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function record() return FP.db.steps.records["NodeRadarProbe/partyguide"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function receive(text, sender)
    WoW.fire("CHAT_MSG_ADDON", "NodeRadar", text, "PARTY", sender or HERB, "", 0, 0, "", 0)
end
local function msg(seq, ...)
    return ("1|%d|%d|1|%s"):format(session + 5, seq, table.concat({ ... }, ";"))
end
local function shots() for _ = 1, 3 do WoW.advance(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end end

eq(NR.db.compass, false, "the compass starts off")
eq(NR.db.marker, false, "the marker starts off")
fp("steps nr partyguide")
poll()
eq(result(1).status, "done", "the setup: " .. detail(1))
check(detail(1):find("partyNodes true, enabled true, IsInGroup true, tracking active: none", 1, true), "...the settings: " .. detail(1))
check(detail(1):find("compass true (was false)", 1, true) and detail(1):find("marker true (was false)", 1, true), "...both turned on, with the old values")
eq(NR.db.compass, true, "the compass is on for the round")
eq(NR.db.marker, true, "the marker is on for the round")
eq(NodeRadarProbeDB.partyguide.saved.compass, false, "the old values are saved")
S.Answer(true)                                             -- 2: the setup
-- H's snapshot arrives while M rides: a herb 30 yards north
receive(msg(1, "765,30.0,0.0,Silverleaf"))
poll()
S.Answer(true)                                             -- 3: the icon is on the minimap
poll()
eq(result(4).status, "done", "the compass dump: " .. detail(4))
check(detail(4):find('Silverleaf.+ %(party true, item 765%) 30%.0 yd'), "...a party target and its distance: " .. detail(4))
check(detail(4):find("ring shown true", 1, true), "...the ring shown: " .. detail(4))
check(detail(4):find("beacon shown", 1, true) and detail(4):find("waypoint ours", 1, true), "...the beacon's state")
check(logLines("guide compass:   shared \"Silverleaf\" north 30.00 west 0.00 pending") > 0, "...the shared entry listed")
shots()
eq(WoW.shots and WoW.shots >= 1, true, "a screenshot of the ring")
S.Answer(true)                                             -- 5: the arrow
S.Answer(true)                                             -- 6: 20 to 55 yards
poll()
eq(result(7).status, "done", "the beacon dump: " .. detail(7))
check(logLines("guide beacon: target") > 0, "...logged under its own tag")
shots()
S.Answer(true)                                             -- 8: the beacon stands over the herb
WoW.pos = { 25, 0, 1 }                                     -- 5 yards from the herb
S.Answer(true)                                             -- 9: walked up
poll()
eq(result(10).status, "done", "the stars dump: " .. detail(10))
check(detail(10):find("stars Nearby", 1, true) and detail(10):find("Share.Near true", 1, true), "...the stars' state: " .. detail(10))
shots()
S.Answer(true)                                             -- 11: the stars
poll()
eq(result(12).status, "done", "the counter installed: " .. detail(12))
check(NR.Alert.Sonar ~= originalSonar, "...the Sonar wrapped")
WoW.pos = { 0, 0, 1 }
WoW.advance(NR.Share.QUIET + 0.5)
receive(msg(2, "765,30.0,0.0,Silverleaf", "2449,0.0,40.0,Earthroot"))   -- a new herb arrives
poll()
S.Answer(true)                                             -- 13: H's sound played
poll()
eq(result(14).status, "done", "the ripples counted: " .. detail(14))
check(detail(14):find("1 ripples in", 1, true) and detail(14):find("herbs at", 1, true), "...one ripple, its kind and spot: " .. detail(14))
check(detail(14):find("the wrapper still ours", 1, true), "...the wrapper still in place")
check(logLines("guide: Alert.Sonar%(") == 1, "...logged when it happened")
S.Answer(true)                                             -- 15: the ripple was seen
poll()
eq(result(16).status, "done", "the settings put back: " .. detail(16))
check(detail(16):find("compass false, marker false, Alert.Sonar restored true", 1, true), "...old values back: " .. detail(16))
eq(NR.db.compass, false, "the compass off again")
eq(NR.db.marker, false, "the marker off again")
eq(NR.Alert.Sonar, originalSonar, "the original Sonar back")
eq(NodeRadarProbeDB.partyguide.saved, nil, "nothing left pending")
FP.run = FP.run + 1                                        -- 17: the reload
S.Resume()
eq(result(17).status, "done", "the reload step done")
fp("steps stop")

-- A round stopped half way puts everything back (the guard).
fp("steps nr partyguide")
poll()
eq(NR.db.compass, true, "a second run: the compass on")
fp("steps stop")
WoW.advance(1)
eq(NR.db.compass, false, "stopped: the guard puts the compass back")
eq(NR.db.marker, false, "...and the marker")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_partyguide")
