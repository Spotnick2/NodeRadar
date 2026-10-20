-- Snoozing the compass's node (#46, docs/PLAN.md "Snoozing the compass's
-- node"): a node put aside for a while by its spot (the same node measured
-- again too), the next one winning outright; the durations, clearing, the dim
-- at once; kept through the clears; the minimap button (no libraries: none),
-- its context menu (toggles, the snooze of the node it showed, clearing), the
-- right-click, the compartment; the key binding and the commands.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
WoW.noLibs = true                                          -- first: as if Libs\ were missing
local NR = loadAddon()
NR.Track.SetSmart(false)
local Icons, Compass, Button = NR.Icons, NR.Compass, NR.Minimap
local C, T = Compass._test, Icons._test
for _, id in ipairs({ 765, 2449 }) do WoW.itemCached[id] = true end

eq(Button.Available(), false, "no libraries: no button")
eq(NR.failures.menu, nil, "...and nothing failed")
WoW.noLibs = false
Button.Register()
eq(Button.Available(), true, "the libraries there: the button registered")
local btn = WoW.ldbi.buttons.NodeRadar
check(btn and btn._shown, "...shown by default")
check(WoW.ldbi.registered.NodeRadar == NR.db.minimap, "...LibDBIcon given NodeRadarDB.minimap, kept")

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
    NR.Step(WoW.now)
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) <= 1 end
local function at(n) local g = C.target(); return g and near(g.north, n.north) and near(g.west, n.west) end
local function rec(n)
    for _, r in ipairs(T.records()) do
        if r.name == n.name and near(r.north, n.north) and near(r.west, n.west) then return r end
    end
end
local function fresh()
    nodes = {}
    Icons.Clear()
    Compass.ClearSnoozes()
    WoW.pos = { 0, 0, 1 }
    step(1)
end

NR.Set("compass", true)
NR.Set("icons", true)

--------------------------------------------------------------------------------
-- Snoozing
--------------------------------------------------------------------------------

fresh()
local a = node("Silverleaf", 0, 30)                        -- 30 units: about 45 yards
local b = node("Silverleaf", 0, -31.5)                     -- 1.5 units farther (under the 5-yard hysteresis)
step(1)
check(at(a), "two nodes: the nearer Silverleaf the target")
eq(Compass.Snooze("bogus"), nil, "an unknown duration: nothing")
local snoozed = Compass.Snooze("15")
check(snoozed == rec(a), "snoozed: the target")
check(at(b), "...the next wins at once, outright (only 2 yards farther)")
eq(rec(a).dim, true, "...the snoozed icon dimmed at once, no sweep")
eq(rec(b).dim, false, "...the other not")
eq(Compass.SnoozeCount(), 1, "one snoozed")
step(1)
check(at(b), "...and at the sweep")
-- The same node measured again: its record dropped (off the map), then back.
a.gone = true
step(1); step(1)
eq(rec(a), nil, "the snoozed node's record dropped (missed twice)")
a.gone = nil
step(1)
check(rec(a) ~= nil, "back: measured again, a new record")
check(at(b) and rec(a).dim, "...still snoozed by its spot: the compass stays on the other, it dimmed")
-- The spot: within 8 yards the same node, past it another (a Silverleaf so
-- near couldn't be measured beside it: their squares overlap).
local r0 = rec(a)
eq(Compass.Snoozed({ name = "Silverleaf", north = r0.north + 7, west = r0.west }), true, "7 yards off: the same spot")
eq(Compass.Snoozed({ name = "Silverleaf", north = r0.north + 12, west = r0.west }), false, "12 yards off: not snoozed")
eq(Compass.Snoozed({ name = "Earthroot", north = r0.north, west = r0.west }), false, "another name at the spot: not")
-- Kept through the clears (a loading screen, death, tracking): records go, snoozes stay.
WoW.fire("LOADING_SCREEN_ENABLED")
eq(#T.records(), 0, "a loading screen clears the records")
eq(Compass.SnoozeCount(), 1, "...not the snoozes")
WoW.fire("LOADING_SCREEN_DISABLED")
-- Expiry: 15 minutes.
fresh()
a = node("Silverleaf", 0, 30)
b = node("Silverleaf", 0, -40)
step(1)
Compass.Snooze("15")
check(at(b), "15 minutes: on the other")
step(890)
check(at(b), "...still at 891 s")
step(10)
check(at(a), "...past 900 s: the snoozed one back at the sweep")
eq(rec(a).dim, false, "...undimmed")
eq(Compass.SnoozeCount(), 0, "...the snooze gone")
-- This session: never, until a clear.
Compass.Snooze("session")
check(at(b), "this session: on the other")
step(100000)
check(at(b), "...still, a day later")
Compass.ClearSnoozes()
check(at(a), "cleared: back at once, no sweep")
eq(rec(a).dim, false, "...undimmed at once")
-- Another instance: not snoozed.
Compass.Snooze("session")
WoW.pos[3] = 2
step(1)
check(at(a), "another instance at the same spot: not snoozed")
WoW.pos[3] = 1
Compass.ClearSnoozes()
-- Nothing to snooze.
fresh()
eq(Compass.Snooze("15"), nil, "no target: nothing snoozed")
eq(Compass.SnoozeCount(), 0, "...none")

--------------------------------------------------------------------------------
-- The minimap button's menu
--------------------------------------------------------------------------------

fresh()
a = node("Silverleaf", 0, 30)
b = node("Earthroot", 0, -40)
step(1)
Button.Click(btn, "LeftButton")
check(WoW.menu and WoW.menu.owner == btn, "left-click: a context menu on the button")
local radar = WoW.menuItem("Radar on")
local icons = WoW.menuItem("Item icons on the minimap")
local compass = WoW.menuItem("The compass (experimental)")
check(radar and icons and compass, "...its toggles")
eq(compass.isSelected(), true, "...the compass checked")
eq(compass.response, MenuResponse.CloseAll, "...a checkbox closes the menu (Codex)")
local snoozeItem = WoW.menuItem("Snooze ")
check(snoozeItem and snoozeItem.text:find("^Snooze Item 765, %d+ yd$"), "...the snooze of the compass's node: "
    .. tostring(snoozeItem and snoozeItem.text))
eq(#snoozeItem.children, 4, "...four durations")
eq(snoozeItem.children[4].text, "This session", "...the last this session")
eq(WoW.menuItem("Clear snoozes"), nil, "...no clear with nothing snoozed")
-- The compass moving on while the menu is open: the shown node snoozed.
WoW.pos[1] = WoW.pos[1] - 40 * K()                         -- south: the Earthroot now the nearer by far
step(1)
check(at(b), "the compass moved on while the menu was open")
eq(snoozeItem.children[2].callback(), MenuResponse.CloseAll, "30 minutes chosen: the menu closes")
check(rec(a) and Compass.Snoozed(rec(a)), "...the node the menu showed snoozed (the Silverleaf)")
eq(Compass.Snoozed(rec(b)), false, "...not the compass's new one")
-- Clearing from the menu.
Button.Click(btn, "LeftButton")
local clear = WoW.menuItem("Clear snoozes (1)")
check(clear, "the menu: Clear snoozes (1)")
clear.callback()
eq(Compass.SnoozeCount(), 0, "...cleared")
-- A toggle: NR.Set, and closed; reopened, the menu follows.
Button.Click(btn, "LeftButton")
eq(WoW.menuItem("The compass (experimental)").setSelected(), MenuResponse.CloseAll, "the compass unticked: closed")
eq(NR.db.compass, false, "...the compass off (NR.Set)")
Button.Click(btn, "LeftButton")
local why = WoW.menuItem("The compass is off")
check(why and why.enabled == false, "reopened: \"The compass is off\", disabled")
eq(WoW.menuItem("Snooze "), nil, "...no snooze")
WoW.menuItem("The compass (experimental)").setSelected()
eq(NR.db.compass, true, "ticked again: on")
fresh()
Button.Click(btn, "LeftButton")
check(WoW.menuItem("The compass has no node now"), "on with no node: says so")
WoW.menuItem("Item icons on the minimap").setSelected()
eq(NR.db.icons, false, "the icons toggled off")
WoW.menuItem("Radar on").setSelected()
eq(NR.db.enabled, false, "the radar toggled off")
NR.Set("enabled", true)
NR.Set("icons", true)
-- Right-click: the Options page.
WoW.openedCategory = nil
Button.Click(btn, "RightButton")
check(WoW.openedCategory, "right-click: the Options page")
-- The compartment: the addon's name first, so the menu at the cursor.
WoW.menu = nil
NodeRadar_OnAddonCompartmentClick("NodeRadar", "LeftButton")
check(WoW.menu and WoW.menu.owner == nil, "the compartment: the menu at the cursor (no owner)")
-- The button hidden by the setting; the compartment still works.
NR.Set("minimapButton", false)
eq(btn._shown, false, "the setting off: the button hidden")
eq(NR.db.minimap.hide, true, "...saved in LibDBIcon's table")
WoW.menu = nil
Button.Click(btn, "LeftButton")
check(WoW.menu and WoW.menu.owner == nil, "a click from a hidden button: the menu at the cursor")
NR.Set("minimapButton", true)
eq(btn._shown, true, "the setting on: shown")
-- /nr reset brings a hidden button back (Codex, PR #65), LibDBIcon's table kept.
NR.Set("minimapButton", false)
local saved, before = NR.db.minimap, {}
for k, v in pairs(NR.db) do before[k] = v end
SlashCmdList.NODERADAR("reset")
eq(btn._shown, true, "/nr reset: the hidden button shown again")
eq(NR.db.minimap.hide, false, "...LibDBIcon's table says so")
check(NR.db.minimap == saved, "...the same table LibDBIcon holds")
for k, v in pairs(before) do NR.db[k] = v end              -- the rest of this file's settings back
NR.db.minimapButton = true
-- The tooltip.
fresh()
a = node("Silverleaf", 0, 30)
step(1)
Compass.Snooze("15", rec(a))
node("Earthroot", 0, -40)
step(1)
GameTooltip._lines = nil
GameTooltip:SetText("")
Button._test.tooltip(GameTooltip, true)
local lines = table.concat(GameTooltip._lines or {}, " | ")
check(lines:find("The compass: Item 2449, %d+ yd") and lines:find("1 snoozed") and lines:find("Right%-click: settings")
    and lines:find("Drag: move"), "the tooltip: the compass's node, the snoozes, the clicks: " .. lines)
Compass.ClearSnoozes()

--------------------------------------------------------------------------------
-- The key binding and the commands
--------------------------------------------------------------------------------

eq(BINDING_NAME_NODERADAR_SNOOZE, "Snooze the compass's node", "the binding's line in Key Bindings")
local xml = io.open("Bindings.xml"):read("*a")
check(xml:find('name="NODERADAR_SNOOZE" category="NodeRadar"', 1, true) and xml:find("NodeRadar.Minimap.SnoozeKey()", 1, true),
    "Bindings.xml: its own category, the snooze")
fresh()
a = node("Silverleaf", 0, 30)
b = node("Earthroot", 0, -40)
step(1)
NR.db.snoozeFor = "60"
newChat()
Button.SnoozeKey()
check(at(b) and chatHas("snoozed Silverleaf for 1 hour"), "the key: the compass's node for the setting (1 hour)")
step(3590)
check(at(b), "...still at 59 minutes")
step(15)
check(at(a), "...back past the hour")
NR.db.snoozeFor = nil
SlashCmdList.NODERADAR("snooze")
check(at(b) and chatHas("for this session"), "/nr snooze: the setting's default, this session")
SlashCmdList.NODERADAR("snooze clear")
check(at(a), "/nr snooze clear")
SlashCmdList.NODERADAR("snooze 15")
check(at(b) and NR.db.snoozeFor == "15", "/nr snooze 15: snoozed, and kept as the key's length")
Compass.ClearSnoozes()
fresh()
newChat()
SlashCmdList.NODERADAR("snooze")
check(chatHas("no node to snooze"), "/nr snooze with no node: says so")
NR.db.snoozeFor = nil

-- Options: the button's checkbox and the key's length.
NR.Options._test.panel:Show()
check(NR.Options._test.checks.minimapButton, "Options: the minimap button's checkbox")
eq(#(NR.Options._test.radios.snoozeFor or {}), 4, "...the key's four lengths")

eq(WoW.softCursor, false, "the soft cursor is off")
done("test_snooze")
