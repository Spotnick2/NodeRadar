-- Every widget method the addon calls must exist on this client, on that
-- widget type: the stub answers any method (a no-op for one it doesn't
-- implement), so a call Forever lacks would otherwise pass silently. The
-- addon is exercised as widely as is cheap (loaded, every event, a radar
-- running with a node in view and every feature on, every Options page, the
-- minimap button and its menu, every /nr command), then WowTestKit's
-- Kit.checkMethods checks each recorded "Type:Method" against the pinned
-- build's widget methods (harness: checkMethods, with the allow list).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
WoW.BLIP_HALF = 12.5
WoW.blips = { { "Silverleaf", 30, -20, kind = "herbs" } }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
NR.db.learn = false

-- Every event, then a few seconds of frames and timers.
WoW.fireAllRegistered()
for _ = 1, 5 do WoW.tick(); WoW.advance(1) end

-- Every frame under f, depth first.
local function walk(f, fn)
    fn(f)
    for _, c in ipairs(f._children or {}) do walk(c, fn) end
end
-- Hover and click everything clickable on a page: tooltips, checkboxes, radios, buttons.
local function poke(frame)
    walk(frame, function(w)
        local s = w._scripts
        if s.OnEnter then s.OnEnter(w) end
        if s.OnLeave then s.OnLeave(w) end
        if s.OnClick and (w._type == "Button" or w._type == "CheckButton") and not w._protected then
            s.OnClick(w, "LeftButton", false)
        end
    end)
end

-- Every /nr command, the features on first: the icons, the compass, the marker, the
-- sharing, with a radar sweeping a node in view and the player on the move.
WoW.speed = 4.7
for _, cmd in ipairs({ "skill", "icons", "iconstyle glass", "iconsize large", "compass", "compasssize large",
    "marker", "share", "party", "tooltip" }) do
    SlashCmdList.NODERADAR(cmd)
    WoW.advance(2)
end
WoW.hover(30, -20)
WoW.buildMinimapTooltip()          -- the node's hover tooltip: Tooltip.lua's post-call
WoW.advance(5)
for _, style in ipairs({ "plain", "bronze", "yellow", "auto" }) do
    SlashCmdList.NODERADAR("iconstyle " .. style)
    WoW.advance(1)
end
for _, size in ipairs({ "small", "medium" }) do
    SlashCmdList.NODERADAR("iconsize " .. size)
    SlashCmdList.NODERADAR("compasssize " .. size)
end
WoW.altDown = true
WoW.tick()                          -- the compass's Alt-drag grip
WoW.altDown = false
for _, cmd in ipairs({ "", "status", "known", "failures", "help", "options", "test", "cd 5", "smart",
    "ignore", "track Silverleaf", "ignore Silverleaf", "ignore", "sound sonar", "sound ping", "sound", "ring",
    "chat", "ping", "learn", "compass lock", "compass unlock", "compass reset", "snooze 15", "snooze",
    "snooze clear", "forget Silverleaf", "reset" }) do
    SlashCmdList.NODERADAR(cmd)
    WoW.advance(1)
end

-- The Options pages: the page, Herbs and Ores, each shown and every control poked.
for _, category in ipairs(WoW.categories) do
    category.frame:Show()
    poke(category.frame)
    category.frame:Show()
end
check(#WoW.categories >= 3, "the Options page and its two sub-pages were opened")

-- The minimap button, its menu, and the key binding's snooze.
local button = WoW.ldbi.buttons.NodeRadar
check(button ~= nil, "the minimap button exists")
if button then
    button._scripts.OnClick(button, "LeftButton")
    button._scripts.OnClick(button, "RightButton")
end
WoW.advance(2)

local recorded = checkMethods()
check(recorded >= 100,"the exercise reached the addon's windows (" .. recorded .. " recorded)")

done("test_methods")
