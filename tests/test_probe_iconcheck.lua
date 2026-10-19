-- The iconcheck procedure (/fp steps nr iconcheck, #28): NodeRadar's icons on,
-- then each check in turn (standing still, the hover tooltip, standing on a
-- node, a node above, a zoom, running, turning, indoors, a gather, the cost
-- off and on, the stock map), and the setting put back. Runs locally only
-- (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.db.iconStyle = "plain"                                  -- #28's icon (the looks: test_styles)
local STEP = NR.Step
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 30 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/iconcheck"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

-- The world: one Silverleaf, its blip where the player sees it.
local function K() return C_Minimap.GetViewRadius() / 99 end
local leaf = { north = 20 * K(), west = -30 * K() }       -- 30 units east, 20 north of the start
local text
local function place()
    WoW.blips = { { "Silverleaf", -(leaf.west - WoW.pos[2]) / K(), (leaf.north - WoW.pos[1]) / K(), kind = "herbs",
                    text = text } }
end
local function walk(seconds)                               -- time passing, the blips following the player
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        place()
        WoW.advance(0.1)
    end
end
local function shown()
    for _, r in ipairs(NR.Icons._test.records()) do if r.frame and r.frame._shown then return r end end
end

place()
fp("steps nr iconcheck")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.icons, true, "NodeRadar's icons on")
check(db.restoreIcons and db.restoreIcons.value == nil, "...the player's setting (the default) kept to put back")

-- Standing still: the icon over the dot.
walk(3)
eq(result(2).status, "done", "an icon shown: " .. detail(2))
check(detail(2):find("1 icons: Silverleaf at %+[23][09]%.%d %+[12][09]%.%d"), "...at its node: " .. detail(2))
settle()
S.Answer(true)                                             -- 3
settle()

-- The hover tooltip.
poll()
eq(record().at, 4, "waits for the mouse on an icon")
local r = shown()
rawset(_G, "GameTooltip", CreateFrame("Frame"))
rawset(_G, "GameTooltipTextLeft1", GameTooltip:CreateFontString())
GameTooltipTextLeft1:SetText("Silverleaf")
GameTooltip:Show()
poll()
eq(result(4).status, nil, "a tooltip, the mouse not on an icon: still waiting")
GameTooltip:Hide()
WoW.mouseOver = r.frame
poll()
eq(result(4).status, nil, "on the icon, no tooltip yet: still waiting")
GameTooltip:Show()
poll()
eq(result(4).status, "done", "hovering: " .. detail(4))
check(detail(4):find("on Silverleaf: the tooltip shows Silverleaf"), "...the tooltip's first line read")
WoW.mouseOver = nil
settle()
S.Answer(true)                                             -- 5
settle()

-- Standing on the node.
poll()
eq(record().at, 6, "waits for the player on a node")
WoW.pos = { leaf.north - 1, leaf.west, 1 }
walk(3)
eq(result(6).status, "done", "on the node: " .. detail(6))
settle()
S.Answer(true)                                             -- 7
settle()

-- A node above: not the arrow round 1 saw (a node below), its own.
text = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:16:32|tSilverleaf"
walk(2)
eq(record().at, 8, "the arrow of a node below isn't taken for above")
text = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16|tSilverleaf"
walk(2)
eq(result(8).status, "done", "above: " .. detail(8))
check(db.icons.arrows.above.tex:find("0:16:0:16$"), "...its texture kept")
text = nil
settle()
S.Answer(true)                                             -- 9
settle()

-- A zoom.
walk(2)
eq(record().at, 10, "waits for a zoom")
Minimap._zoom = 2
walk(2)
eq(result(10).status, "done", "zoomed: " .. detail(10))
settle()
S.Answer(true)                                             -- 11
settle()

-- Running, then turning while running.
WoW.speed = 7
walk(4)
eq(result(12).status, "done", "running with icons: " .. detail(12))
settle()
WoW.facing = 0.5
walk(1.2)
eq(record().at, 13, "waits for the turn")
WoW.facing = 3.0
walk(1.2)
eq(result(13).status, "done", "turned: " .. detail(13))
settle()
S.Answer(true)                                             -- 14
settle()
WoW.speed = 0

-- Indoors.
walk(1.2)
eq(record().at, 15, "waits indoors")
WoW.indoors = true
walk(1.2)
eq(result(15).status, "done", "indoors: " .. detail(15))
WoW.indoors = false
settle()

-- A gather: the record against the player at the cast.
Minimap._zoom = 0
walk(2.5)
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-9", 2366)
check(logged("gather: the Silverleaf icon's record 1.0 yd from the player"), "the cast: the record 1 yd off")
walk(1.2)
eq(result(16).status, "done", "gathered: " .. detail(16))

-- The cost: off, then on, a minute each, starting when the player moves.
walk(1.2)
eq(record().at, 17, "waits for the player to move")
WoW.speed = 7
walk(61)
eq(result(17).status, "done", "icons off: " .. detail(17))
local off = db.icons.cost["icons off"]
eq(off and off.icons, false, "...icons were off for it")
check(off and off.reads > 0 and off.sweeps > 0, "...reads and sweeps counted")
walk(61)
eq(result(18).status, "done", "icons on: " .. detail(18))
eq(db.icons.cost["icons on"].icons, true, "...on for it")
check(db.icons.cost["icons on"].sweeps > 0, "...counted")
WoW.speed = 0
check(NR.Step == STEP, "the sweep's timer taken off NodeRadar's NR.Step")

-- The stock map: skipped here; the setting put back.
S.Skip()                                                   -- 19: the reload
S.Skip()                                                   -- 20
S.Skip()                                                   -- 21
S.Skip()                                                   -- 22
eq(result(23).status, "done", "put back: " .. detail(23))
eq(rawget(NR.db, "icons"), nil, "NodeRadar's icons back to the player's default")
eq(db.restoreIcons, nil, "...nothing left to put back")
eq(record().at, 24, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
eq(WoW.softCursor, false, "the soft cursor is off")

done("test_probe_iconcheck")
