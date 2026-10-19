-- The track2 procedure (/fp steps nr track2, #47): the Herbs and Ores pages in
-- columns, a row's tooltip, smart off and on with each toggle logged, a node's
-- own tooltip in the world read with its colours; the list put back. Runs
-- locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
TEST_LIBRARY.enUS["Mageroyal"] = "herbs"
TEST_LIBRARY.enUS["Peacebloom"] = "herbs"
WoW.skillLines[182] = { skillID = 182, rank = 38, modifier = 0, maxRank = 75 }
local NR = loadAddon()
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
local function logged(pattern)
    for _, l in ipairs(db.log) do if l:find(pattern) then return true end end
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 6 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/track2"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local H, O = NR.TrackOptions._test.herbs, NR.TrackOptions._test.ore
NR.Track.Follow()                                          -- smart settled before the round
local before = NR.Track.Count("herbs")
local setSmart = NR.Track.SetSmart

fp("steps nr track2")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
H.panel:Show()
poll()
eq(result(2).status, "done", "Herbs: " .. detail(2))
settle()
S.Answer(true)                                             -- 3
poll()
eq(result(4).status, nil, "no row hovered: waits")
H.rows[2].cell._scripts.OnEnter(H.rows[2].cell)
GameTooltipTextLeft1:SetText(GameTooltip._text)           -- the client's SetText fills its first line
poll()
eq(result(4).status, "done", "a row's tooltip: " .. detail(4))
check(detail(4):find("Peacebloom"), "...its lines read")
H.rows[2].cell._scripts.OnLeave(H.rows[2].cell)
settle()
S.Answer(true)                                             -- 5
H.panel:Hide()
O.panel:Show()
poll()
eq(result(6).status, "done", "Ores: " .. detail(6))
O.panel:Hide()
settle()
S.Answer(true)                                             -- 7
H.panel:Show()
WoW.click(H.smart)
poll()
eq(result(8).status, "done", "smart off: " .. detail(8))
WoW.click(H.smart)
poll()
eq(result(9).status, "done", "smart on: " .. detail(9))
check(detail(9):find("the box true"), "...the box ticked")
check(logged("SMART false %(was true%)") and logged("SMART true %(was false%)"), "each toggle logged")
H.panel:Hide()
settle()
S.Answer(true)                                             -- 10
-- A node's own tooltip in the world, not the minimap's.
GameTooltip:SetOwner(Minimap, "ANCHOR_LEFT")
GameTooltip._shown = true
GameTooltipTextLeft1:SetText("Silverleaf")
poll()
eq(result(11).status, nil, "the minimap's tooltip: waits")
GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
poll()
eq(result(11).status, "done", "a node's tooltip: " .. detail(11))
check(detail(11):find("Herbalism 38: Silverleaf"), "...the rank and its lines")
GameTooltip._shown = false
settle()
eq(result(12).status, "done", "put back: " .. detail(12))
check(NR.Track.SetSmart == setSmart, "the logging taken off")
eq(NR.Track.Count("herbs"), before, "the list back")
eq(record().at, 13, "at the last reload")
fp("steps stop")

-- /fp nr icons: what the icons hold against a fresh sweep.
NR.Set("icons", true)
WoW.blips = { { "Silverleaf", 20, 10, kind = "herbs" } }
for _ = 1, 3 do WoW.advance(1.1) end
fp("nr icons")
check(logged("icons: on true, keeping true"), "the dump's head")
check(logged("  blip Silverleaf at %+20.0 %+6.0 %(1 cells, from the centre 20.9%): nearest record none; wanted true, "
    .. "skipped false"), "...each blip, its nearest record, wanted, skipped")
check(logged("  failed measure Silverleaf: tried %d s ago"), "...each failed measure (the stub's map doesn't measure it)")
check(logged("    measured now: "), "...an unmatched blip measured again on the spot, and why")
NR.Set("icons", false)

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_track2")
