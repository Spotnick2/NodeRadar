-- The track procedure (/fp steps nr track, #47): the Herbs and Ores pages on
-- their first visit, their item names, what smart chose, a herb near the player
-- skipped (dimmed, the compass leaving it), Blizzard's dot, tracked again, each
-- preset, smart off and on, a node's tooltip colour; the settings and the list
-- put back. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Mageroyal"] = "herbs"
TEST_LIBRARY.enUS["Peacebloom"] = "herbs"
WoW.skillLines[182] = { skillID = 182, rank = 38, modifier = 0, maxRank = 75 }
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
local function record() return FP.db.steps.records["NodeRadarProbe/track"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        local l = {}
        for _, n in ipairs(nodes) do
            l[#l + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
        end
        WoW.blips = l
        WoW.advance(0.1)
    end
end
local H, O = NR.TrackOptions._test.herbs, NR.TrackOptions._test.ore
local before = NR.Track.Count("herbs")
local track0 = NR.charDb.track

walk(1)
fp("steps nr track")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.icons, true, "...icons on")
eq(NR.db.compass, true, "...the compass on")
poll()
eq(result(2).status, nil, "Herbs not open: waits")
H.panel:Show()
poll()
eq(result(2).status, "done", "Herbs open: " .. detail(2))
check(detail(2):find("3 rows"), "...its rows counted: " .. detail(2))
settle()
S.Answer(true)                                             -- 3
S.Run()                                                    -- 4 count
eq(result(4).status, "done", "the names counted: " .. detail(4))
H.panel:Hide()
O.panel:Show()
poll()
eq(result(5).status, "done", "Ores open: " .. detail(5))
O.panel:Hide()
settle()
S.Answer(true)                                             -- 6
S.Answer(true)                                             -- 7
nodes = { { name = "Silverleaf", north = WoW.pos[1] + 30 * K(), west = WoW.pos[2] } }
walk(3)
eq(result(8).status, "done", "a herb in view: " .. detail(8))
settle()
walk(2)
eq(result(9).status, "done", "skipped: " .. detail(9))
check(NR.Track.Ignored(765), "...Silverleaf skipped")
settle()
S.Answer(true)                                             -- 10
walk(2)
eq(result(11).status, "done", "Blizzard's dot: " .. detail(11))
eq(NR.db.ignoredIcon, "dot", "...chosen")
settle()
S.Answer(true)                                             -- 12
walk(3)
eq(result(13).status, "done", "tracked again: " .. detail(13))
check(not NR.Track.Ignored(765), "...Silverleaf followed")
settle()
H.panel:Show()
poll()
eq(result(14).status, "done", "Herbs again")
-- The presets, each waited for.
poll()
eq(result(15).status, nil, "None not pressed: waits")
WoW.click(H.buttons.none)
poll()
eq(result(15).status, "done", "None: " .. detail(15))
settle()
WoW.click(H.buttons.gather)
poll()
eq(result(16).status, "done", "All I can gather: " .. detail(16))
settle()
WoW.click(H.buttons.skillups)
poll()
eq(result(17).status, "done", "Skill-ups only: " .. detail(17))
settle()
WoW.click(H.buttons.all)
poll()
eq(result(18).status, "done", "All: " .. detail(18))
settle()
S.Answer(true)                                             -- 19
WoW.click(H.smart)
poll()
eq(result(20).status, "done", "smart off: " .. detail(20))
WoW.click(H.smart)
poll()
eq(result(21).status, "done", "smart on: " .. detail(21))
check(detail(21):find("smart true"), "...on")
settle()
S.Answer(true)                                             -- 22
H.panel:Hide()
settle(); S.Next(); settle()                               -- 23 the tooltip
S.Answer(true)                                             -- 24
eq(result(25).status, "done", "put back: " .. detail(25))
eq(rawget(NR.db, "icons"), nil, "the icons back")
eq(rawget(NR.db, "compass"), nil, "the compass back")
eq(rawget(NR.db, "ignoredIcon"), nil, "the skipped look back")
eq(NR.Track.Count("herbs"), before, "the list back")
check(NR.charDb.track ~= track0 and NR.Track.Smart(), "...a copy, smart as it was")
eq(record().at, 26, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_track")
