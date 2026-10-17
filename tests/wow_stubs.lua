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
local DUMP = os.getenv("NODERADAR_API_DUMP") or "C:/Projects/WoW/References/forever-api-1.60.1.70450.md"
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
    table.insert(WoW.frames, w)
    if parent then
        parent._children = parent._children or {}
        table.insert(parent._children, w)
    end
    if name then rawset(_G, name, w) end
    return w
end
function Methods.GetChildren(w) return unpack(w._children or {}) end

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

local function blipsAt(dx, dy)
    local lines = {}
    for _, b in ipairs(WoW.blips) do
        if (b[2] - dx) ^ 2 + (b[3] - dy) ^ 2 <= 36 and (not b.kind or kindOn(b.kind)) then
            local c = b.colour or { 1, 1, 1 }
            lines[#lines + 1] = { leftText = b[1], type = 0, leftColor = { r = c[1], g = c[2], b = c[3], a = 1 } }
        end
    end
    return lines
end

C_TooltipInfo = {
    -- MayReturnNothing (TooltipInfoDocumentation.lua:619).
    GetMinimapMouseover = function()
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
    GetViewRadius = function() return 150 end,
    -- WoW.refuseTrackingOn: turning a tracking on does nothing (a cast the
    -- client refuses). Either way MINIMAP_UPDATE_TRACKING fires.
    SetTracking = function(i, on)
        assert(type(on) == "boolean", "SetTracking takes a bool")
        local t = WoW.tracking[i]
        if t and not (on and WoW.refuseTrackingOn) then t.active = on end
        WoW.fire("MINIMAP_UPDATE_TRACKING")
    end,
}

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
local allowNil = { NodeRadar = true, NodeRadarDB = true, NodeRadarProbeDB = true }
strmatch = string.match
setmetatable(_G, { __index = function(_, k)
    if allowNil[k] then return nil end
    error("read of undefined global '" .. tostring(k) .. "' (not stubbed: is it in the API dump?)", 2)
end })
