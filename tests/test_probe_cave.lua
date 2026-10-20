-- The cave procedure (/fp steps nr cave, #63): indoors/outdoors changes, zoom
-- events and SetZoom calls, NodeRadar's steps, resets, updates and fires
-- around them, node rows with their colours; NodeRadar's functions put back at
-- the end. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = 42, modifier = 0, maxRank = 75 }
local NR = loadAddon()
NR.NODE_INFO = { enUS = { ["Silverleaf"] = { skill = 1, item = 765 } } }
local FP = loadForeverProbe()
local NS = loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB
for i = 1, 4 do rawset(_G, "GameTooltipTextLeft" .. i, GameTooltip:CreateFontString()) end
local names = { "Alert.Reset", "Alert.NewArea", "Alert.Update", "Alert.Fire", "Alert.Gathered", "Scan.Plain", "Step" }
local function current()
    return { NR.Alert.Reset, NR.Alert.NewArea, NR.Alert.Update, NR.Alert.Fire, NR.Alert.Gathered, NR.Scan.Plain,
        NR.Step }
end
local originals = current()

local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function record() return FP.db.steps.records["NodeRadarProbe/cave"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 4 do WoW.advance(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end
end
local function hover(text)
    WoW.cursorOnMap = text ~= nil
    GameTooltipTextLeft1:SetText(text)
end
local function zoom(z)
    Minimap:SetZoom(z)
    WoW.fire("MINIMAP_UPDATE_ZOOM")
end
local function waitFor(i)
    for _ = 1, 40 do if result(i).status == nil then poll() end end
end

-- The measured format (porting guide, "Who wrote a chat line"): the call site, then the definition.
local STACK = "[Interface/AddOns/NodeRadarProbe/NodeRadarProbe.lua]:4600: in function <Interface/AddOns/NodeRadarProbe/NodeRadarProbe.lua:4598>\n"
    .. "[Interface/AddOns/NodeRadar/NodeRadar.lua]:207: in function <Interface/AddOns/NodeRadar/NodeRadar.lua:180>\n"
local where = NS._caveTest.cave().where
eq(where(STACK), "NodeRadar.lua:207", "the call site, past the probe's frames, not the definition")
eq(where('[string "@Interface/AddOns/NodeRadar/NodeRadar.lua"]:97: in function <...>'), "NodeRadar.lua:97",
    "...the older format too")
eq(where(nil), "?", "...no stack: unknown")

WoW.blips = { { "Silverleaf", 20, 0, kind = "herbs" } }
fp("steps nr cave")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
check(detail(1):find("watching: indoors false") and detail(1):find("NodeRadar enabled true"), "...the start logged")
local wrapped = current()
for i, f in ipairs(originals) do check(wrapped[i] ~= f, "...wrapped: " .. names[i]) end

GameTooltipTextLeft1:SetText("Silverleaf")                 -- a node's world tooltip: not the minimap's
poll()
eq(result(2).status, nil, "the cursor off the minimap: waits")
hover("Silverleaf")
poll()
eq(result(2).status, "done", "a node in the open: " .. detail(2))
check(detail(2):find("Silverleaf: row Silverleaf") and detail(2):find("indoors false"), "...its row and the state")
settle()
hover(nil)

poll()
eq(result(3).status, nil, "no zoom yet: waits")
zoom(1); zoom(0)
poll(); poll(); poll()
eq(result(3).status, "done", "zoomed outdoors: " .. detail(3))
check(detail(3):find("Minimap:SetZoom%(1%); indoors false"), "...the SetZoom call seen")
check(detail(3):find("MINIMAP_UPDATE_ZOOM: IsIndoors false %(last polled false%)"), "...the event with the state")

WoW.indoors = true
poll()
eq(result(4).status, "done", "indoors: " .. detail(4))
check(detail(4):find("now INDOORS; zoom 0, radius"), "...the change and the view logged")

S.Skip()                                                   -- 5: no node inside
WoW.blips = { { "Silverleaf", 20, 0, kind = "herbs", colour = { 0.5, 0.5, 0.5 } } }   -- grey in its leftColor only
poll()
zoom(1); zoom(0)
poll()
eq(result(6).status, nil, "zoomed but not 30 s inside: waits")
NS._caveTest.uninstall()                                   -- a reload drops the wrappers and the state
poll()
check(NR.Alert.Update ~= originals[3], "...installed again after it")
zoom(1); zoom(0)
waitFor(6)
eq(result(6).status, "done", "30 s inside: " .. detail(6))
check(detail(6):find("(resumed after a reload: inconclusive)", 1, true), "...said inconclusive after the reload")
check(detail(6):find("watching again (after a reload", 1, true), "...and timed from it")
local function logged(text)
    for _, l in ipairs(db.cave.events) do if l:find(text, 1, true) then return true end end
end
check(logged("a node row coloured: Silverleaf | 808080 | indoors"), "...a grey leftColor kept")

WoW.indoors = false
poll()
eq(result(7).status, nil, "out, no updates yet: waits")
rawset(_G, "debugstack", function() return STACK end)
zoom(1)                                                    -- a zoom on the way out: a reset
WoW.blips = { { "Silverleaf", 20, 0, kind = "herbs" }, { "|cff808080Silverleaf|r", -30, 10, kind = "herbs" } }
waitFor(7)
eq(result(7).status, "done", "five updates outdoors: " .. detail(7))
local d7 = detail(7)
check(d7:find("now outdoors"), "...the change logged")
check(d7:find("update %(a baseline: a reset at NodeRadar.lua:207%): [^/]*rises Silverleaf %(not counted%)[^/]*alerted nothing"),
    "...the reset's baseline, silent, by its call site")
check(d7:find("a node row coloured: ||cff808080Silverleaf||r | ffffff | outdoors", 1, true),
    "...the coloured row, raw, with leftColor")
S.Answer(false)                                            -- 8

poll()
WoW.indoors = true
local outside = WoW.blips
WoW.blips = { outside[1] }                                 -- the smaller view indoors
poll(); poll(); poll()
WoW.indoors = false
WoW.blips = { outside[1], outside[2], { "Silverleaf", 40, -40, kind = "herbs" },
    { "Wilted Peacebloom", -40, -40, kind = "herbs" } }
waitFor(9)
eq(result(9).status, "done", "a short visit: " .. detail(9))
local d9 = detail(9)
check(d9:find("the visit %d s;"), "...its length")
check(d9:find("rises Silverleaf %(drop %d+ s ago: a blink, wanted%), Wilted Peacebloom %(drop none, wanted%)"),
    "...both rises, the blink's with its drop")
check(d9:find("FIRE Wilted Peacebloom %(sound true, chat false%)"), "...the fire seen, the blink held")
S.Answer(true)                                             -- 10
poll()
S.Skip()                                                   -- 11
poll()
local mark = #db.cave.events
local function later(pattern)
    for i = mark + 1, #db.cave.events do if db.cave.events[i]:find(pattern) then return true end end
end
local open = WoW.blips
WoW.blips = { open[1], open[2], open[3] }                  -- the Peacebloom out of view
poll(); poll()
zoom(0)                                                    -- a reset (from 1): the mirror forgets the drop
poll(); poll()
WoW.advance(5)
WoW.blips = open
poll(); poll()
check(later("Wilted Peacebloom %(drop none, wanted%)"), "a drop before a reset forgotten, as Alert does")
check(later("FIRE Wilted Peacebloom"), "...and it alerts")
WoW.tracking[1].active = false
poll()
check(later("a step without an update: [^/]*tracking on false; sweep not run"), "tracking off: the gate named")
WoW.tracking[1].active = true
WoW.secretNames = true
poll()
check(later("a step without an update: [^/]*tracking on true; sweep failed: "), "a failed sweep: its reason")
WoW.secretNames = nil
WoW.tracking[1].active = false                             -- a pause past the stale gap, then a new area (Codex)
WoW.advance(10)
WoW.fire("ZONE_CHANGED_NEW_AREA")
WoW.tracking[1].active = true
poll(); poll()
check(later("update %(after a new area: counts from zero%): [^/]*rises [^/]*Silverleaf %(drop none, wanted%)"),
    "a new area after a pause: counted from zero, as Alert does")
check(not later("a baseline: stale"), "...not a stale baseline")
WoW.fire("ZONE_CHANGED_NEW_AREA")
zoom(1)                                                    -- a reset after it: a baseline after all
local seen = #db.cave.events
poll(); poll()
local after
for i = seen + 1, #db.cave.events do
    if db.cave.events[i]:find("update %(a baseline") then after = db.cave.events[i] end
end
check(after and after:find("a reset at") and not after:find("new area"), "a new area then a reset: a baseline, not from zero: "
    .. tostring(after))
WoW.blips = { { "Silverleaf", 20, 0, kind = "herbs" }, { "Silverleaf", 21, 0, kind = "herbs", colour = { 0.5, 0.5, 0.5 } } }
poll(); poll()
check(later("a node row coloured: Silverleaf | ambiguous ffffff/808080 | outdoors", 1, true)
    or later("a node row coloured: Silverleaf | ambiguous 808080/ffffff | outdoors"), "two lines of a row's text: both colours")
rawset(_G, "debugstack", nil)
S.Answer(false)                                            -- 12
poll()
eq(result(13).status, "done", "the summary: " .. detail(13))
check(detail(13):find("Silverleaf | ffffff | outdoors x%d+") and detail(13):find("%(%d+ second reads%)"),
    "...the rows counted with their colours")
local back = current()
for i, f in ipairs(originals) do eq(back[i], f, names[i] .. " put back") end
eq(record().at, 14, "at the last reload")
local lines = #db.log
zoom(1)
eq(#db.log, lines, "the SetZoom hook silent once the round is over")
fp("steps stop")

eq(errors(), 0, "no step threw")
for _, l in ipairs(WoW.chat) do check(not l:find("cave"), "nothing of the probe in chat: " .. l) end
done("test_probe_cave")
