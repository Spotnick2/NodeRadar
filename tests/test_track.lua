-- Choosing which herbs and ores (#47, docs/PLAN.md "Choosing which herbs and
-- ores"): the per-character list by item, cleaned at load; the items' states
-- from the base rank; the presets; smart following the skill; the rule in the
-- alert, the compass and the icons (dimmed or Blizzard's dot), at once; the
-- commands; the Herbs and Ores pages.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
for _, n in ipairs({ "Peacebloom", "Earthroot", "Mageroyal", "Briarthorn" }) do TEST_LIBRARY.enUS[n] = "herbs" end
for _, n in ipairs({ "Copper Vein", "Tin Vein", "Small Thorium Vein", "Rich Thorium Vein" }) do
    TEST_LIBRARY.enUS[n] = "ore"
end
-- Saved junk, cleaned at load.
local NR = loadAddon({ charDb = { track = { ignored = { [2447] = true, [785] = 1, Silverleaf = true },
                                            smart = "yes", last = { herbs = "x", ore = 40 } } } })
local Track, Icons, Compass, Alert = NR.Track, NR.Icons, NR.Compass, NR.Alert
local C, T = Compass._test, Icons._test
for _, id in ipairs({ 765, 2447, 2449, 785, 2450, 2770, 2771, 10620 }) do WoW.itemCached[id] = true end

local function herbs(rank, modifier)
    WoW.skillLines[182] = rank and { skillID = 182, rank = rank, modifier = modifier or 0, maxRank = 300 } or nil
end
local function mining(rank)
    WoW.skillLines[186] = rank and { skillID = 186, rank = rank, modifier = 0, maxRank = 300 } or nil
end
local function skipped(item) return Track.Ignored(item) end
local function rowOf(item)
    for _, kind in ipairs(Track.KINDS) do
        for _, row in ipairs(Track.List(kind)) do if row.item == item then return row end end
    end
end
local PEACE, LEAF, EARTH, MAGE, BRIAR = 2447, 765, 2449, 785, 2450
local COPPER, TIN, THORIUM = 2770, 2771, 10620

--------------------------------------------------------------------------------
-- Load: the per-character table cleaned
--------------------------------------------------------------------------------

local t = NodeRadarCharDB.track
eq(t.ignored[PEACE], true, "a saved item ID kept")
eq(t.ignored[MAGE], nil, "...a value not true dropped")
eq(t.ignored.Silverleaf, nil, "...a name key dropped (IDs, never names)")
eq(t.smart, nil, "a smart that isn't a boolean: the default")
check(Track.Smart(), "...smart on by default")
eq(t.last.herbs, nil, "a last rank that isn't a number dropped")
eq(t.last.ore, 40, "...a number kept")
t.ignored, t.last = {}, {}

--------------------------------------------------------------------------------
-- The lists and the states
--------------------------------------------------------------------------------

local list = Track.List("herbs")
local order = {}
for _, row in ipairs(list) do order[#order + 1] = row.item end
eq(table.concat(order, " "), "765 2447 2449 785 2450", "herbs by lowest requirement, then item ID")
eq(#Track.List("ore"), 3, "ores: Copper, Tin, Thorium (two veins, one item)")
local th = rowOf(THORIUM)
eq(#th.nodes, 2, "Thorium Ore: two nodes")
check(th.nodes[1].name == "Small Thorium Vein" and th.nodes[1].skill == 245 and th.nodes[2].skill == 275,
    "...by skill, each its own")
check(th.low == 245 and th.high == 275, "...lowest 245, highest 275")
eq(Track.State(th, 244), "low", "244: not gatherable")
eq(Track.State(th, 245), "up", "245: skill-ups (the lowest node)")
eq(Track.State(th, 374), "up", "374: skill-ups still (Rich isn't grey)")
eq(Track.State(th, 375), "grey", "375: grey (the highest + 100)")
eq(Track.State(th, nil), nil, "no rank: no state")
herbs(120, 15)
eq(Track.Rank("herbs"), 120, "the base rank, the modifier left out")
eq(NR.API.Skill(182), 135, "...while the effective skill keeps it (#26)")
herbs(nil)
eq(Track.Rank("herbs"), nil, "no Herbalism: no rank")

--------------------------------------------------------------------------------
-- The presets
--------------------------------------------------------------------------------

Track.SetSmart(false)
herbs(60)
check(Track.Preset("herbs", "gather"), "all I can gather")
check(not skipped(PEACE) and not skipped(MAGE) and skipped(BRIAR), "...up to Mageroyal (50), not Briarthorn (70)")
eq(Track.Count("ore"), 0, "...ores untouched")
herbs(120)
check(Track.Preset("herbs", "skillups"), "skill-ups only at 120")
check(skipped(PEACE) and skipped(LEAF) and skipped(EARTH), "...Peacebloom, Silverleaf (1) and Earthroot (15) grey")
check(not skipped(MAGE) and not skipped(BRIAR), "...Mageroyal and Briarthorn give skill-ups")
check(Track.Preset("herbs", "gather"), "all I can gather at 120")
check(not skipped(PEACE) and not skipped(BRIAR), "...grey ones too")
Track.Preset("herbs", "none")
eq(Track.Count("herbs"), 5, "none")
Track.Preset("herbs", "all")
eq(Track.Count("herbs"), 0, "all")
mining(nil)
Track.Set(TIN, false)
eq(Track.Preset("ore", "skillups"), false, "no Mining: skill-ups refused")
eq(Track.Preset("ore", "gather"), false, "...all I can gather too")
check(skipped(TIN) and Track.Count("ore") == 1, "...nothing changed")
Track.Preset("ore", "all")

--------------------------------------------------------------------------------
-- Smart
--------------------------------------------------------------------------------

herbs(60)
Track.SetSmart(true)
check(skipped(BRIAR) and not skipped(MAGE), "on at 60: skill-ups only (Briarthorn not yet)")
eq(t.last.herbs, 60, "...from 60")
eq(Track.Count("ore"), 0, "...no Mining: ores untouched")
Track.Set(MAGE, false)                                     -- the player's own click
herbs(70)
Track.Follow()
check(not skipped(BRIAR), "70: Briarthorn reached, checked")
check(skipped(MAGE), "...Mageroyal, the player's, untouched")
herbs(100)
Track.Follow()
check(not skipped(PEACE), "100: Peacebloom not grey yet")
herbs(101)
Track.Follow()
check(skipped(PEACE) and skipped(LEAF), "101: Peacebloom and Silverleaf turned grey, unchecked")
Track.Set(PEACE, true)                                     -- the player wants it anyway
herbs(110)
Track.Follow()
check(not skipped(PEACE), "...checked by the player, it stays")
-- The modifier moving changes nothing.
herbs(110, 10)
check(not Track.Follow(), "a +10 tool: no change")
herbs(110, 0)
check(not Track.Follow(), "...taken off: no change, the player's clicks stand")
check(not skipped(PEACE), "...Peacebloom still checked")
-- One rise across both lines: unchecked.
herbs(10)
Track.SetSmart(false)
Track.SetSmart(true)                                       -- starts over at 10
check(skipped(EARTH), "on again at 10: Earthroot (15) not yet")
herbs(120)
Track.Follow()
check(skipped(EARTH), "10 to 120: Earthroot reached (15) and grey (115) in one rise: unchecked")
check(not skipped(MAGE), "...Mageroyal reached: checked")
-- The base rank going down: unlearned, learned again: starts over.
herbs(1)
Track.Follow()
check(not skipped(PEACE) and skipped(EARTH) and skipped(MAGE), "down to 1: skill-ups only again")
-- Off: nothing.
Track.SetSmart(false)
herbs(60)
check(not Track.Follow(), "smart off: Follow does nothing")
check(skipped(MAGE), "...Mageroyal stays unchecked")
-- On again at the same rank: starts over from skill-ups only.
Track.Preset("herbs", "all")
Track.SetSmart(true)
check(skipped(BRIAR), "smart on again at 60: Briarthorn (70) unchecked, a fresh start")
Track.SetSmart(false)
-- SKILL_LINES_CHANGED runs it.
Track.SetSmart(true)
herbs(80)
WoW.fire("SKILL_LINES_CHANGED")
eq(t.last.herbs, 80, "SKILL_LINES_CHANGED: followed")
Track.SetSmart(false)
Track.Preset("herbs", "all")
Track.Preset("ore", "all")

--------------------------------------------------------------------------------
-- The rule: the alert, the compass, the icons
--------------------------------------------------------------------------------

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y)
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    nodes[#nodes + 1] = n
    return n
end
local function place()
    local l = {}
    for _, n in ipairs(nodes) do
        if not n.gone then
            l[#l + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
        end
    end
    WoW.blips = l
end
local function step(dt)
    WoW.now = WoW.now + (dt or 1)
    place()
    local before = WoW.reads
    NR.Step(WoW.now)
    return WoW.reads - before
end
local function rec(name)
    for _, r in ipairs(T.records()) do if r.name == name then return r end end
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) <= 1 end
local function at(n) local g = C.target(); return g and near(g.north, n.north) and near(g.west, n.west) end
local function fresh()
    nodes = {}
    Icons.Clear()
    WoW.pos = { 0, 0, 1 }
    step(1)
end
herbs(300)                                                 -- every herb gatherable (#26 out of the way)

-- The alert: a skipped item never alerts; tracked again, nodes in view aren't new.
eq(Alert.Ignored("Stunted Silverleaf"), false, "a name without NODE_INFO: never skipped")
Track.Set(LEAF, false)
eq(Alert.Ignored("Silverleaf"), true, "Silverleaf's item unchecked: skipped")
eq(Alert.Wanted("Silverleaf"), false, "...not wanted")
eq(Alert.Wanted("Earthroot"), true, "...Earthroot still wanted")
fresh()
step(6)                                                    -- the silent baseline
local sounds = #WoW.sounds
node("Silverleaf", 30, 30)
step(6)
eq(#WoW.sounds, sounds, "a new Silverleaf: no sound")
node("Earthroot", -30, 30)
step(6)
eq(#WoW.sounds, sounds + 1, "a new Earthroot: the alert")
Track.Set(LEAF, true)
step(6)
eq(#WoW.sounds, sounds + 1, "Silverleaf tracked again: the one in view isn't new")
node("Silverleaf", 30, -30)
step(6)
eq(#WoW.sounds, sounds + 2, "...a second one is")

-- The compass: a skipped node passed over; a skipped incumbent replaced at once.
NR.Set("compass", true)
fresh()
local close = node("Silverleaf", 0, 30)
local farther = node("Earthroot", 0, -60)
step(1)
check(at(close), "the nearer Silverleaf the target")
Track.Set(LEAF, false)
check(at(farther), "Silverleaf skipped: the Earthroot at once, no sweep")
step(1)
check(at(farther), "...and at the sweep")
Track.Set(EARTH, false)
eq(C.target(), nil, "every node skipped: no target")
eq(C.root._shown, false, "...hidden")
eq(rec("Silverleaf"), nil, "the compass alone keeps no record of a skipped node")
Track.Set(LEAF, true)
Track.Set(EARTH, true)
step(1)
check(at(close), "tracked again: the Silverleaf back at the sweep")
NR.Set("compass", false)

-- The icons, dimmed (the default).
NR.Set("icons", true)
fresh()
node("Silverleaf", 30, 0)
step(1)
local r = rec("Silverleaf")
eq(r and r.dim, false, "tracked: not dimmed")
Track.Set(LEAF, false)
eq(rec("Silverleaf"), r, "skipped, dimmed: the record kept")
eq(r.dim, true, "...dimmed at once")
step(1)
eq(rec("Silverleaf").dim, true, "...and at the sweep")
Track.Set(LEAF, true)
eq(r.dim, false, "tracked again: undimmed at once")

-- The compass with the icons on: the dimmed record is there, still not its target.
NR.Set("compass", true)
local cl = node("Silverleaf", 0, 20)
local fa = node("Earthroot", 0, -60)
step(1)
check(at(cl), "icons and compass: the nearer Silverleaf")
Track.Set(LEAF, false)
check(rec("Silverleaf") and at(fa), "...skipped: kept dimmed, the compass on the Earthroot")
Track.Set(LEAF, true)
NR.Set("compass", false)
nodes = { nodes[1] }
step(1); step(1)
-- Blizzard's dot chosen while a node is skipped: its record gone at once.
Track.Set(LEAF, false)
check(rec("Silverleaf"), "skipped, dimmed: kept")
NR.Set("ignoredIcon", "dot")
eq(rec("Silverleaf"), nil, "Blizzard's dot chosen: gone at once")
NR.Set("ignoredIcon", "dim")
Track.Set(LEAF, true)
step(1)
-- Blizzard's dot: the record goes at once, nothing measured.
NR.Set("ignoredIcon", "dot")
Track.Set(LEAF, false)
eq(rec("Silverleaf"), nil, "skipped, Blizzard's dot: the record gone at once")
local reads = step(1)
eq(rec("Silverleaf"), nil, "...not measured again")
Track.Set(LEAF, true)
local measured = step(1)
check(rec("Silverleaf") ~= nil, "tracked again: measured at the sweep")
check(measured > reads + 20, ("...measuring costs reads (%d), the skipped sweep didn't (%d)"):format(measured, reads))
Track.Set(LEAF, false)
NR.Set("ignoredIcon", "dim")
eq(rec("Silverleaf"), nil, "back to dimmed: nothing to show until it's measured")
step(1)
eq(rec("Silverleaf") and rec("Silverleaf").dim, true, "...measured at the sweep, dimmed")
Track.Set(LEAF, true)
NR.Set("icons", false)

-- The sweep runs smart before the icons.
Track.SetSmart(true)
herbs(290)
local seen
local update = Icons.Update
Icons.Update = function(...) seen = t.last.herbs; return update(...) end
step(1)
Icons.Update = update
eq(seen, 290, "the sweep followed the skill before the icons")
Track.SetSmart(false)
Track.Preset("herbs", "all")

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

newChat()
SlashCmdList.NODERADAR("ignore small thorium vein")
check(skipped(THORIUM), "/nr ignore by a node's name, any case")
check(chatHas("Item 10620: skipped %(Small Thorium Vein, Rich Thorium Vein%)"), "...named back with its nodes")
SlashCmdList.NODERADAR("track 10620")
check(not skipped(THORIUM), "/nr track by item ID")
WoW.itemNames[PEACE] = "Peacebloom Flower"
SlashCmdList.NODERADAR("ignore peacebloom flower")
check(skipped(PEACE), "/nr ignore by the item's name")
SlashCmdList.NODERADAR("ignore Stranglethorn")
check(chatHas("no herb or ore called Stranglethorn"), "an unknown name: said")
newChat()
SlashCmdList.NODERADAR("ignore")
local lines = newChat()
check(#lines == 1 and lines[1]:find("Peacebloom Flower %(2447%)"), "/nr ignore alone: the list")
SlashCmdList.NODERADAR("track 2447")
newChat()
SlashCmdList.NODERADAR("ignore")
check(newChat()[1]:find("nothing skipped"), "...empty: said")
SlashCmdList.NODERADAR("smart")
check(Track.Smart(), "/nr smart: on")
SlashCmdList.NODERADAR("smart")
check(not Track.Smart(), "...off")
Track.Preset("herbs", "all")                               -- smart on at 300 unchecked the grey ones
SlashCmdList.NODERADAR("status")
check(chatHas("skipped: 0 herbs, 0 ores; smart"), "/nr status says the list")
Track.Preset("herbs", "all")

--------------------------------------------------------------------------------
-- The pages
--------------------------------------------------------------------------------

local P = NR.TrackOptions._test
local H = P.herbs
eq(H.panel._shown, false, "Herbs: hidden at creation")
eq(H.built, nil, "...not built before it shows")
herbs(60)
WoW.itemCached[2450] = nil                                 -- Briarthorn's item not cached yet
WoW.itemRequests = {}
H.panel:Show()
check(H.built, "built on the first show")
eq(#H.rows, 5, "one row per herb item")
eq(H.rows[1].row.item, LEAF, "...sorted: Silverleaf first")
eq(H.rows[5].name._text, "Briarthorn", "an uncached item: its node's name meanwhile")
eq(#WoW.itemRequests, 1, "...asked for once")
eq(WoW.itemRequests[1], 2450, "...Briarthorn's")
eq(H.rows[1].name._text, "Item 765", "a cached item: its name")
eq(H.rows[4].skill._text, "|cffff804050|r", "Mageroyal 50 at 60: orange")
eq(H.rows[1].skill._text, "|cff40c0401|r", "Silverleaf 1 at 60: green")
eq(H.rows[5].skill._text, "|cffff202070|r", "Briarthorn 70 at 60: red, not yet")
-- Three columns, filled top to bottom: five herbs, two to a column.
local function spot(i) local p = H.rows[i].cell._points[1]; return p[4], p[5] end
local x1, y1 = spot(1)
local x2, y2 = spot(2)
local x3, y3 = spot(3)
local x5 = spot(5)
check(x1 == 0 and x2 == 0 and y2 < y1, "the first column: rows 1 and 2, top to bottom")
check(x3 > x1 and y3 == y1, "...row 3 tops the second column")
check(x5 > x3, "...row 5 in the third")
-- Hovering a row: its nodes, each with its skill.
H.rows[4].cell._scripts.OnEnter(H.rows[4].cell)
eq(GameTooltip._owner, H.rows[4].cell, "a row hovered: its tooltip")
eq(GameTooltip._text, "Item 785", "...the item")
eq(GameTooltip._lines and GameTooltip._lines[1], "Mageroyal |cffff804050|r", "...its node and skill")
H.rows[4].cell._scripts.OnLeave(H.rows[4].cell)
eq(GameTooltip._shown, false, "...hidden on leaving")
-- The name clicks the box too.
H.rows[2].cell._scripts.OnMouseUp(H.rows[2].cell)
check(skipped(PEACE) and not H.rows[2].check:GetChecked(), "clicking Peacebloom's name: skipped")
H.rows[2].cell._scripts.OnMouseUp(H.rows[2].cell)
check(not skipped(PEACE), "...again: tracked")
H.panel:Hide()
H.panel:Show()
eq(#WoW.itemRequests, 1, "shown again: not asked again")
WoW.itemCached[2450] = true
H.panel._scripts.OnEvent(H.panel, "ITEM_DATA_LOAD_RESULT", 785, true)
eq(H.rows[5].name._text, "Briarthorn", "another item's event: no re-read")
H.panel._scripts.OnEvent(H.panel, "ITEM_DATA_LOAD_RESULT", 2450, true)
eq(H.rows[5].name._text, "Item 2450", "its event: the name filled")
-- Clicks.
WoW.click(H.rows[2].check)
check(skipped(PEACE), "a row unchecked: skipped")
WoW.click(H.rows[2].check)
check(not skipped(PEACE), "...checked: tracked")
WoW.click(H.buttons.none)
eq(Track.Count("herbs"), 5, "None")
eq(Track.Count("ore"), 0, "...the ores untouched")
check(not H.rows[1].check:GetChecked(), "...the rows re-read")
WoW.click(H.buttons.gather)
check(not skipped(MAGE) and skipped(BRIAR), "All I can gather")
WoW.click(H.buttons.all)
eq(Track.Count("herbs"), 0, "All")
herbs(nil)
WoW.click(H.buttons.skillups)
check(H.why._text:find("no Herbalism"), "Skill-ups without the skill: said")
eq(Track.Count("herbs"), 0, "...nothing changed")
herbs(60)
WoW.click(H.smart)
check(Track.Smart() and H.smart:GetChecked(), "the smart checkbox: on")
check(skipped(BRIAR), "...and the list follows at once")
SlashCmdList.NODERADAR("smart")
check(not H.smart:GetChecked(), "/nr smart while shown: the page re-reads")
H.panel:Hide()
SlashCmdList.NODERADAR("ignore Silverleaf")
H.panel:Show()
check(not H.rows[1].check:GetChecked(), "a change while hidden shows at the next show")
-- Ores: the same builder.
P.ore.panel:Show()
eq(#P.ore.rows, 3, "Ores: one row per ore item")
mining(260)
P.ore.panel:Hide(); P.ore.panel:Show()
eq(P.ore.rows[3].skill._text, "|cffff8040245|r-|cffff2020275|r", "Thorium at 260: 245 orange, 275 red")
P.ore.rows[3].cell._scripts.OnEnter(P.ore.rows[3].cell)
eq(#GameTooltip._lines, 2, "...hovered: both veins")
eq(GameTooltip._lines[2], "Rich Thorium Vein |cffff2020275|r", "...each with its own skill")
P.ore.rows[3].cell._scripts.OnLeave(P.ore.rows[3].cell)
mining(nil)
P.ore.panel:Hide()
H.panel:Hide()
-- The sub-page API missing: a failure, not an error.
NR.failures["track pages"] = nil
local reg = Settings.RegisterCanvasLayoutSubcategory
Settings.RegisterCanvasLayoutSubcategory = nil
NR.TrackOptions.Register({})
Settings.RegisterCanvasLayoutSubcategory = reg
check(NR.failures["track pages"], "no sub-page API: recorded (/nr failures)")
-- The colours' lines.
local col = NR.TrackOptions.colour
check(col(50, 49) == "ffff2020" and col(50, 50) == "ffff8040" and col(50, 75) == "ffffff00"
      and col(50, 100) == "ff40c040" and col(50, 149) == "ff40c040" and col(50, 150) == "ff808080",
    "the colours: red, orange, yellow at +25, green at +50, grey at +100")

eq(WoW.softCursor, false, "the soft cursor is off")
checkMethods({ "CheckButton:SetChecked", "FontString:SetText" })
done("test_track")
