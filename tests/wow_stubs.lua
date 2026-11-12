-- wow_stubs.lua: NodeRadar's WoW: Forever mock for Lua 5.1 unit tests.
-- dofile("tests/wow_stubs.lua") FIRST in every test; drive it via the WoW table.
--
-- The mechanics are WowTestKit's core (tests/kit.lua loads the commit and the
-- build tests/kit.pin names): strict globals, secrets, events checked against
-- the build, widgets that record every method called, print with the
-- stray-"|" check, timers, fire / fireAllRegistered, check / eq / done. Its
-- README is the reference. This file adds the client APIs NodeRadar touches,
-- and replaces the core's methods where NodeRadar's tests rely on something
-- else (methods are looked up at call time).
--
-- THE MINIMAP'S MOUSEOVER: Minimap:UpdateMouseoverAtPoint(x, y) moves it and
-- C_TooltipInfo.GetMinimapMouseover() reads the blips there. Which
-- coordinates the client takes is what NodeRadarProbe measures (#2); here
-- it's WoW.mouseoverConvention, offsets from the map's centre by default.

dofile("tests/kit.lua")
local Methods = WoW.Methods
local newWidget = WoW.newWidget

-- What WoW.reset() clears besides the core's state.
local function resetNodeRadar()
    WoW.cvars = { rotateMinimap = "0" }
    WoW.tickers = {}
    WoW.now = 0
    WoW.build = "70450"     -- GetBuildInfo's build (#90: from 70862 the radar is blind)
end
table.insert(WoW.onReset, resetNodeRadar)
resetNodeRadar()

--------------------------------------------------------------------------------
-- Templates (CreateFrame's fourth argument)
--------------------------------------------------------------------------------

-- The radio template's own label (CheckButtonTemplates.xml: parentKey "text"),
-- a region as CreateFontString makes it.
WoW.templates.UIRadioButtonTemplate = function(w) w.text = WoW.addRegion(w, newWidget("FontString", w)) end

--------------------------------------------------------------------------------
-- Widgets: NodeRadar's own methods, and its versions of some of the core's
--------------------------------------------------------------------------------

-- A WowStyle1DropdownTemplate's menu (GuildSpy's stub): the generator, which
-- WoW.menu(dd) runs with a recording root; GenerateMenu counts refreshes.
-- DoesTemplateExist says no to WoW.missingTemplates[name].
WoW.missingTemplates = {}
function DoesTemplateExist(name) return not WoW.missingTemplates[name] end
function Methods.SetupMenu(w, fn) w._menu = fn end
function Methods.GenerateMenu(w) w._generated = (w._generated or 0) + 1 end
-- The menu's items: { label, selected = bool, pick = fn }.
function WoW.menu(dd)
    local items = {}
    dd._menu(dd, { CreateRadio = function(_, label, isSelected, onSelect)
        items[#items + 1] = { label = label, selected = isSelected() == true, pick = onSelect }
    end })
    return items
end

-- Check buttons: a click toggles the check, then runs OnClick (as the client).
function WoW.click(w)
    if w._type == "CheckButton" then w._checked = not w._checked end
    if w._scripts.OnClick then w._scripts.OnClick(w, "LeftButton") end
end

function Methods.GetSize(w) return w._width, w._height end
function Methods.GetEffectiveScale(w) return w._effScale or 1 end
function Methods.GetTop(w) return w._top end              -- nil until a test lays it out
function Methods.GetBottom(w) return w._bottom end
function Methods.SetScrollChild(sf, child) sf._scrollChild = child end
function Methods.SetRotation(t, radians) t._rotation = radians end
function Methods.SetScale(w, s) w._scale = s end
function Methods.GetScale(w) return w._scale or 1 end
-- Overrides of the core (test_styles, test_probe_glass and _bronze read the mask on the
-- texture: t._mask; the core keeps a list, t._masks).
function Methods.AddMaskTexture(t, m) t._mask = m end
-- The kit has GetChildren but not GetNumChildren (the scan's walks ask it first, the memory churn).
function Methods.GetNumChildren(w) return #(w._children or {}) end
function Methods.GetEffectiveAlpha(w) return (w._alpha or 1) * (w._parent and Methods.GetEffectiveAlpha(w._parent) or 1) end
function Methods.RegisterUnitEvent(w, e, ...)
    if not WoW.KNOWN_EVENTS[e] then error("Attempt to register unknown event \"" .. e .. "\"", 2) end
    w._events[e] = true
    return true
end
-- A mask is a region of its frame (GetRegions lists it; the core's CreateMaskTexture doesn't
-- add it, and test_probe_bronze finds it there).
function Methods.CreateMaskTexture(w, name)
    return WoW.addRegion(w, newWidget("MaskTexture", w, name))
end
function Methods.SetTexCoord(t, ...) t._texCoord = { ... } end
function Methods.IsDesaturated(t) return t._desaturated == true end
function Methods.GetTexture(t) return t._file end
-- WowTestKit: SetText as the core has it, and a GameTooltip's lines start over.
local coreSetText = Methods.SetText
function Methods.SetText(fs, text)
    coreSetText(fs, text)
    if fs._type == "GameTooltip" then fs._lines = {} end
end


--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

UIParent._width, UIParent._height = 1920, 1080          -- the screen, in UIParent's units (#57)

-- Moving a frame (#57): StartMoving marks it; StopMovingOrSizing leaves it where
-- the test dropped it (WoW.dropAt = { x, y }, a centre in UIParent's units) or
-- where it was. GetCenter: a frame's own centre if set, else its CENTER anchor's
-- frame's centre plus the offsets (UIParent's is the screen's middle), else nil.
WoW.altDown = false
function IsAltKeyDown() return WoW.altDown == true end
function Methods.SetMovable(w, v) w._movable = v end
function Methods.StartMoving(w) w._moving = true end
function Methods.StopMovingOrSizing(w)
    w._moving = false
    if WoW.dropAt then w._center = { WoW.dropAt[1], WoW.dropAt[2] }; WoW.dropAt = nil end
end
function Methods.GetCenter(w)
    if w == UIParent then return UIParent._width / 2, UIParent._height / 2 end
    if w._center then return w._center[1], w._center[2] end
    local p = w._points[#w._points]
    if p and p[1] == "CENTER" and type(p[2]) == "table" and (p[3] == nil or p[3] == "CENTER") then
        local cx, cy = Methods.GetCenter(p[2])
        if cx then return cx + (p[4] or 0), cy + (p[5] or 0) end
    end
end

-- The game's tooltip: its owner, and FrameXML's SetItemByID (#29), which shows it.
GameTooltip = newWidget("GameTooltip", UIParent, "GameTooltip")
GameTooltip._shown = false
function Methods.SetOwner(t, owner, anchor) t._owner, t._anchor = owner, anchor end
function Methods.GetOwner(t) return t._owner end
function Methods.SetItemByID(t, id) t._item = id; t._shown = true; return true end
-- Its lines (#47): SetText starts over, AddLine adds.
function Methods.AddLine(t, text) t._lines = t._lines or {}; table.insert(t._lines, text) end
-- TooltipDataProcessor (FrameXML, #62): post-calls by tooltip type.
-- WoW.buildMinimapTooltip(tooltip) is what Minimap_OnUpdate's SetMinimapMouseover
-- does (TooltipDataHandler.lua, 70450): read the data, clear, add its lines, run
-- the post-calls for its type, show; nothing when there's no data.
WoW.postCalls = {}
TooltipDataProcessor = {
    AllTypes = "ALL",
    AddTooltipPostCall = function(kind, func)
        assert(kind ~= nil and type(func) == "function", "AddTooltipPostCall takes a type and a function")
        WoW.postCalls[kind] = WoW.postCalls[kind] or {}
        table.insert(WoW.postCalls[kind], func)
    end,
}
function WoW.buildMinimapTooltip(tooltip)
    tooltip = tooltip or GameTooltip
    local data = C_TooltipInfo.GetMinimapMouseover()
    tooltip._lines = {}
    if not data then tooltip._shown = false; return nil end
    for _, line in ipairs(data.lines) do
        if not issecretvalue(line.leftText) then Methods.AddLine(tooltip, line.leftText) end
    end
    for _, func in ipairs(WoW.postCalls[data.type] or {}) do func(tooltip, data) end
    tooltip._shown = true
    return data
end
-- The compass test reads the fields as set: _motion, _click (the core keeps _motion and
-- _clicks, as booleans).
function Methods.SetMouseMotionEnabled(w, v) w._motion = v end
function Methods.SetMouseClickEnabled(w, v) w._click = v end
-- As the client: EnableMouse sets both motion and clicks; EnableMouseMotion is motion's other setter.
function Methods.EnableMouse(w, v) w._mouse, w._motion, w._click = v, v == true, v == true end
function Methods.EnableMouseMotion(w, v) w._motion = v end

SlashCmdList = {}
Enum = {}
-- In the dump's order (70450); the probe's logs read 0, 1 and 2.
Enum.NavigationState = { Invalid = 0, Occluded = 1, InRange = 2, Disabled = 3 }
date = os.date
-- The clock follows WoW.now, so a test that advances time also turns the
-- second (ForeverProbe takes a screenshot just after it changes).
function time(t) if t then return os.time(t) end return 1760000000 + math.floor(WoW.now) end
function GetServerTime() return time() end
function GetBuildInfo() return "1.60.1", WoW.build or "70450", "Oct 15 2026", 16001 end
function GetCVar(name) return WoW.cvars[name] end
function GetCVarBool(name) return WoW.cvars[name] == "1" end
function debugprofilestop() return os.clock() * 1000 end
-- The whole Lua state's memory stands in for one addon's.
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage() return collectgarbage("count") end

WoW.addonVersion = "dev"
C_AddOns = {
    GetAddOnMetadata = function(name, field) if field == "Version" then return WoW.addonVersion end end,
    IsAddOnLoaded = function(name)
        local on = WoW.loadedAddons ~= nil and WoW.loadedAddons[name] == true
        return on, on
    end,
}

-- The core's C_Timer.After and WoW.flushTimers(upTo) stand. Tickers are NodeRadar's
-- own (the core's doesn't repeat): WoW.drainTimers() runs the timers until none
-- is left, timers set by timers included.
-- C_Timer.NewTicker follows WoW.now: WoW.tick runs a ticker's callback each time
-- the clock passes its next due time, `iterations` times at most; Cancel stops it.
WoW.tickers = {}
function C_Timer.NewTicker(seconds, callback, iterations)
    local t = { every = seconds, at = WoW.now + seconds, cb = callback, left = iterations }
    function t.Cancel(self) self.cancelled = true end
    table.insert(WoW.tickers, t)
    return t
end
function WoW.drainTimers()
    for _ = 1, 1000 do
        if #WoW.timers == 0 then return end
        WoW.flushTimers()
    end
    error("timers never drained")
end

--------------------------------------------------------------------------------
-- The player, sounds, files
--------------------------------------------------------------------------------

-- The player: speed (WoW.speed), a cast (WoW.casting, a spell name), death,
-- a group, the locale.
WoW.speed, WoW.casting, WoW.dead, WoW.group, WoW.locale = 0, nil, false, false, "enUS"
function GetUnitSpeed(unit) return WoW.speed, 7, 7, 4.72 end
function UnitCastingInfo(unit) if unit == "player" and WoW.casting then return WoW.casting, WoW.casting end end
function UnitChannelInfo(unit) return nil end
function UnitIsDeadOrGhost(unit) return WoW.dead end
-- The player's world position (#28): WoW.pos = { north, west, instance } in
-- UnitPosition's frame, its first value north and its second west
-- (HereBeDragons-2.0); WoW.posSecret makes it secret; WoW.posZ its height (0 if nil).
WoW.pos = { 0, 0, 1 }
function UnitPosition(unit)
    if unit ~= "player" or not WoW.pos then return nil end
    if WoW.posSecret then return WoW.Secret("north"), WoW.Secret("west"), 0, WoW.pos[3] end
    return WoW.pos[1], WoW.pos[2], WoW.posZ or 0, WoW.pos[3]
end
function IsInGroup() return WoW.group end
-- A raid (WoW.raid), and the other units of a group (WoW.units[unit] = { name, realm,
-- full }): UnitName splits a surname-bearing name as the client does, GetUnitName(unit,
-- false) is the full name.
WoW.raid, WoW.units = false, {}
function IsInRaid() return WoW.raid == true end
function GetUnitName(unit, showServer)
    local u = WoW.units[unit]
    return u and (u.full or u.name) or nil
end
-- Addon messages (C_ChatInfo): every send recorded in WoW.sent as { prefix, text,
-- chatType, target }; WoW.sendResult[chatType] (a number, or a function of the text; default 0,
-- success) is what it returns,
-- WoW.lockdown what InChatMessagingLockdown says, WoW.prefixes the registered ones.
WoW.sent, WoW.sendResult, WoW.lockdown, WoW.prefixes = {}, {}, false, {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix) WoW.prefixes[prefix] = true; return 0 end,
    IsAddonMessagePrefixRegistered = function(prefix) return WoW.prefixes[prefix] == true end,
    InChatMessagingLockdown = function() return WoW.lockdown end,
    SendAddonMessage = function(prefix, text, chatType, target)
        table.insert(WoW.sent, { prefix = prefix, text = text, chatType = chatType, target = target })
        local r = WoW.sendResult[chatType]
        if type(r) == "function" then r = r(text) end
        return r or 0
    end,
}
function GetLocale() return WoW.locale end

-- Spells: names by ID (C_Spell.GetSpellInfo); WoW.cooling[id] puts one on cooldown.
WoW.spellNames = { [2366] = "Herb Gathering", [2368] = "Herb Gathering", [2575] = "Mining", [2576] = "Mining",
                   [2383] = "Find Herbs", [2580] = "Find Minerals" }
WoW.cooling = {}
C_Spell = {
    GetSpellTexture = function(id) if WoW.spellNames[id] then return 136000 + id, 136000 + id end end,
    GetSpellInfo = function(id)
        local n = WoW.spellNames[id]
        if n then return { name = n, spellID = id, iconID = 1, originalIconID = 1, castTime = 0, minRange = 0, maxRange = 0 } end
    end,
    -- WoW.spellCooldowns[id] gives a spell's whole answer (Cultivation's, #26),
    -- else WoW.cooling[id] puts it on the global cooldown.
    GetSpellCooldown = function(id)
        if WoW.spellCooldowns[id] ~= nil then
            local cd = WoW.spellCooldowns[id]
            if cd == "throw" then error("GetSpellCooldown failed") end
            return cd
        end
        local on = WoW.cooling[id] == true
        return { startTime = on and 1 or 0, duration = on and 1.5 or 0, isEnabled = true, isActive = on, modRate = 1,
                 isOnGCD = on }
    end,
}
WoW.spellCooldowns = {}

-- Gathering skills (#26): WoW.skillLines[id] is GetSkillLineInfoByID's answer
-- (nil without the profession; "throw" throws). Spells known: WoW.knownSpells.
WoW.skillLines = {}
C_SkillInfo = {
    GetSkillLineInfoByID = function(id)
        if WoW.skillLines[id] == "throw" then error("GetSkillLineInfoByID failed") end
        return WoW.skillLines[id]
    end,
}
WoW.knownSpells = {}
C_SpellBook = { IsSpellKnown = function(id) return WoW.knownSpells[id] == true end }

-- The player on the zone map (#27): WoW.map (a uiMapID, or nil), WoW.mapPos
-- (0-1, y down), WoW.mapSize (yards); the facing (radians, 0 north,
-- counter-clockwise; nil in an instance); indoors.
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 1000, 1000 }
WoW.facing, WoW.indoors = 0, false
C_Map = {
    GetBestMapForUnit = function(unit) return WoW.map end,
    GetPlayerMapPosition = function(map, unit)
        assert(type(map) == "number" and unit ~= nil, "GetPlayerMapPosition takes (uiMapID, unitToken)")
        if map ~= WoW.map or not WoW.mapPos then return nil end
        local x, y = WoW.mapPos.x, WoW.mapPos.y
        return { x = x, y = y, GetXY = function() return x, y end }
    end,
    GetMapWorldSize = function(map) return WoW.mapSize[1], WoW.mapSize[2] end,
}
function GetPlayerFacing() return WoW.facing end
-- Blizzard's on-screen marker (Blizzard_QuestNavigation, FrameXML's): its OnUpdate
-- calls UpdateAlpha every frame; here it just sets the alpha it wants (1).
SuperTrackedFrame = WoW.newWidget("Frame", nil, "SuperTrackedFrame")
SuperTrackedFrame.Icon = SuperTrackedFrame:CreateTexture()          -- the diamond (its parentKey)
function SuperTrackedFrame:UpdateAlpha() self:SetAlpha(1) end
-- The world map (FrameXML's, not in the dump): WoW.worldMapShown.
WorldMapFrame = { IsShown = function() return WoW.worldMapShown == true end }
function UnitOnTaxi(unit) return unit == "player" and WoW.onTaxi == true end
function IsIndoors() return WoW.indoors == true end
WoW.instanced = false
function IsInInstance()
    if WoW.instanced == "throw" then error("IsInInstance failed") end
    return WoW.instanced, WoW.instanced == true and "party" or "none"
end
-- A set fires CVAR_UPDATE (name, value) at once; its timing in the client isn't measured.
C_CVar = { GetCVar = function(name) return WoW.cvars[name] end,
           SetCVar = function(name, value)
               WoW.cvars[name] = value
               WoW.fire("CVAR_UPDATE", name, value)
               return true
           end }

-- The user waypoint and the super-track (#29): WoW.waypoint ({ map, x, y } or
-- nil), WoW.superTracked ("waypoint", "quest" or nil); the navigation frame
-- exists while the waypoint is super-tracked (NAVIGATION_FRAME_CREATED when it
-- starts, _DESTROYED when it stops, as SuperTrackedFrame expects); WoW.navClamped,
-- WoW.navDistance.
-- Setting or clearing fires USER_WAYPOINT_UPDATED / SUPER_TRACKING_CHANGED at
-- once (the first is SynchronousEvent; the second's timing isn't documented).
WoW.waypoint, WoW.superTracked, WoW.navClamped, WoW.navDistance = nil, nil, false, 50
UiMapPoint = {
    CreateFromCoordinates = function(map, x, y, z)
        return { uiMapID = map, position = { x = x, y = y }, z = z }
    end,
}
C_Map.HasUserWaypoint = function() return WoW.waypoint ~= nil end
-- A world position (north, west, as UnitPosition) on the player's zone map, as
-- the player's own spot and the map's size in yards place it.
C_Map.GetMapPosFromWorldPos = function(continent, pos, map)
    local x = WoW.mapPos.x + (WoW.pos[2] - pos.y) / WoW.mapSize[1]
    local y = WoW.mapPos.y - (pos.x - WoW.pos[1]) / WoW.mapSize[2]
    return map or WoW.map, { x = x, y = y }
end
-- FrameXML's (not in the dump).
function CreateVector2D(x, y) return { x = x, y = y } end
C_Map.CanSetUserWaypointOnMap = function(map) return map == WoW.map end
C_Map.GetUserWaypoint = function()
    local w = WoW.waypoint
    if w then return { uiMapID = w.map, position = { x = w.x, y = w.y }, z = w.z } end
end
C_Map.SetUserWaypoint = function(point)
    if not (point and point.uiMapID == WoW.map) then return false end
    WoW.waypoint = { map = point.uiMapID, x = point.position.x, y = point.position.y, z = point.z }
    WoW.fire("USER_WAYPOINT_UPDATED")
    return true
end
-- Clearing the waypoint leaves its super-track on, as measured (FOREVER-PROBE.md).
C_Map.ClearUserWaypoint = function()
    WoW.waypoint = nil
    WoW.fire("USER_WAYPOINT_UPDATED")
end
function WoW.SetSuperTracked(what)
    local was = WoW.superTracked == "waypoint"
    WoW.superTracked = what
    local now = what == "waypoint"
    if now and not was then
        WoW.navFrame = WoW.navFrame or CreateFrame("Frame")
        WoW.fire("NAVIGATION_FRAME_CREATED")
    elseif was and not now then
        WoW.fire("NAVIGATION_FRAME_DESTROYED")
    end
    WoW.fire("SUPER_TRACKING_CHANGED")
end
C_SuperTrack = {
    SetSuperTrackedUserWaypoint = function(on)
        if on and WoW.waypoint then WoW.SetSuperTracked("waypoint")
        elseif not on and WoW.superTracked == "waypoint" then WoW.SetSuperTracked(nil)
        else WoW.fire("SUPER_TRACKING_CHANGED") end
    end,
    IsSuperTrackingAnything = function() return WoW.superTracked ~= nil end,
    IsSuperTrackingUserWaypoint = function() return WoW.superTracked == "waypoint" end,
    IsSuperTrackingQuest = function() return WoW.superTracked == "quest" end,
    IsSuperTrackingCorpse = function() return WoW.superTracked == "corpse" end,
    IsSuperTrackingContent = function() return false end,
    IsSuperTrackingMapPin = function() return false end,
    GetSuperTrackedVignette = function() return nil end,
    GetSuperTrackedQuestID = function() return WoW.superTracked == "quest" and 783 or nil end,
}
-- Items (#28): WoW.itemCached[id] says which are cached; GetItemIconByID
-- answers only those (a model: what the client does is the probe's question),
-- GetItemInfoInstant every one. A name (#47) answers once cached, from
-- WoW.itemNames or "Item <id>"; RequestLoadItemDataByID records the asks.
WoW.itemCached = {}
WoW.itemNames = {}
WoW.itemRequests = {}
C_Item = {
    IsItemDataCachedByID = function(id) return WoW.itemCached[id] == true end,
    GetItemIconByID = function(id) if WoW.itemCached[id] then return 130000 + id end end,
    GetItemNameByID = function(id) if WoW.itemCached[id] then return WoW.itemNames[id] or ("Item " .. id) end end,
    RequestLoadItemDataByID = function(id) table.insert(WoW.itemRequests, id) end,
    GetItemInfoInstant = function(id) return id, "Trade Goods", "Herb", "", 130000 + id, 7, 9 end,
}
C_Navigation = {
    GetFrame = function() return WoW.superTracked == "waypoint" and WoW.navFrame or nil end,
    HasValidScreenPosition = function() return WoW.superTracked == "waypoint" end,
    GetDistance = function() return WoW.navDistance end,
    WasClampedToScreen = function() return WoW.navClamped == true end,
    GetTargetState = function() return WoW.navState or 0 end,
}

-- Nameplates (#78): WoW.plates = { { unit = "nameplate1", name, object = true,
-- soft = true (the soft-interact target), alpha }, ... }; each a plate frame
-- with namePlateUnitToken and a UnitFrame, kept by unit.
WoW.plates = {}
local plateFrames = {}
local function plateOf(unit)
    for _, p in ipairs(WoW.plates) do
        if p.unit == unit or (unit == "softinteract" and p.soft) then return p end
    end
end
local function plateFrame(p)
    local f = plateFrames[p.unit]
    if not f then
        f = newWidget("Frame", nil)
        f.namePlateUnitToken = p.unit
        f.UnitFrame = newWidget("Frame", f)
        f.UnitFrame.unit = p.unit
        f._width, f._height = 110, 45
        plateFrames[p.unit] = f
    end
    f._alpha = p.alpha or 1
    return f
end
C_NamePlate = {
    GetNamePlates = function()
        local out = {}
        for _, p in ipairs(WoW.plates) do out[#out + 1] = plateFrame(p) end
        return out
    end,
    GetNamePlateForUnit = function(unit) local p = plateOf(unit); return p and plateFrame(p) or nil end,
}
function UnitIsGameObject(unit) local p = plateOf(unit); return p ~= nil and p.object == true end
function UnitName(unit)
    local u = WoW.units[unit]
    if u then return u.name, u.realm end
    local p = plateOf(unit); if p then return p.name end
end
function UnitExists(unit) return WoW.units[unit] ~= nil or plateOf(unit) ~= nil end
function UnitIsUnit(a, b)
    local pa, pb = plateOf(a), plateOf(b)
    return pa ~= nil and pa == pb
end

WoW.mounted = false
function IsMounted() return WoW.mounted end
-- The cursor busy (#113): a spell aimed (WoW.targeting), something held (WoW.cursorInfo = "item"),
-- a loot window's items (WoW.lootItems).
WoW.targeting, WoW.cursorInfo, WoW.lootItems = false, nil, 0
function SpellIsTargeting() return WoW.targeting end
function GetCursorInfo() return WoW.cursorInfo end
function GetNumLootItems() return WoW.lootItems end
WoW.sounds = {}
-- willPlay for vanilla kits; WoW.refusedSounds[kit] refuses one (newer kits are, on Forever).
WoW.refusedSounds = {}
function PlaySound(kit, channel)
    table.insert(WoW.sounds, { kit, channel })
    if WoW.refusedSounds[kit] then return false, nil end
    return true, #WoW.sounds
end
-- An addon's own file plays when it's there (the porting guide: PlaySoundFile
-- refuses game-file paths, plays an addon's); here "there" is the repo's copy.
function PlaySoundFile(path, channel)
    table.insert(WoW.sounds, { path, channel })
    -- A FileDataID: plays unless refused (WoW.refusedSounds[id]).
    if type(path) == "number" then
        if WoW.refusedSounds[path] then return nil, nil end
        return true, #WoW.sounds
    end
    local rel = type(path) == "string" and path:match("^Interface\\AddOns\\NodeRadar\\(.+)$")
    local f = rel and io.open((rel:gsub("\\", "/")), "rb")
    if not f or WoW.refusedSounds[path] then return nil, nil end
    f:close()
    return true, #WoW.sounds
end

-- The Settings framework (Blizzard_Settings): canvas categories, recorded.
WoW.categories = {}
-- The minimap button's libraries (#46): the vendored Libs\ aren't loaded in
-- tests (GuildSpy's recipe); LibStub answers LibDataBroker-1.1 and LibDBIcon-1.0
-- with recording fakes, anything else with nil. A test can still set its own
-- LibStub (the LibGlass fakes). WoW.noLibs: as if the libraries were missing.
function WoW.newLDB()
    local lib = { objects = {} }
    function lib:NewDataObject(name, obj)
        if self.objects[name] then return nil end            -- the name taken: nil, as the real one
        self.objects[name] = obj
        return obj
    end
    return lib
end
function WoW.newLDBI()
    local lib = { registered = {}, buttons = {} }
    function lib:Register(name, obj, db)
        local b = newWidget("Button", Minimap, "LibDBIcon10_" .. name)
        b._scripts.OnClick = function(self, mouse) obj.OnClick(self, mouse) end
        b.dataObject, b.db = obj, db
        if db.hide then b._shown = false end
        self.registered[name], self.buttons[name] = db, b
    end
    -- As the real one (minor 56): Show/Hide only show or hide the button, never the saved table.
    function lib:Show(name) self.buttons[name]:Show() end
    function lib:Hide(name) self.buttons[name]:Hide() end
    function lib:GetMinimapButton(name) return self.buttons[name] end
    return lib
end
function LibStub(major)
    if WoW.noLibs then return nil end
    if major == "LibDataBroker-1.1" then WoW.ldb = WoW.ldb or WoW.newLDB(); return WoW.ldb end
    if major == "LibDBIcon-1.0" then WoW.ldbi = WoW.ldbi or WoW.newLDBI(); return WoW.ldbi end
end

-- Blizzard_Menu's context menus (#46): CreateContextMenu runs the generator on
-- a recording description; WoW.menu = { owner, root }. Each element: kind,
-- text, its callbacks, enabled, response, children (a submenu).
MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
local function newDesc(kind, text)
    local d = { kind = kind, text = text, children = {}, enabled = true }
    function d:CreateTitle(t) local e = newDesc("title", t); table.insert(self.children, e); return e end
    function d:CreateDivider() local e = newDesc("divider"); table.insert(self.children, e); return e end
    function d:CreateButton(t, callback, data)
        local e = newDesc("button", t)
        e.callback, e.data = callback, data
        table.insert(self.children, e)
        return e
    end
    function d:CreateCheckbox(t, isSelected, setSelected, data)
        local e = newDesc("checkbox", t)
        e.isSelected, e.setSelected, e.data = isSelected, setSelected, data
        table.insert(self.children, e)
        return e
    end
    function d:SetEnabled(v) self.enabled = v end
    function d:SetResponse(r) self.response = r end
    return d
end
MenuUtil = {
    CreateContextMenu = function(owner, generator, ...)
        local root = newDesc("root")
        generator(owner, root, ...)
        WoW.menu = { owner = owner, root = root }
        return root
    end,
}
-- The element whose text matches `pattern` (plain), searched through submenus.
function WoW.menuItem(pattern, from)
    from = from or (WoW.menu and WoW.menu.root)
    if not from then return nil end
    for _, e in ipairs(from.children) do
        if e.text and e.text:find(pattern, 1, true) then return e end
        local inner = WoW.menuItem(pattern, e)
        if inner then return inner end
    end
end

Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        local c = { frame = frame, name = name, id = #WoW.categories + 1 }
        function c:GetID() return self.id end
        table.insert(WoW.categories, c)
        return c
    end,
    RegisterAddOnCategory = function(c) c.registered = true end,
    -- A sub-page (#47): recorded in order, under its parent.
    RegisterCanvasLayoutSubcategory = function(parent, frame, name)
        local c = { frame = frame, name = name, parent = parent, id = #WoW.categories + 1 }
        function c:GetID() return self.id end
        table.insert(WoW.categories, c)
        return c
    end,
    OpenToCategory = function(id) WoW.openedCategory = id end,
}

function GetFileIDFromPath(path) return WoW.files and WoW.files[path] or nil end

--------------------------------------------------------------------------------
-- The minimap: 198x198 at (800, 500) in its own units, effective scale 1.2
-- (its units times 1.2 are screen pixels). The cursor is in pixels:
-- WoW.cursor = { x, y }; WoW.cursorOnMap says whether it's over the map.
-- Blips: WoW.blips = { { name, dx, dy } }, offsets from the map's centre in
-- its units. The mouseover reads every blip within 6 units of:
-- - the last point UpdateMouseoverAtPoint got (as WoW.mouseoverConvention(x, y)
--   turns it into a centre offset), but only while the cursor is on the map
--   (round 1, 70450) or the soft cursor is on (SetUsingSoftCursor; what round 2
--   measures; WoW.softIgnored makes it do nothing);
-- - else the cursor, while it's on the map.
-- WoW.mouseoverStuck makes UpdateMouseoverAtPoint do nothing.
--------------------------------------------------------------------------------

Minimap = CreateFrame("Frame", "Minimap", UIParent)
Minimap._type = "Minimap"   -- the dump's widget walk lists its methods as Minimap:<method>
Minimap._rect = { 800, 500, 198, 198 }
Minimap._effScale = 1.2
Minimap._zoom = 0
function Methods.GetRect(w)
    local r = w._rect
    if r then return r[1], r[2], r[3], r[4] end
end
function Methods.GetZoom(w) return w._zoom or 0 end
-- The zoom set; the client's MINIMAP_UPDATE_ZOOM is the test's to fire.
function Methods.SetZoom(w, z) w._zoom = z end
-- WoW.mouseOver: another frame under the cursor (#28's icons).
function Methods.IsMouseOver(w) return (w == Minimap and WoW.cursorOnMap == true) or (w == WoW.mouseOver) end
function Methods.UpdateMouseoverAtPoint(w, x, y)
    assert(type(x) == "number" and type(y) == "number", "UpdateMouseoverAtPoint takes two numbers")
    WoW.reads = WoW.reads + 1                      -- every point the mouseover is moved to
    if WoW.mouseoverStuck then return end
    WoW.mouseoverPoint = { x, y }
end
function Methods.SetUsingSoftCursor(w, on)
    assert(type(on) == "boolean", "SetUsingSoftCursor takes a bool")
    WoW.softCursor = on
end
-- The ping: recorded, then MINIMAP_PING (unitTarget, y, x), as documented.
WoW.pings = {}
function Methods.PingLocation(w, x, y)
    assert(type(x) == "number" and type(y) == "number", "PingLocation takes two numbers")
    table.insert(WoW.pings, { x, y })
    WoW.pingAt = { x, y }
    WoW.fire("MINIMAP_PING", "player", y, x)
end
function Methods.GetPingPosition(w)
    local p = WoW.pingAt or { 0, 0 }
    return p[1], p[2]
end

WoW.reads = 0
WoW.cursor = { 0, 0 }
WoW.cursorOnMap = false
WoW.blips = {}
-- Round 2 (70450): the point is in GetCursorPosition's space, screen pixels.
WoW.mouseoverConvention = function(x, y)
    local r, s = Minimap._rect, Minimap._effScale
    return x / s - (r[1] + r[3] / 2), y / s - (r[2] + r[4] / 2)
end
function GetCursorPosition() return WoW.cursor[1], WoW.cursor[2] end

-- A blip's pixels, as the cursor would be on it.
function WoW.blipPixels(dx, dy)
    local r, s = Minimap._rect, Minimap._effScale
    return (r[1] + r[3] / 2 + dx) * s, (r[2] + r[4] / 2 + dy) * s
end

-- The real cursor resting on the map (a blip or not): the client's own
-- mouseover follows it.
function WoW.hover(dx, dy)
    WoW.cursor = { WoW.blipPixels(dx, dy) }
    WoW.cursorOnMap = true
    WoW.mouseoverPoint, WoW.cursorAt = nil, { dx, dy }
end

-- The cursor leaves the map, onto the game world.
function WoW.leaveMap()
    WoW.cursor = { 10, 10 }
    WoW.cursorOnMap, WoW.cursorAt = false, nil
end

-- A blip's optional kind ("herbs", "ore") shows it only while that tracking
-- is on; its optional colour is its line's leftColor ({ r, g, b }).
local TRACKING_KIND = { [2383] = "herbs", [2580] = "ore" }
local function kindOn(kind)
    for _, t in ipairs(WoW.tracking) do
        if t.spellID and TRACKING_KIND[t.spellID] == kind and t.active then return true end
    end
    return false
end

-- A blip's hit area: a square, 17 units wide (a herb's narrowest, #11); a
-- blip's own `half` makes it larger (a quest's objective area), `disc` round.
WoW.BLIP_HALF = 8.5
local function inside(b, dx, dy)
    local half, x, y = b.half or WoW.BLIP_HALF, b[2] - dx, b[3] - dy
    if b.disc then return x * x + y * y <= half * half end
    return math.abs(x) <= half and math.abs(y) <= half
end
WoW.kindOn = kindOn
local function blipsAt(dx, dy)
    local lines = {}
    for _, b in ipairs(WoW.blips) do
        if inside(b, dx, dy)
            and (not b.kind or kindOn(b.kind)) then
            local c = b.colour or { 1, 1, 1 }
            local text = WoW.secretNames and WoW.Secret("name") or b.text or b[1]
            lines[#lines + 1] = { leftText = text, type = 0, leftColor = { r = c[1], g = c[2], b = c[3], a = 1 } }
        end
    end
    return lines
end

C_TooltipInfo = {
    -- MayReturnNothing (TooltipInfoDocumentation.lua:619). WoW.mouseoverThrows
    -- makes every read throw.
    GetMinimapMouseover = function()
        if WoW.mouseoverThrows then error("GetMinimapMouseover failed") end
        if WoW.moveModel then return WoW.moveRead() end
        local dx, dy
        local pointCounts = WoW.cursorOnMap or (WoW.softCursor and not WoW.softIgnored)
        if WoW.mouseoverPoint and pointCounts then
            dx, dy = WoW.mouseoverConvention(WoW.mouseoverPoint[1], WoW.mouseoverPoint[2])
        elseif WoW.cursorAt then
            dx, dy = WoW.cursorAt[1], WoW.cursorAt[2]
        else
            return nil
        end
        local lines = blipsAt(dx, dy)
        if #lines == 0 then return nil end
        return { type = 21, lines = lines }
    end,
}

--------------------------------------------------------------------------------
-- The minimap scan's world (#91, 70862): the mouseover follows only the real cursor.
-- With WoW.moveModel on:
-- - Minimap sits at its home point (CENTER on MinimapCluster.MinimapContainer, _rect)
--   until a point CENTER on UIParent's BOTTOMLEFT places its centre there, at its size;
-- - GetMouseFoci: {} while mouselooking (measured), { Minimap } with the cursor in its rect,
--   it visible and its mouse motion on, else { WoW.focus }, or over the world {} (the stock UI,
--   WorldFrame's mouse off, measured on 70888; WoW.worldFocus = true gives { WorldFrame });
-- - a read, only with Minimap the top focus: the player (WoW.playerName) and every blip
--   whose hit square (WoW.HIT_PX screen px, measured 16) holds the cursor, a blip's offset
--   in a 198-unit map's units scaled to the map's width; empty lines (unsettled) the frame
--   after a placement that followed a resize (measured), and until UpdateBlips after a
--   placement (stale, measured).
--------------------------------------------------------------------------------

WorldFrame = newWidget("Frame", nil, "WorldFrame")
MinimapCluster = CreateFrame("Frame", "MinimapCluster", UIParent)
MinimapCluster.MinimapContainer = CreateFrame("Frame", nil, MinimapCluster)
MinimapCluster.MinimapContainer.PlayerCoords = CreateFrame("Frame", nil, MinimapCluster.MinimapContainer)
MinimapCluster.MinimapContainer.PlayerCoords:SetPoint("TOP", Minimap, "BOTTOM", 0, -4)
QueueStatusButton = CreateFrame("Button", "QueueStatusButton", UIParent)
QueueStatusButton:SetPoint("BOTTOMLEFT", Minimap, "BOTTOMLEFT", -10, -10)
QueueStatusButton:EnableMouse(true)
QueueStatusButton:Hide()
Minimap:SetPoint("CENTER", MinimapCluster.MinimapContainer, "CENTER", 0, 0)
Minimap:SetSize(198, 198)
Minimap:SetFrameStrata("LOW")
Minimap:SetFrameLevel(3)
WoW.HIT_PX = 16
WoW.playerName = "Elegia"
WoW.frameCount = 0

function Methods.GetNumPoints(w) return #w._points end
function Methods.IsProtected(w) return w._protected == true end
function Methods.SetClampedToScreen(w, on) w._clamp = on == true end
function Methods.IsClampedToScreen(w) return w._clamp == true end
function Methods.IsMouseClickEnabled(w) return w._click ~= false end
function Methods.IsMouseMotionEnabled(w) return w._motion ~= false end
function Methods.EnableMouseWheel(w, on) w._wheel = on == true end
function Methods.IsMouseWheelEnabled(w) return w._wheel ~= false end
function Methods.SetIconScale(w, v) w._iconScale = v end
function Methods.UpdateBlips(w) w._blipsStale = false; WoW.updateBlips = (WoW.updateBlips or 0) + 1 end

local homeRect = Methods.GetRect
local function placed(w)
    local p = w._points[#w._points]
    if w == Minimap and p and p[1] == "CENTER" and p[2] == UIParent and p[3] == "BOTTOMLEFT" then return p[4], p[5] end
end
function Methods.GetRect(w)
    local x, y = placed(w)
    if x then return x - w._width / 2, y - w._height / 2, w._width, w._height end
    return homeRect(w)
end
local centre = Methods.GetCenter
function Methods.GetCenter(w)
    if w == Minimap then
        local l, b, wd, h = Methods.GetRect(w)
        if l then return l + wd / 2, b + h / 2 end
    end
    return centre(w)
end
local setSize, setPoint = Methods.SetSize, Methods.SetPoint
function Methods.SetSize(w, x, y)
    if w == Minimap and (x ~= w._width or y ~= w._height) then w._resized = true end
    return setSize(w, x, y)
end
function Methods.SetPoint(w, ...)
    setPoint(w, ...)
    if w == Minimap then
        if w._resized then w._unsettledUntil, w._resized = WoW.frameCount + 1, false end
        w._blipsStale = true
    end
end

function GetMouseFoci()
    if WoW.mouselook then return {} end
    if WoW.moveModel and Methods.IsVisible(Minimap) and Minimap._motion ~= false then
        local x, y = GetCursorPosition()
        local s = Minimap._effScale
        local l, b, w, h = Methods.GetRect(Minimap)
        if l and x / s >= l and x / s <= l + w and y / s >= b and y / s <= b + h then return { Minimap } end
    end
    if WoW.focus then return { WoW.focus } end
    return WoW.worldFocus and { WorldFrame } or {}
end
function IsMouseButtonDown() return WoW.buttonDown == true end
function IsMouselooking() return WoW.mouselook == true end
-- The client's frame rate (the scan's burst line, #91): WoW.fps, else 60.
function GetFramerate() return WoW.fps or 60 end
function UnitAffectingCombat(unit) return unit == "player" and WoW.combat == true end

-- What the moved map lists under the real cursor.
function WoW.moveRead()
    if GetMouseFoci()[1] ~= Minimap then return nil end
    if WoW.frameCount <= (Minimap._unsettledUntil or -1) or Minimap._blipsStale then return { type = 21, lines = {} } end
    local l, b, w, h = Methods.GetRect(Minimap)
    local s, half = Minimap._effScale, WoW.HIT_PX / 2
    local x, y = GetCursorPosition()
    local cx, cy = (l + w / 2) * s, (b + h / 2) * s
    local lines = {}
    if math.abs(x - cx) <= half and math.abs(y - cy) <= half then
        lines[#lines + 1] = { leftText = WoW.playerName, type = 0 }
    end
    local k = w / 198
    for _, bl in ipairs(WoW.blips) do
        local bx, by = cx + bl[2] * k * s, cy + bl[3] * k * s
        if math.abs(x - bx) <= half and math.abs(y - by) <= half and (not bl.kind or WoW.kindOn(bl.kind)) then
            lines[#lines + 1] = { leftText = WoW.secretNames and WoW.Secret("name") or bl.text or bl[1], type = 0 }
        end
    end
    -- The minimap hovered with nothing under the cursor: a valid answer with no lines (in
    -- game, a locate window away from the player's arrow; #91).
    return { type = 21, lines = lines }
end

-- Blizzard's Lua methods and frames the scan uses (not in the dump's widget walk).
GameTooltip.SetMinimapMouseover = function(self) return WoW.buildMinimapTooltip(self) end
WoW.registry = {}
EventRegistry = {
    RegisterCallback = function(self, name, fn, owner)
        WoW.registry[name] = WoW.registry[name] or {}
        table.insert(WoW.registry[name], fn)
    end,
}
function WoW.fireRegistry(name, ...)
    for _, fn in ipairs(WoW.registry[name] or {}) do fn(nil, ...) end
end
EditModeManagerFrame = CreateFrame("Frame", "EditModeManagerFrame", UIParent)
EditModeManagerFrame.IsEditModeActive = function() return WoW.editMode == true end

-- Tracking: WoW.tracking = { { name, spellID, active } }.
WoW.tracking = {
    { name = "Find Herbs", spellID = 2383, active = false },
    { name = "Auctioneer", active = false },
}
C_Minimap = {
    GetNumTrackingTypes = function() return #WoW.tracking end,
    GetTrackingInfo = function(i)
        local t = WoW.tracking[i]
        if t then return { name = t.name, texture = 136025, active = t.active, type = "spell", subType = -1,
                           spellID = t.spellID } end
    end,
    -- WoW.viewRadius[zoom] when given (#27), else 150 yards.
    GetViewRadius = function() return WoW.viewRadius and WoW.viewRadius[Minimap._zoom or 0] or 150 end,
    IsRotateMinimapIgnored = function() return WoW.rotateIgnored == true end,
    -- A tracking's filter (70862's dump; #91 turns the quest areas, QuestPOIs = 65536, off
    -- during a scan): { filterID } from the entry's own filterID.
    GetTrackingFilter = function(i)
        local t = WoW.tracking[i]
        if t then return { filterID = t.filterID, spellID = t.spellID } end
    end,
    -- WoW.refuseTrackingOn / Off: turning a tracking on / off does nothing (a cast the
    -- client refuses). Either way MINIMAP_UPDATE_TRACKING fires.
    SetTracking = function(i, on)
        assert(type(on) == "boolean", "SetTracking takes a bool")
        local t = WoW.tracking[i]
        if t and not (on and WoW.refuseTrackingOn) and not (not on and WoW.refuseTrackingOff) then t.active = on end
        -- WoW.trackingGCD: turning a tracking on (a cast) starts a 1.5 s global cooldown.
        if on and WoW.trackingGCD then WoW.gcdUntil = WoW.now + 1.5 end
        WoW.fire("MINIMAP_UPDATE_TRACKING")
    end,
}

-- The global cooldown, as the action bar shows it: slots 1-3 hold spells.
local function onGCD() return WoW.gcdUntil ~= nil and WoW.now < WoW.gcdUntil end
C_ActionBar = {
    GetActionCooldown = function(slot)
        local on = slot <= 3 and onGCD()
        return { startTime = on and 1 or 0, duration = on and 1.5 or 0, isEnabled = true, isActive = on, modRate = 1 }
    end,
}
WoW.onGCD = onGCD

-- The Gamepad UI option (InputUtil, Blizzard_SharedXML): WoW.gamepadUI. The
-- GamePadEnable CVar is something else, on by default.
WoW.gamepadUI = false
InputUtil = { IsGamepadUIEnabled = function() return WoW.gamepadUI == true end }
function IsGamePadCursorControlEnabled() return WoW.gamepadCursor == true end

-- The client's secure hook: the original runs, then the hook, with the same arguments.
-- The closest game object of an ID: WoW.closest[id] = { x, y, distance }, or
-- secrets when WoW.closestSecret (documented SecretReturns).
WoW.closest = {}
function ClosestGameObjectPosition(id)
    local c = WoW.closest[id]
    if not c then return end
    if WoW.closestSecret then return WoW.Secret("x"), WoW.Secret("y"), WoW.Secret("distance") end
    return c[1], c[2], c[3]
end

-- A game object's GUID, as the client shapes it.
function WoW.objectGUID(id, spawn) return ("GameObject-0-4170-0-12-%d-%s"):format(id, spawn or "0000ABCDEF") end

-- Vignettes: WoW.vignettes = { [guid] = info }.
WoW.vignettes = {}
C_VignetteInfo = {
    GetVignettes = function()
        local list = {}
        for guid in pairs(WoW.vignettes) do list[#list + 1] = guid end
        return list
    end,
    GetVignetteInfo = function(guid) return WoW.vignettes[guid] end,
}

--------------------------------------------------------------------------------
-- Driving
--------------------------------------------------------------------------------
-- One rendered frame: OnUpdate on every visible frame.
function WoW.tick(elapsed)
    elapsed = elapsed or 0.02
    WoW.frameCount = (WoW.frameCount or 0) + 1
    local list = {}
    for _, w in ipairs(WoW.frames) do list[#list + 1] = w end
    for _, w in ipairs(list) do
        local fn = w._scripts.OnUpdate
        if fn and Methods.IsVisible(w) then fn(w, elapsed) end
    end
    local tickers = {}
    for _, t in ipairs(WoW.tickers) do tickers[#tickers + 1] = t end
    for _, t in ipairs(tickers) do
        while not t.cancelled and WoW.now >= t.at do
            t.at = t.at + t.every
            if t.left then
                t.left = t.left - 1
                if t.left <= 0 then t.cancelled = true end
            end
            t.cb(t)
        end
    end
    local keep = {}
    for _, t in ipairs(WoW.tickers) do if not t.cancelled then keep[#keep + 1] = t end end
    WoW.tickers = keep
end

-- Time passing: `seconds` of frames, `step` apart.
function WoW.advance(seconds, step)
    step = step or 0.1
    for _ = 1, math.floor(seconds / step + 0.5) do
        WoW.now = WoW.now + step
        WoW.tick(step)
    end
end

Kit.strict({ NodeRadar = true, NodeRadarDB = true, NodeRadarCharDB = true, NodeRadarProbeDB = true })
