-- The tooltip procedure (/fp steps nr tooltip, #62): the client's strings and
-- skill lines logged, our line under a hovered herb and ore, held through
-- sweeps; the setting put back. Runs locally only (ForeverProbe is private;
-- CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
TEST_LIBRARY.enUS["Copper Vein"] = "ore"
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = 42, modifier = 0, maxRank = 75 }
local NR = loadAddon()
NR.NODE_INFO = { enUS = { ["Silverleaf"] = { skill = 1, item = 765 }, ["Copper Vein"] = { skill = 1, item = 2770 } } }
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB
for i = 1, 4 do rawset(_G, "GameTooltipTextLeft" .. i, GameTooltip:CreateFontString()) end

local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function record() return FP.db.steps.records["NodeRadarProbe/tooltip"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
-- The client's hover: the tooltip rebuilt and its font strings filled.
local function hover(blips)
    WoW.blips = blips
    WoW.hover(0, 0)
    WoW.buildMinimapTooltip()
    for i = 1, 4 do _G["GameTooltipTextLeft" .. i]:SetText(GameTooltip._lines[i]) end
end
local function poll() hover(WoW.blips); WoW.advance(1.1) end
local function settle()
    for _ = 1, 4 do WoW.advance(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end
end

NR.db.tooltipSkill = false                                  -- the player's setting, off
WoW.blips = {}
fp("steps nr tooltip")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
check(detail(1):find("Herbalism %(182%): name Herbalism, rank 42") and detail(1):find("Mining %(186%): nil"),
    "...the skill lines logged")
eq(NR.db.tooltipSkill, true, "...the line on for the round")
poll()
eq(result(2).status, nil, "no herb hovered: waits")
GameTooltipTextLeft1:SetText("Master Gadrin")                -- a unit's tooltip, a coloured line of its own
GameTooltipTextLeft2:SetText("|c0042b1fePress F6 to submit an issue for this Creature")
WoW.advance(1.1)
eq(result(2).status, nil, "...a unit's coloured line isn't ours")
hover({ { "Silverleaf", 0, 0 } })
poll()
eq(result(2).status, "done", "a herb: " .. detail(2))
check(detail(2):find("Silverleaf") and detail(2):find("Herbalism 1"), "...its line read back")
settle()
S.Answer(true)                                             -- 3
poll()
eq(result(4).status, nil, "a herb within the skill isn't the ore step's")
hover({ { "Copper Vein", 0, 0 } })
poll()
eq(result(4).status, "done", "an ore: " .. detail(4))
check(detail(4):find("|cffff2020Mining 1|r", 1, true), "...red, no Mining")
settle()
hover({ { "Silverleaf", 0, 0 } })
poll()
for _ = 1, 12 do poll() end
eq(result(5).status, "done", "held: " .. detail(5))
check(detail(5):find("sweeps while hovering; the line missing in 0 of"), "...the line there throughout")
check(NR.Scan.Sweep ~= nil and not detail(5):find("^0 sweeps"), "...sweeps counted")
S.Answer(true)                                             -- 6
poll()
S.Answer(false)                                            -- 7: nothing broke
poll()
eq(result(8).status, "done", "put back: " .. detail(8))
eq(NR.db.tooltipSkill, false, "the setting back off")
eq(db.tooltipWas, nil, "...the saved setting cleared")
eq(record().at, 9, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_tooltip")
