-- wow_stubs.lua: a minimal WoW: Forever mock for Lua 5.1 unit tests.
-- dofile("tests/wow_stubs.lua") FIRST in every test; drive it via the WoW table.
-- GlassMail's stubs, the generic part (secrets, events, widgets, strict
-- globals), plus the minimap and what the gathering blips need.
--
-- What it models, on purpose:
-- - STRICT globals: reading any global it does not define is an error. The
--   stub is the allowlist of APIs verified present in the API dump; defining
--   something Forever lacks is how a missing API survives into a build.
-- - SECRETS as newproxy userdata: arithmetic, ordering, tostring, concat and
--   string.format on one throw. Lua 5.1 cannot make a truth test or == throw,
--   so those two misuses are NOT caught here (only in game / in review).
-- - EVENT names: RegisterEvent throws on a name the API dump does not declare
--   (tests/events-70450.txt when the dump is absent, as on CI).
-- - METHOD calls: every widget method called is recorded (WoW.methodsCalled)
--   so a test can check each against the dump's widget methods.
-- - THE MINIMAP'S MOUSEOVER: Minimap:UpdateMouseoverAtPoint(x, y) moves it and
--   C_TooltipInfo.GetMinimapMouseover() reads the blips there. Which
--   coordinates the client takes is what NodeRadarProbe measures (#2); here
--   it's WoW.mouseoverConvention, offsets from the map's centre by default.

WoW = {}
local DUMP = os.getenv("NODERADAR_API_DUMP") or "C:/Projects/WoW/References/Forever/api/forever-api-1.60.1.70450.md"
WoW.DUMP = DUMP
WoW.FIXTURE = "tests/events-70450.txt"

--------------------------------------------------------------------------------
-- Secrets
--------------------------------------------------------------------------------

local secrets = setmetatable({}, { __mode = "k" })

function WoW.Secret(label)
    local p = newproxy(true)
    local mt = getmetatable(p)
    local function boom() error("secret value touched in Lua: " .. label, 2) end
    for _, k in ipairs({ "__tostring", "__concat", "__add", "__sub", "__mul", "__div", "__mod",
                         "__pow", "__unm", "__lt", "__le", "__len", "__index", "__newindex", "__call" }) do
        mt[k] = boom
    end
    secrets[p] = label
    return p
end

function issecretvalue(v) return secrets[v] ~= nil end

--------------------------------------------------------------------------------
-- Known events (from the dump when present, else the checked-in fixture)
--------------------------------------------------------------------------------

WoW.KNOWN_EVENTS = {}
WoW.dumpAvailable = false
do
    local f = io.open(DUMP, "r")
    if f then
        local inEvents = false
        for line in f:lines() do
            if line:match("^## Documented events") then inEvents = true
            elseif line:match("^## ") then inEvents = false
            elseif inEvents then
                local name = line:match("^([A-Z][A-Z0-9_]+)%s+%(")
                if name then WoW.KNOWN_EVENTS[name] = true end
            end
        end
        f:close()
        WoW.dumpAvailable = next(WoW.KNOWN_EVENTS) ~= nil
    end
    if not WoW.dumpAvailable then
        -- No dump (CI): the list generated from it, so validation stays
        -- exactly as strict. test_toc fails if the two ever drift.
        local fixture = io.open(WoW.FIXTURE, "r")
        assert(fixture, WoW.FIXTURE .. " missing: event validation needs the dump or the fixture")
        for line in fixture:lines() do
            local name = line:match("^([A-Z][A-Z0-9_]+)%s*$")
            if name then WoW.KNOWN_EVENTS[name] = true end
        end
        fixture:close()
    end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

function WoW.reset()
    WoW.cvars = { rotateMinimap = "0" }
    WoW.frames = {}
    WoW.chat = {}
    WoW.methodsCalled = {}
    WoW.combat = false
    WoW.timers = {}
    WoW.now = 0
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local Methods = {}   -- shared implementations, by method name
WoW.Methods = Methods

local function record(w, name)
    WoW.methodsCalled[w._type .. ":" .. name] = true
end

local widgetMT = {
    __index = function(w, k)
        if type(k) ~= "string" or not k:match("^%u") then return nil end  -- fields read as nil
        return function(self, ...)
            record(self, k)
            local impl = Methods[k]
            if impl then return impl(self, ...) end
            return nil
        end
    end,
}

local function newWidget(wtype, parent, name)
    return setmetatable({ _type = wtype, _parent = parent, _shown = true, _points = {},
                          _scripts = {}, _events = {},
                          _level = parent and parent._level and (parent._level + 1) or 1,
                          _width = 0, _height = 0, _name = name }, widgetMT)
end
WoW.newWidget = newWidget

function CreateFrame(ftype, name, parent, template)
    local w = newWidget(ftype, parent, name)
    w._template = template
    -- The radio template's own label (CheckButtonTemplates.xml: parentKey "text").
    if template == "UIRadioButtonTemplate" then w.text = Methods.CreateFontString(w) end
    table.insert(WoW.frames, w)
    if parent then
        parent._children = parent._children or {}
        table.insert(parent._children, w)
    end
    if name then rawset(_G, name, w) end
    return w
end
function Methods.GetChildren(w) return unpack(w._children or {}) end

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
function Methods.SetChecked(w, on) w._checked = on and true or false end
function Methods.GetChecked(w) return w._checked == true end
function WoW.click(w)
    if w._type == "CheckButton" then w._checked = not w._checked end
    if w._scripts.OnClick then w._scripts.OnClick(w, "LeftButton") end
end

function Methods.Show(w) w._shown = true; if w._scripts.OnShow then w._scripts.OnShow(w) end end
function Methods.Hide(w)
    local was = w._shown
    w._shown = false
    if was and w._scripts.OnHide then w._scripts.OnHide(w) end
end
function Methods.SetShown(w, v) if v then Methods.Show(w) else Methods.Hide(w) end end
function Methods.IsShown(w) return w._shown end
function Methods.IsVisible(w)
    local p = w
    while p do if not p._shown then return false end; p = p._parent end
    return true
end
function Methods.SetPoint(w, ...) table.insert(w._points, { ... }) end
function Methods.ClearAllPoints(w) w._points = {} end
function Methods.GetPoint(w, i)
    local p = w._points[i or 1]
    if p then return p[1], p[2], p[3], p[4], p[5] end
end
function Methods.SetAllPoints(w, rel) table.insert(w._points, { "ALL", rel }) end
function Methods.SetSize(w, x, y) w._width, w._height = x, y end
function Methods.SetWidth(w, x) w._width = x end
function Methods.SetHeight(w, y) w._height = y end
function Methods.GetWidth(w) return w._width end
function Methods.GetHeight(w) return w._height end
function Methods.GetSize(w) return w._width, w._height end
function Methods.GetEffectiveScale(w) return w._effScale or 1 end
function Methods.SetAlpha(w, a) w._alpha = a end
function Methods.GetAlpha(w) return w._alpha or 1 end
function Methods.GetParent(w) return w._parent end
function Methods.SetParent(w, p) w._parent = p end
function Methods.GetFrameLevel(w) return w._level end
function Methods.SetFrameLevel(w, l) w._level = l end
function Methods.SetFrameStrata(w, s) w._strata = s end
function Methods.GetFrameStrata(w) return w._strata or "MEDIUM" end
function Methods.EnableMouse(w, v) w._mouse = v end
function Methods.Enable(b) b._disabled = false end
function Methods.Disable(b) b._disabled = true end
function Methods.SetEnabled(b, v) b._disabled = not v end
function Methods.IsEnabled(b) return not b._disabled end
function Methods.GetName(w) return w._name end
function Methods.GetDebugName(w) return w._name or ("<" .. w._type .. ">") end
function Methods.IsForbidden(w) return false end
function Methods.SetAttribute(w, k, v)
    if WoW.combat and w._protected then return end
    w._attrs = w._attrs or {}
    w._attrs[k] = v
end
function Methods.GetAttribute(w, k) return w._attrs and w._attrs[k] end
function Methods.SetScript(w, name, fn) w._scripts[name] = fn end
function Methods.GetScript(w, name) return w._scripts[name] end
function Methods.HookScript(w, name, fn)
    local old = w._scripts[name]
    w._scripts[name] = function(...) if old then old(...) end; fn(...) end
end
function Methods.RegisterEvent(w, e)
    if not WoW.KNOWN_EVENTS[e] then error("Attempt to register unknown event \"" .. e .. "\"", 2) end
    w._events[e] = true
    return true
end
function Methods.RegisterUnitEvent(w, e, ...)
    if not WoW.KNOWN_EVENTS[e] then error("Attempt to register unknown event \"" .. e .. "\"", 2) end
    w._events[e] = true
    return true
end
function Methods.UnregisterEvent(w, e) w._events[e] = nil end
function Methods.IsEventRegistered(w, e) return w._events[e] == true end

-- Regions: listed in creation order for GetRegions.
local function addRegion(w, r)
    w._regions = w._regions or {}
    table.insert(w._regions, r)
    return r
end
function Methods.CreateTexture(w, name, layer, template, sublevel)
    local t = addRegion(w, newWidget("Texture", w, name))
    t._layer, t._sublevel = layer, sublevel
    if name then rawset(_G, name, t) end
    return t
end
function Methods.CreateFontString(w, name)
    local fs = addRegion(w, newWidget("FontString", w, name))
    if name then rawset(_G, name, fs) end
    return fs
end
function Methods.GetRegions(w) return unpack(w._regions or {}) end
function Methods.GetObjectType(w) return w._type end
function Methods.SetTexture(t, file) t._file = file; return true end
function Methods.SetColorTexture(t, r, g, b, a) t._color = { r, g, b, a } end
function Methods.SetVertexColor(t, r, g, b, a) t._vertex = { r, g, b, a } end
-- Animations: groups record whether they play.
function Methods.CreateAnimationGroup(w) return newWidget("AnimationGroup", w) end
function Methods.CreateAnimation(ag, atype) return newWidget(atype or "Animation", ag) end
function Methods.Play(ag) ag._playing = true end
function Methods.Stop(ag) ag._playing = false end
function Methods.IsPlaying(ag) return ag._playing == true end
function Methods.SetText(fs, text) fs._text = text end
function Methods.GetText(fs) return fs._text end
function Methods.SetFont(fs, file, size, flags) fs._font = { file, size, flags }; return true end
function Methods.SetFontObject(fs, obj) fs._fontObject = obj end
function Methods.GetFont(fs)
    local f = fs._font or { "Fonts\\FRIZQT__.TTF", 10, "" }
    return f[1], f[2], f[3]
end

WoW.reset()

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

UIParent = newWidget("Frame", nil, "UIParent")
UIParent._level = 0

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(WoW.chat, table.concat(parts, " "))
end

SlashCmdList = {}
Enum = {}
date = os.date
-- The clock follows WoW.now, so a test that advances time also turns the
-- second (ForeverProbe takes a screenshot just after it changes).
function time(t) if t then return os.time(t) end return 1760000000 + math.floor(WoW.now) end
function GetTime() return WoW.now end
function GetServerTime() return time() end
function GetBuildInfo() return "1.60.1", "70450", "Oct 15 2026", 16001 end
function InCombatLockdown() return WoW.combat == true end
function GetCVar(name) return WoW.cvars[name] end
function GetCVarBool(name) return WoW.cvars[name] == "1" end
function debugprofilestop() return os.clock() * 1000 end
-- The whole Lua state's memory stands in for one addon's.
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage() return collectgarbage("count") end

WoW.addonVersion = "dev"
C_AddOns = {
    GetAddOnMetadata = function(name, field) if field == "Version" then return WoW.addonVersion end end,
}

-- C_Timer.After keeps its delay: WoW.flushTimers(upTo) runs those due within
-- upTo seconds (all when nil) and keeps the rest. WoW.drainTimers() runs them
-- until none is left, timers set by timers included.
C_Timer = { After = function(s, fn) table.insert(WoW.timers, { s = s, fn = fn }) end }
function WoW.flushTimers(upTo)
    local run, keep = {}, {}
    for _, t in ipairs(WoW.timers) do
        if upTo == nil or t.s <= upTo then run[#run + 1] = t else keep[#keep + 1] = t end
    end
    WoW.timers = keep
    for _, t in ipairs(run) do t.fn() end
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
function IsInGroup() return WoW.group end
function GetLocale() return WoW.locale end

-- Spells: names by ID (C_Spell.GetSpellInfo); WoW.cooling[id] puts one on cooldown.
WoW.spellNames = { [2366] = "Herb Gathering", [2368] = "Herb Gathering", [2575] = "Mining", [2576] = "Mining",
                   [2383] = "Find Herbs", [2580] = "Find Minerals" }
WoW.cooling = {}
C_Spell = {
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
function IsIndoors() return WoW.indoors == true end
C_CVar = { GetCVar = function(name) return WoW.cvars[name] end }

WoW.mounted = false
function IsMounted() return WoW.mounted end
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
Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        local c = { frame = frame, name = name, id = #WoW.categories + 1 }
        function c:GetID() return self.id end
        table.insert(WoW.categories, c)
        return c
    end,
    RegisterAddOnCategory = function(c) c.registered = true end,
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
function Methods.IsMouseOver(w) return w == Minimap and WoW.cursorOnMap == true end
function Methods.UpdateMouseoverAtPoint(w, x, y)
    assert(type(x) == "number" and type(y) == "number", "UpdateMouseoverAtPoint takes two numbers")
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
-- blip's own `half` makes it larger (a quest's objective area).
WoW.BLIP_HALF = 8.5
local function blipsAt(dx, dy)
    local lines = {}
    for _, b in ipairs(WoW.blips) do
        local half = b.half or WoW.BLIP_HALF
        if math.abs(b[2] - dx) <= half and math.abs(b[3] - dy) <= half
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
function hooksecurefunc(t, name, fn)
    if type(t) == "string" then t, name, fn = _G, t, name end
    local orig = t[name]
    t[name] = function(...)
        local r = { orig(...) }
        fn(...)
        return unpack(r)
    end
end

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

-- Fire an event at every frame registered for it. Errors are NOT caught: a
-- handler that throws fails the test.
function WoW.fire(event, ...)
    for _, w in ipairs(WoW.frames) do
        local handler = w._scripts.OnEvent
        if handler and w._events[event] then handler(w, event, ...) end
    end
end

-- One rendered frame: OnUpdate on every visible frame.
function WoW.tick(elapsed)
    elapsed = elapsed or 0.02
    local list = {}
    for _, w in ipairs(WoW.frames) do list[#list + 1] = w end
    for _, w in ipairs(list) do
        local fn = w._scripts.OnUpdate
        if fn and Methods.IsVisible(w) then fn(w, elapsed) end
    end
end

-- Time passing: `seconds` of frames, `step` apart.
function WoW.advance(seconds, step)
    step = step or 0.1
    for _ = 1, math.floor(seconds / step + 0.5) do
        WoW.now = WoW.now + step
        WoW.tick(step)
    end
end

-- Strict globals: any read of an undefined global is an error, except the
-- addon's own globals that are legitimately nil before first assignment.
local allowNil = { NodeRadar = true, NodeRadarDB = true, NodeRadarCharDB = true, NodeRadarProbeDB = true }
strmatch = string.match
setmetatable(_G, { __index = function(_, k)
    if allowNil[k] then return nil end
    error("read of undefined global '" .. tostring(k) .. "' (not stubbed: is it in the API dump?)", 2)
end })
