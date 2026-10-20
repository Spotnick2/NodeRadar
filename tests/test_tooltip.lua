-- The skill a node needs in the minimap's tooltip (#62): our post-call on the
-- MinimapMouseover type adds "Requires Herbalism (15)", coloured by difficulty,
-- to GameTooltip only; the data the sweep reads is never touched.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
TEST_LIBRARY.enUS["Mageroyal"] = "herbs"
TEST_LIBRARY.enUS["Copper Vein"] = "ore"
local NR = loadAddon()
NR.NODE_INFO = { enUS = { ["Silverleaf"] = { skill = 1, item = 765 }, ["Mageroyal"] = { skill = 50, item = 785 },
                          ["Copper Vein"] = { skill = 1, item = 2770 } } }
local Tooltip = NR.Tooltip
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = 60, modifier = 0, maxRank = 150 }

eq(#(WoW.postCalls[21] or {}), 1, "registered once at login, for MinimapMouseover (21)")
eq(NR.db.tooltipSkill, true, "on by default")

local function lines(tooltip)
    WoW.blips = WoW.tipBlips
    WoW.hover(0, 0)
    WoW.buildMinimapTooltip(tooltip)
    return (tooltip or GameTooltip)._lines
end
local function added(tooltip)                              -- the lines after the data's own
    local all, out = lines(tooltip), {}
    for _, l in ipairs(all) do
        if l:find("|c", 1, true) then out[#out + 1] = l end
    end
    return out, all
end

-- One node: its line, its text and colour.
WoW.tipBlips = { { "Silverleaf", 0, 0 } }
local out, all = added()
eq(all[1], "Silverleaf", "the node's own line first")
eq(#out, 1, "one line added")
eq(out[1], "|cff40c040Herbalism 1|r", "Silverleaf (1) at 60: green, the fallback text (no ITEM_MIN_SKILL)")
_G.ITEM_MIN_SKILL = "Requires %s (%d)"
out = added()
eq(out[1], "|cff40c040Requires Herbalism (1)|r", "the client's own requirement text")
-- Two builds in a row: no stacking (each build starts over).
out = added()
eq(#out, 1, "built again: still one line")
-- The bands, by the effective rank (gear included).
WoW.tipBlips = { { "Mageroyal", 0, 0 } }
for _, c in ipairs({ { 40, 0, "ffff2020", "below: red" }, { 50, 0, "ffff8040", "at it: orange" },
                     { 74, 0, "ffff8040", "+24: orange" }, { 75, 0, "ffffff00", "+25: yellow" },
                     { 100, 0, "ff40c040", "+50: green" }, { 150, 0, "ff808080", "+100: grey" },
                     { 45, 5, "ffff8040", "45 and a +5 bonus: orange (the effective rank)" } }) do
    WoW.skillLines[182].rank, WoW.skillLines[182].modifier = c[1], c[2]
    out = added()
    eq(out[1], "|c" .. c[3] .. "Requires Herbalism (50)|r", "Mageroyal (50): " .. c[4])
end
WoW.skillLines[182].rank, WoW.skillLines[182].modifier = 60, 0
-- No such profession: red.
WoW.tipBlips = { { "Copper Vein", 0, 0 } }
out = added()
eq(out[1], "|cffff2020Requires Mining (1)|r", "Copper Vein without Mining: red, the English name")
-- The skill line's own name when it reads.
WoW.skillLines[186] = { skillID = 186, name = "Bergbau", rank = 10, modifier = 0 }
out = added()
eq(out[1], "|cffff8040Requires Bergbau (1)|r", "...the client's name for the skill when it reads")
WoW.skillLines[186] = nil
-- Two names: one line each, named; two of one name: one line.
WoW.tipBlips = { { "Silverleaf", 0, 0 }, { "Mageroyal", 2, 0 }, { "Silverleaf", -2, 0 } }
out = added()
eq(#out, 2, "Silverleaf, Mageroyal, Silverleaf: two lines (one a name)")
eq(out[1], "|cff40c040Silverleaf: Requires Herbalism (1)|r", "...each named, in the tooltip's order")
eq(out[2], "|cffff8040Mageroyal: Requires Herbalism (50)|r", "...the second")
-- Another name (a quest's), a name not known: nothing.
WoW.tipBlips = { { "Carry Your Weight", 0, 0 }, { "Earthroot", 0, 0 } }
out = added()
eq(#out, 0, "a quest's name and an unknown one: no line")
-- A learned name without NODE_INFO, a learned "not a node" over a shipped one.
NR.Learn.Record("Earthroot", "herbs", "gather")
out = added()
eq(#out, 0, "a learned herb without a skill: no line")
NR.Learn.Record("Silverleaf", false, "toggle")
WoW.tipBlips = { { "Silverleaf", 0, 0 } }
out = added()
eq(#out, 0, "a learned 'not a node': its shipped skill ignored")
NodeRadarDB.learned = {}
out = added()
eq(#out, 1, "forgotten: the line back")

-- Rows: several names in one line, and a height arrow's row.
local data = { type = 21, lines = { { leftText = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:32:32:0:32:0:16|tSilverleaf\nMageroyal" } } }
GameTooltip._lines = {}
Tooltip.PostCall(GameTooltip, data)
eq(#GameTooltip._lines, 2, "two rows in one line, one with a height arrow: both read")
eq(GameTooltip._lines[1], "|cff40c040Silverleaf: Requires Herbalism (1)|r", "...the arrow's row as its name")

-- Secrets: no line, nothing raised, recorded once.
local function silent(d, label)
    GameTooltip._lines = {}
    local ok = pcall(Tooltip.PostCall, GameTooltip, d)
    check(ok, label .. ": nothing raised")
    eq(#GameTooltip._lines, 0, label .. ": no line")
end
silent(WoW.Secret("data"), "secret data")
silent({ type = 21, lines = WoW.Secret("lines") }, "secret lines")
silent({ type = 21, lines = { WoW.Secret("line") } }, "a secret line")
silent({ type = 21, lines = { { leftText = WoW.Secret("text") } } }, "a secret text")
silent({ type = 21, lines = { { leftText = "Silverleaf" }, { leftText = WoW.Secret("text") } } },
    "a node then a secret row")
local base = { type = 21, lines = { { leftText = "Silverleaf" } } }
WoW.skillLines[182] = WoW.Secret("info")
silent(base, "secret skill info")
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = WoW.Secret("rank"), modifier = 0 }
silent(base, "a secret rank")
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = 60, modifier = WoW.Secret("modifier") }
silent(base, "a secret modifier")
eq(NR.API.Skill(182), nil, "API.Skill: a secret modifier unreadable, never compared")
eq(select(2, NR.API.Skill(182)), "unreadable", "...said so")
eq(select(2, NR.API.Skill(186)), "absent", "...no Mining: absent")
WoW.skillLines[182] = { skillID = 182, name = WoW.Secret("name"), rank = 60, modifier = 0 }
GameTooltip._lines = {}
Tooltip.PostCall(GameTooltip, base)
eq(GameTooltip._lines[1], "|cff40c040Requires Herbalism (1)|r", "a secret skill name: the English one")
WoW.skillLines[182] = "throw"
silent(base, "the skill call failing")
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = 60, modifier = 0 }
-- A failure inside: recorded once.
local info = NR.Learn.Info
NR.Learn.Info = function() error("boom") end
silent(base, "a failure")
silent(base, "...again")
NR.Learn.Info = info
eq(NR.failures.tooltip and NR.failures.tooltip.count, 1, "the failure recorded once, not per frame")

-- The data the sweep reads is untouched by our call.
WoW.tipBlips = { { "Silverleaf", 0, 0 } }
WoW.blips = WoW.tipBlips
WoW.hover(0, 0)
local d = C_TooltipInfo.GetMinimapMouseover()
local before = #d.lines .. ":" .. d.lines[1].leftText
GameTooltip._lines = {}
Tooltip.PostCall(GameTooltip, d)
eq(#d.lines .. ":" .. d.lines[1].leftText, before, "the data unchanged by the post-call")
eq(#GameTooltip._lines, 1, "...the line went to the tooltip")
-- A sweep with the tooltip shown reads node names only.
lines()
local r = NR.Scan.Sweep(function() return true end)
local names = {}
for name in pairs(r.byName) do names[#names + 1] = name end
eq(table.concat(names, ","), "Silverleaf", "a sweep while hovering: only the node's name")
eq(WoW.softCursor, false, "...the soft cursor off")

-- Another tooltip: untouched.
local other = CreateFrame("GameTooltip", "OtherTooltip", UIParent)
out = added(other)
eq(#out, 0, "another tooltip than GameTooltip: no line")

-- The setting: /nr tooltip, the Options checkbox, saved off, the radar off.
SlashCmdList.NODERADAR("tooltip")
eq(NR.db.tooltipSkill, false, "/nr tooltip: off")
out = added()
eq(#out, 0, "...no line")
SlashCmdList.NODERADAR("tooltip")
eq(NR.db.tooltipSkill, true, "/nr tooltip again: on")
NR.Options._test.panel:Show()
local box = NR.Options._test.checks.tooltipSkill
check(box and box:GetChecked() == true, "Options: its checkbox, ticked")
box:SetChecked(false)
box._scripts.OnClick(box)
eq(NR.db.tooltipSkill, false, "...unticked: off")
box:SetChecked(true)
box._scripts.OnClick(box)
eq(NR.db.tooltipSkill, true, "...ticked: on")
NR.Set("enabled", false)
out = added()
eq(#out, 1, "the radar off: still shown (it reads no blip)")
NR.Set("enabled", true)
NR.db = nil
silent(base, "before the settings load")
done("test_tooltip")
