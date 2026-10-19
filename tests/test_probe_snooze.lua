-- The snooze procedure (/fp steps nr snooze, #46): the minimap button and its
-- tooltip, a snooze from the menu moving the compass on, clearing, the key
-- binding, the right-click, a reload clearing; the settings put back. Runs
-- locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
NR.Track.SetSmart(false)
for _, id in ipairs({ 765, 2449 }) do WoW.itemCached[id] = true end
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB
rawset(_G, "GameTooltipTextLeft1", GameTooltip:CreateFontString())

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
local function record() return FP.db.steps.records["NodeRadarProbe/snooze"] end
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
local btn = WoW.ldbi.buttons.NodeRadar

walk(1)
fp("steps nr snooze")
WoW.advance(1.1)
eq(result(1).status, "done", "ready: " .. detail(1))
-- The button's tooltip.
walk(1.2)
eq(result(2).status, nil, "no tooltip: waits")
GameTooltip._shown = true
GameTooltipTextLeft1:SetText("NodeRadar")
walk(1.2)
eq(result(2).status, "done", "the tooltip: " .. detail(2))
GameTooltip._shown = false
settle()
S.Answer(true)                                             -- 3
nodes = { { name = "Silverleaf", north = WoW.pos[1] + 30 * K(), west = WoW.pos[2] },
          { name = "Earthroot", north = WoW.pos[1] - 40 * K(), west = WoW.pos[2] } }
walk(4)
eq(result(4).status, "done", "two nodes, the compass on one: " .. detail(4))
-- The menu: snooze 15 minutes.
walk(1.2)
eq(result(5).status, nil, "not snoozed: waits")
btn._scripts.OnClick(btn, "LeftButton")
WoW.menuItem("15 minutes").callback()
walk(1.2)
eq(result(5).status, "done", "snoozed: " .. detail(5))
check(detail(5):find("the compass on Item 2449") and detail(5):find("1 snoozed"), "...moved on: " .. detail(5))
settle()
S.Answer(true)                                             -- 6
btn._scripts.OnClick(btn, "LeftButton")
WoW.menuItem("Clear snoozes").callback()
walk(1.2)
eq(result(7).status, "done", "cleared: " .. detail(7))
NR.Minimap.SnoozeKey()
walk(1.2)
eq(result(8).status, "done", "the key: " .. detail(8))
S.Answer(true)                                             -- 9
S.Answer(true)                                             -- 10
btn._scripts.OnClick(btn, "RightButton")
NR.Options._test.panel:Show()
walk(1.2)
eq(result(11).status, "done", "right-click: " .. detail(11))
NR.Options._test.panel:Hide()
settle()
S.Answer(true)                                             -- 12
S.Skip()                                                   -- 13
walk(1.2)
eq(result(14).status, "done", "snoozed again: " .. detail(14))
S.Skip()                                                   -- 15: the reload
NR.Compass.ClearSnoozes()                                  -- what the reload does
walk(1.2)
eq(result(16).status, "done", "after the reload: " .. detail(16))
check(detail(16):find("0 snoozed"), "...nothing snoozed")
eq(result(17).status, "done", "put back: " .. detail(17))
eq(rawget(NR.db, "compass"), nil, "the compass back")
eq(rawget(NR.db, "icons"), nil, "the icons back")
eq(record().at, 18, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
done("test_probe_snooze")
