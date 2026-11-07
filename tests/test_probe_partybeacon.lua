-- The partybeacon procedure (/fp steps nr partybeacon, #83 step 2), run on the receiver M:
-- why the distant beacon has no user waypoint on a party herb, read by beaconSlot.
-- Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB
WoW.itemCached[765] = true
WoW.units.player = { name = "Kalizo", realm = "Mistwalker", full = "Kalizo Mistwalker" }
WoW.units.party1 = { name = "Drakuza", realm = "Memphisto", full = "Drakuza Memphisto" }
local HERB = "Drakuza Memphisto"
WoW.group = true
WoW.pos = { 0, 0, 1 }
NR.Set("partyNodes", true)
NR.Set("ring", true)
NR.Share.OnRoster()
local session = math.floor(GetServerTime())

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
local function record() return FP.db.steps.records["NodeRadarProbe/partybeacon"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function receive(text)
    WoW.fire("CHAT_MSG_ADDON", "NodeRadar", text, "PARTY", HERB, "", 0, 0, "", 0)
end
local function shots() for _ = 1, 3 do WoW.advance(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end end

eq(NR.db.compass, false, "the compass starts off")
fp("steps nr partybeacon")
poll()
eq(result(1).status, "done", "the setup: " .. detail(1))
check(detail(1):find("compass true (was false)", 1, true) and detail(1):find("marker true (was false)", 1, true), "...both on, old values: " .. detail(1))
eq(NR.db.compass, true, "the compass is on for the round")
eq(NR.db.marker, true, "the marker is on for the round")
eq(NodeRadarProbeDB.partybeacon.saved.compass, false, "the old values are saved under its own key")
eq(NodeRadarProbeDB.partyguide, nil, "...not partyguide's")
-- A tracked quest, and one API missing: the read says so and doesn't throw.
WoW.superTracked = "quest"
local savedContent = C_SuperTrack.IsSuperTrackingContent
C_SuperTrack.IsSuperTrackingContent = nil
receive(("1|%d|1|1|765,30.0,0.0,Silverleaf"):format(session + 5))
poll()
S.Answer(true)                                             -- 2: ride to the herb
poll()
poll()
eq(result(3).status, "done", "the dump: " .. detail(3))
check(logLines("guide pbeacon: target") > 0, "...guideDump logged under the tag")
check(logLines("beaconSlot pbeacon: waypoint") > 0, "...navState logged")
check(logLines("beaconSlot pbeacon: quest true, corpse false, content MISSING, mapPin false, vignette nil") > 0, "...a missing API reads MISSING, the quest read")
check(logLines("showInGameNavigation 0; farNavigation nil; InCombatLockdown false; WorldMapFrame shown false") > 0, "...the cvar, ownership, combat, the map")
check(logLines("FarMarker.reason .-; want .-; ours none; GetUserWaypoint none; Marker.Settled") > 0, "...want, ours, the waypoint, the marker")
check(logLines("beaconSlot pbeacon: .*Nearby") > 0, "...Nearby read")
C_SuperTrack.IsSuperTrackingContent = savedContent
shots()
S.Answer(true)                                             -- 4: the beacon seen
S.Answer(true)                                             -- 5: a quest tracked
poll()
eq(result(6).status, "done", "the after read: " .. detail(6))
check(logLines("beaconSlot pbeacon%-after: quest true") > 0, "...logged under the after tag")
eq(result(7).status, "done", "the settings put back: " .. detail(7))
check(detail(7):find("compass false, marker false", 1, true), "...old values: " .. detail(7))
eq(NR.db.compass, false, "the compass off again")
eq(NR.db.marker, false, "the marker off again")
eq(NodeRadarProbeDB.partybeacon.saved, nil, "nothing left pending")
FP.run = FP.run + 1                                        -- 8: the reload
S.Resume()
eq(result(8).status, "done", "the reload step done")
fp("steps stop")
WoW.superTracked = nil

-- A round stopped half way puts everything back (the guard).
fp("steps nr partybeacon")
poll()
eq(NR.db.compass, true, "a second run: the compass on")
fp("steps stop")
WoW.advance(1)
eq(NR.db.compass, false, "stopped: the guard puts the compass back")
eq(NR.db.marker, false, "...and the marker")
eq(NodeRadarProbeDB.partybeacon.saved, nil, "...nothing pending")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_partybeacon")
