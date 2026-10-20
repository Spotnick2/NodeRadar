-- Minimap.lua: NodeRadar's minimap button, its context menu, the AddOns
-- compartment and the key binding (#46, docs/PLAN.md "Snoozing the compass's
-- node"). The owner's sibling addons' recipe (GuildSpy's Minimap.lua, after
-- Gnomesweeper's): a LibDataBroker launcher shown by LibDBIcon (Libs\), which
-- drags around the ring and is taken by minimap skins and button collectors.
--
-- Left-click: a context menu (toggles, the compass's snooze, clearing); right-
-- click: the Options page. Its position and whether it's shown are LibDBIcon's
-- table, NodeRadarDB.minimap, made once at ADDON_LOADED (NodeRadar.lua) and
-- never replaced: LibDBIcon keeps a reference to it.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Button = {}            -- not "Minimap": that's the client's minimap frame
NR.Minimap = Button

local NAME = "NodeRadar"
Button.ICON = "Interface\\Icons\\INV_Misc_Flower_02"       -- the TOC's IconTexture: Find Herbs'
local registered = false

-- The durations offered, in the menu's order (Compass.SNOOZES' keys).
Button.DURATIONS = { { "15", "15 minutes" }, { "30", "30 minutes" }, { "60", "1 hour" }, { "session", "This session" } }

local function db() return NR.db.minimap end

function Button.Shown() return not db().hide end
function Button.Available() return registered end

-- Show or hide it to match the setting; LibDBIcon's own Show/Hide never touch
-- the saved table, so the choice is written here.
function Button.Apply()
    if not registered then return end
    db().hide = not NR.db.minimapButton
    local icon = rawget(_G, "LibStub")("LibDBIcon-1.0")
    if db().hide then icon:Hide(NAME) else icon:Show(NAME) end
end

local function durationText(key)
    for _, d in ipairs(Button.DURATIONS) do if d[1] == key then return d[2]:lower() end end
    return key
end

-- The context menu. The compass's node is captured as the menu opens: a
-- duration chosen later snoozes that one, even if the compass moved on
-- meanwhile (Codex). A checkbox closes the menu: on 70450 a refresh reruns
-- the entries but not this generator, so a menu left open would go stale.
local function generate(_, root)
    root:CreateTitle("NodeRadar")
    local function toggle(text, key)
        local box = root:CreateCheckbox(text, function() return NR.db[key] == true end, function()
            NR.Set(key, not NR.db[key])
            return MenuResponse.CloseAll
        end)
        box:SetResponse(MenuResponse.CloseAll)
    end
    toggle("Radar on", "enabled")
    toggle("Item icons on the minimap", "icons")
    toggle("The compass (experimental)", "compass")
    root:CreateDivider()
    local record, name, yards = NR.Compass.Target()
    if record then
        local snooze = root:CreateButton(("Snooze %s, %s yd"):format(name, yards or "?"))
        for _, d in ipairs(Button.DURATIONS) do
            snooze:CreateButton(d[2], function()
                NR.Compass.Snooze(d[1], record)
                return MenuResponse.CloseAll
            end)
        end
    else
        local why = NR.Compass.On() and "The compass has no node now" or "The compass is off"
        root:CreateButton(why):SetEnabled(false)
    end
    local n = NR.Compass.SnoozeCount()
    if n > 0 then
        root:CreateButton(("Clear snoozes (%d)"):format(n), function()
            NR.Compass.ClearSnoozes()
            return MenuResponse.CloseAll
        end)
    end
end

-- One click, from the minimap button (its frame first) or the compartment (the
-- addon's name first: Blizzard's AddonCompartment.lua), then the mouse button.
-- The menu's owner is the button only when it's that shown button; else nil,
-- the cursor (Codex).
function Button.Click(from, mouse)
    if mouse == "RightButton" then
        NR.Options.Open()
        return
    end
    local owner = type(from) == "table" and API.Yes(from.IsShown and from:IsShown()) and from or nil
    local ok, err = pcall(MenuUtil.CreateContextMenu, owner, generate)
    if not ok then API.Fail("menu", err) end
end

-- What it says on hover: the compass's node, the snoozes, the clicks.
local HINT = { 0.75, 0.78, 0.85 }
local function tooltip(tip, drag)
    tip:AddLine("NodeRadar")
    local record, name, yards = NR.Compass.Target()
    if record then
        tip:AddLine(("The compass: %s, %s yd"):format(name, yards or "?"), 1, 1, 1)
    elseif NR.Compass.On() then
        tip:AddLine("The compass has no node now", 0.6, 0.6, 0.6)
    end
    local n = NR.Compass.SnoozeCount()
    if n > 0 then tip:AddLine(("%d snoozed"):format(n), 0.8, 0.8, 0.8) end
    tip:AddLine("Left-click: quick settings, snooze the compass's node", HINT[1], HINT[2], HINT[3])
    tip:AddLine("Right-click: settings", HINT[1], HINT[2], HINT[3])
    if drag then tip:AddLine("Drag: move around the minimap", HINT[1], HINT[2], HINT[3]) end
end

-- The TOC's AddonCompartmentFunc*: globals, as the compartment looks them up by name.
NodeRadar_OnAddonCompartmentClick = Button.Click
function NodeRadar_OnAddonCompartmentEnter(_, row)
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    tooltip(GameTooltip, false)
    GameTooltip:Show()
end
function NodeRadar_OnAddonCompartmentLeave() GameTooltip:Hide() end

-- The key binding (Bindings.xml): its line in Key Bindings > NodeRadar is this
-- global; it snoozes the compass's node for the setting's duration.
BINDING_NAME_NODERADAR_SNOOZE = "Snooze the compass's node"
function Button.SnoozeKey()
    local key = NR.db.snoozeFor
    if not NR.Compass.SNOOZES[tostring(key)] then key = NR.DEFAULTS.snoozeFor end
    local r = NR.Compass.Snooze(key)
    if r then
        API.Say(("snoozed %s for %s"):format(r.name, durationText(key)))
    else
        API.Say("the compass has no node to snooze")
    end
end

local launcher = {
    type = "launcher",
    label = "NodeRadar",
    icon = Button.ICON,
    OnClick = Button.Click,
    OnTooltipShow = function(tip) tooltip(tip, true) end,
}

-- At PLAYER_LOGIN (NodeRadar.lua): no libraries, or the name taken, means no
-- button and nothing else breaks.
function Button.Register()
    if registered then return end
    local stub = rawget(_G, "LibStub")
    if type(stub) ~= "function" and type(stub) ~= "table" then return end
    local ok, ldb = pcall(stub, "LibDataBroker-1.1", true)
    local ok2, icon = pcall(stub, "LibDBIcon-1.0", true)
    if not (ok and ok2 and ldb and icon) then return end
    local obj = ldb:NewDataObject(NAME, launcher)
    if not obj then return end
    registered = pcall(icon.Register, icon, NAME, obj, db())
    Button.Apply()
end

Button._test = { launcher = launcher, generate = generate, tooltip = tooltip,
                 registered = function() return registered end }
