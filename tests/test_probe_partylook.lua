-- The partylook procedure (/fp steps nr partylook, #83), run on the main M: Share's
-- state, the shared icon and its frame against where it should be, the toggles and
-- the style, the gather (the entry going) and leaving the group (the list
-- emptying). Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
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
local function record() return FP.db.steps.records["NodeRadarProbe/partylook"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function receive(text, sender)
    WoW.fire("CHAT_MSG_ADDON", "NodeRadar", text, "PARTY", sender or HERB, "", 0, 0, "", 0)
end
local function msg(seq, ...)
    return ("1|%d|%d|1|%s"):format(session + 5, seq, table.concat({ ... }, ";"))
end
local function shots() for _ = 1, 3 do WoW.advance(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end end

fp("steps nr partylook")
poll()
eq(result(1).status, "done", "the state: " .. detail(1))
check(detail(1):find("partyNodes true, shareNodes false, IsInGroup true, roster Drakuza Memphisto", 1, true), "...settings, group and roster")
check(logLines("look: partyNodes true"), "...logged")
S.Answer(true)                                             -- 2: the setup
receive(msg(1, "765,10.0,-10.0,Silverleaf"))               -- H's snapshot arrives while M rides
poll()
S.Answer(true)                                             -- 3: the minimap, with a screenshot
shots()
eq(WoW.shots and WoW.shots >= 1, true, "a screenshot of the minimap")
poll()
eq(result(4).status, "done", "the dump: " .. detail(4))
check(detail(4):find("1 senders kept, 1 shared entries (1 with a frame, 1 shown); first", 1, true), "...one entry, framed and shown: " .. detail(4))
check(logLines('session %d+ seq 1 age') > 0, "...the sender's session, seq and age")
check(logLines("kept \"Silverleaf\" item 765 north 10.00 west %-10.00; frame shown true") > 0, "...the kept entry and its frame")
check(logLines("anchored CENTER of the minimap at %(6%.6, 6%.6%) px; on screen") > 0, "...where its frame is anchored")
check(logLines("expected %(6%.6, 6%.6%) px %(10%.0 yd north, 10%.0 yd east of you%)") > 0, "...and where it should be")
check(logLines("1%.515 yd per px") + logLines("1%.515") > 0, "...the scale")
check(logLines("GetViewRadius %d") > 0, "...the view radius")
S.Answer(true)                                             -- 5: in the right place
S.Answer(true)                                             -- 6: the toggles
shots()
poll()
eq(result(7).status, "done", "after the toggles: " .. detail(7))
check(logLines("look restyled: UnitPosition") > 0, "...logged under its own tag")
S.Answer(true)                                             -- 8: gathered
poll()
eq(result(9).status, nil, "the entry is still listed: waits")
receive(msg(2, ""))                                        -- H's gather: an empty snapshot
poll()
eq(result(9).status, "done", "the entry gone: " .. detail(9))
check(detail(9):find("left the list", 1, true) and detail(9):find("0 shared entries left", 1, true), "...how long it took: " .. detail(9))
check(logLines("gone from Share's list") > 0, "...the watcher noted when")
poll()
eq(result(10).status, "done", "after the gather: " .. detail(10))
check(detail(10):find("0 shared entries", 1, true), "...none shown")
receive(msg(3, "765,10.0,-10.0,Silverleaf"))               -- the group still there: a node back, to see the list empty later
S.Answer(true)                                             -- 11: leave
poll()
eq(result(12).status, nil, "still grouped: the list waits")
WoW.group, WoW.units.party1 = false, nil
WoW.fire("GROUP_ROSTER_UPDATE")
poll()
eq(result(12).status, "done", "the list emptied: " .. detail(12))
check(detail(12):find("the list was empty", 1, true), "...how long it took")
poll()
eq(result(13).status, "done", "after leaving: " .. detail(13))
check(detail(13):find("0 senders kept, 0 shared entries", 1, true), "...nothing kept")
FP.run = FP.run + 1                                        -- 14: the reload
S.Resume()
eq(result(14).status, "done", "the reload step done")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_partylook")
