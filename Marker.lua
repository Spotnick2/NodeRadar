-- Marker.lua: a marker in the world on the compass's node (#61, experimental,
-- off by default; docs/PLAN.md, "A marker in the world").
--
-- Twinkling stars on the node's spot, seen through the scenery, as gathering
-- points sparkle in Final Fantasy XIV. The spot is the engine's navigation
-- frame, placed by the user waypoint we set on the node and super-track. We
-- step aside: never the player's waypoint, never while anything else is
-- super-tracked, and nothing written in combat or with the world map open.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Marker = {}
NR.Marker = Marker

Marker.MATCH = 1e-6    -- a waypoint read back is ours within this, in map units
Marker.SETTLE = 0.3    -- seconds hidden after a new waypoint (Blizzard's SuperTrackedFrame waits 0.2)
Marker.AGREE = 10      -- yards: the navigation's distance must agree with ours this well
Marker.NEAR = 15       -- yards: hidden this close, as the compass (Lueur's glow takes over)
Marker.CVAR = "showInGameNavigation"
Marker.STAR = 40       -- a star's size at scale 1 (22 was a speck: the world round, 70450)
Marker.SPREAD = 24     -- how far from the spot a star can light
Marker.GLOW = 90
Marker.STARS = 4
Marker.TEAL = { 0.55, 1, 0.9 }    -- the glow
Marker.WHITE = { 0.9, 1, 1 }      -- the stars: white, a cyan tinge
Marker.NEAR_SCALE, Marker.FAR_SCALE = 1.3, 0.7   -- the scale near and far (60 / yards between them)
Marker.HIDDEN_EVERY = 0.1  -- seconds between checks while armed but hidden (behind, settling)
Marker.RETRY = 0.5     -- seconds between tries while ours is installed but not wanted (the map open, combat)
Marker.GRACE = 2       -- seconds past the idle interval without a sweep before the target is stale

local want       -- { map, x, y, record, north, west, at }: the target's point at the last sweep
local ours       -- { map, x, y }: the waypoint we set and read back
local writing    -- inside our own waypoint or super-track calls
local cvarExpect -- the value we set the CVar to, while a restore is pending
local nav        -- the navigation frame (NAVIGATION_FRAME_CREATED)
local settledAt = 0
local reconciling

function Marker.On()
    local db = NR.db
    return db and db.marker and db.enabled and true or false
end

-- The last sweep's target, while sweeps confirm it: none for longer than the
-- idle interval and a grace (the radar held: tracking off, the gamepad, a
-- learner's experiment), and it's no longer the target (Codex, PR #74).
local function fresh()
    return want ~= nil and GetTime() - want.at <= NR.db.interval + Marker.GRACE
end

--------------------------------------------------------------------------------
-- What the client says
--------------------------------------------------------------------------------

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return v end
end
local function yes(fn) return API.Yes(call(fn)) end

-- The waypoint now: map, x, y; nil when none or unreadable.
local function point()
    local p = call(C_Map.GetUserWaypoint)
    if type(p) ~= "table" or API.IsSecret(p) then return nil end
    local pos = p.position
    local map = API.Num(p.uiMapID)
    local x, y = type(pos) == "table" and API.Num(pos.x), type(pos) == "table" and API.Num(pos.y)
    if map and x and y then return map, x, y end
end
local function same(a, map, x, y)
    return a ~= nil and map == a.map and math.abs(x - a.x) <= Marker.MATCH and math.abs(y - a.y) <= Marker.MATCH
end
local function isOurs()
    if not ours then return false end
    local map, x, y = point()
    return map ~= nil and same(ours, map, x, y)
end
local function hasWaypoint() return yes(C_Map.HasUserWaypoint) end
local function tracking() return yes(C_SuperTrack.IsSuperTrackingAnything) end
local function trackingWaypoint() return yes(C_SuperTrack.IsSuperTrackingUserWaypoint) end
-- Something other than the user waypoint super-tracked: the navigation frame is shared.
local OTHERS = { "IsSuperTrackingQuest", "IsSuperTrackingCorpse", "IsSuperTrackingContent",
                 "IsSuperTrackingMapPin" }
local function trackingOther()
    if tracking() and not trackingWaypoint() then return true end
    for _, f in ipairs(OTHERS) do if yes(C_SuperTrack[f]) then return true end end
    return call(C_SuperTrack.GetSuperTrackedVignette) ~= nil
end
-- Nothing is written in combat or with the world map open (taint: the map
-- builds its waypoint pin as it's set).
local function busy()
    if InCombatLockdown() then return true end
    local map = rawget(_G, "WorldMapFrame")
    local ok, shown = pcall(function() return map and map:IsShown() end)
    return not ok or API.Yes(shown)
end

local function here()
    local ok, n, w = pcall(UnitPosition, "player")
    if not ok then return nil end
    n, w = API.Num(n), API.Num(w)
    if n and w then return n, w end
end

--------------------------------------------------------------------------------
-- Ours, saved: NodeRadarCharDB.marker = { map, x, y } while our waypoint is set
-- and not yet cleared (cleared at logout, so a waypoint at login is never
-- taken for ours unless that clear didn't happen).
--------------------------------------------------------------------------------

local function save()
    NR.charDb.marker = ours and { map = ours.map, x = ours.x, y = ours.y } or nil
end
local function forget()
    ours = nil
    save()
end

-- Ours, the super-track first if it's the waypoint's, then the waypoint, each
-- checked again at that moment.
local function clear()
    if not isOurs() then forget(); return end
    writing = true
    if trackingWaypoint() then call(C_SuperTrack.SetSuperTrackedUserWaypoint, false) end
    if isOurs() then call(C_Map.ClearUserWaypoint) end
    writing = false
    forget()
end

-- Set on the point, read back, and super-tracked only if it's ours: anything
-- else inside our call (another addon answering USER_WAYPOINT_UPDATED) isn't.
local function set(d)
    writing = true
    local made = call(UiMapPoint.CreateFromCoordinates, d.map, d.x, d.y)
    local ok = made and API.Yes(call(C_Map.SetUserWaypoint, made))
    local map, x, y = point()
    if ok and map and same(d, map, x, y) then
        ours = { map = map, x = x, y = y }
        save()
        call(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        settledAt = GetTime() + Marker.SETTLE
    end
    writing = false
end

--------------------------------------------------------------------------------
-- The stars
--------------------------------------------------------------------------------

local MEDIA = "Interface\\AddOns\\NodeRadar\\Media\\"
local root = CreateFrame("Frame", nil, UIParent)
root:SetSize(1, 1)
root:EnableMouse(false)
root:SetFrameStrata("BACKGROUND")
root:Hide()
local glow, stars = nil, {}

local function part(file, size, layer, tint)
    local f = CreateFrame("Frame", nil, root)
    f:SetSize(size, size)
    f:SetPoint("CENTER", root, "CENTER")
    f:EnableMouse(false)
    local t = f:CreateTexture(nil, layer)
    t:SetTexture(MEDIA .. file)
    t:SetBlendMode("ADD")
    t:SetAllPoints(f)
    t:SetVertexColor(tint[1], tint[2], tint[3])
    f.tex = t
    return f
end

local function anim(group, kind, from, to, duration, order, delay)
    local a = group:CreateAnimation(kind)
    if kind == "Alpha" then a:SetFromAlpha(from); a:SetToAlpha(to)
    else a:SetScaleFrom(from, from); a:SetScaleTo(to, to) end
    a:SetDuration(duration)
    a:SetOrder(order)
    if delay then a:SetStartDelay(delay) end
    return a
end

-- A star lights at a new spot each time round, after a short random wait.
local function place(s)
    local r, a = Marker.SPREAD * math.sqrt(math.random()), math.random() * 2 * math.pi
    s:ClearAllPoints()
    s:SetPoint("CENTER", root, "CENTER", r * math.cos(a), r * math.sin(a) * 0.6)
    s.wait:SetStartDelay(0.05 + 0.25 * math.random())
end

local function build()
    if glow then return end
    glow = part("SonarGlow", Marker.GLOW, "ARTWORK", Marker.TEAL)
    local g = glow:CreateAnimationGroup()
    anim(g, "Alpha", 0.5, 0.85, 1.2, 1)
    g:SetLooping("BOUNCE")
    glow.anim = g
    for i = 1, Marker.STARS do
        local s = part("MarkerStar", Marker.STAR, "OVERLAY", Marker.WHITE)
        s:SetAlpha(0)                                  -- seen only while its animation runs
        local ag = s:CreateAnimationGroup()
        s.wait = anim(ag, "Alpha", 0, 0, 0.01, 1, 0)
        anim(ag, "Alpha", 0, 1, 0.15, 2)
        anim(ag, "Scale", 0.3, 1, 0.15, 2)
        anim(ag, "Alpha", 1, 0, 0.35, 3)
        anim(ag, "Scale", 1, 0.4, 0.35, 3)
        ag:SetScript("OnFinished", function() place(s); ag:Play() end)
        s.anim = ag
        place(s)
        s.wait:SetStartDelay((i - 1) * 0.5 / Marker.STARS)   -- staggered, so one is always lit
        stars[i] = s
    end
end

local function play(on)
    for _, f in ipairs(stars) do if on then f.anim:Play() else f.anim:Stop() end end
    if glow then if on then glow.anim:Play() else glow.anim:Stop() end end
end

local function hideStars()
    if root:IsShown() then
        root:Hide()
        play(false)
    end
end

-- Whether the stars may show now, and how far the node is.
local function showable()
    if not (Marker.On() and ours and want and nav and same(ours, want.map, want.x, want.y)) then return nil end
    if GetTime() < settledAt or not trackingWaypoint() or trackingOther() then return nil end
    if not yes(C_Navigation.HasValidScreenPosition) or yes(C_Navigation.WasClampedToScreen) then return nil end
    local pn, pw = here()
    local r = want.record
    if not pn then return nil end
    local mine = math.sqrt((r.north - pn) ^ 2 + (r.west - pw) ^ 2)
    local theirs = API.Num(call(C_Navigation.GetDistance))
    if not theirs or math.abs(theirs - mine) > Marker.AGREE then return nil end
    local ok, taxi = pcall(UnitOnTaxi, "player")
    if mine < Marker.NEAR or (ok and API.Yes(taxi)) then return nil end
    return mine
end

local since = 0
local function onUpdate(_, elapsed)
    if not fresh() then Marker.Reconcile(); return end    -- stale: dropped, ours cleared
    if not root:IsShown() then
        since = since + elapsed
        if since < Marker.HIDDEN_EVERY then return end
    end
    since = 0
    local d = showable()
    if not d then hideStars(); return end
    root:SetScale(math.max(Marker.FAR_SCALE, math.min(Marker.NEAR_SCALE, 60 / d)))
    if not root:IsShown() then
        root:Show()
        play(true)
    end
end

-- While ours is installed but not the target's (a clear held by combat or the
-- map, the frame not made yet): tried again, sweeps or none, until it's done.
local retried = 0
local function onRetry(_, elapsed)
    retried = retried + elapsed
    if retried < Marker.RETRY then return end
    retried = 0
    Marker.Reconcile()
end

-- Armed (our waypoint on the target, the frame there): checked every frame
-- while shown, ten times a second while hidden; ours otherwise, the retry;
-- nothing of ours, nothing runs.
local driver = CreateFrame("Frame")
local function arm()
    local armed = Marker.On() and ours and want and nav and same(ours, want.map, want.x, want.y)
    if armed then
        build()
        root:ClearAllPoints()
        root:SetPoint("CENTER", nav, "CENTER")
        driver:SetScript("OnUpdate", onUpdate)
    else
        driver:SetScript("OnUpdate", ours and onRetry or nil)
        hideStars()
    end
end

--------------------------------------------------------------------------------
-- The reconciler: what should be against what is, read again each time
--------------------------------------------------------------------------------

function Marker.Reconcile()
    if reconciling or not NR.db or not NR.charDb then return end
    reconciling = true
    if want and not fresh() then want = nil end
    if ours and not isOurs() then forget() end         -- replaced (theirs now) or gone
    if not busy() then
        local on = Marker.On()
        local desire = on and want or nil
        -- No target known (a fresh load before its first sweep included): ours
        -- goes, and the next sweep sets it again (Codex, PR #74: a hold till a
        -- sweep could last forever with tracking off).
        local onTarget = desire ~= nil and same(ours, desire.map, desire.x, desire.y)
        if ours and (not on or not onTarget or trackingOther()) then clear() end
        if desire and not ours and not hasWaypoint() and not tracking() then set(desire) end
    end
    reconciling = false
    arm()
end

-- After each radar sweep: the target's point from this sweep's map and the
-- player's position in the same frame (as Scan.MapPosition does for a blip).
-- The same record, not moved: its point is kept, since one computed again
-- from a moving player differs by a hair and would set the waypoint anew every
-- sweep (the world round, 70450).
Marker.KEEP = 1        -- yards: a record moved less than this keeps its point
function Marker.Update(result)
    if not Marker.On() then return end
    local r = NR.Compass.Chosen()
    local where = result and result.where
    if r and want and want.record == r and where and where.map == want.map
        and math.abs(r.north - want.north) < Marker.KEEP and math.abs(r.west - want.west) < Marker.KEEP then
        want.at = GetTime()
        Marker.Reconcile()
        return
    end
    local pn, pw = here()
    want = nil
    if r and where and pn and where.w and where.h and where.w > 0 and where.h > 0 then
        local x = where.x + (pw - r.west) / where.w
        local y = where.y - (r.north - pn) / where.h
        if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            want = { map = where.map, x = x, y = y, record = r, north = r.north, west = r.west, at = GetTime() }
        end
    end
    Marker.Reconcile()
end

--------------------------------------------------------------------------------
-- showInGameNavigation: on while the marker is (Blizzard's frame needs it),
-- put back after, unless someone else changed it meanwhile.
--------------------------------------------------------------------------------

local function cvar() return call(C_CVar.GetCVar, Marker.CVAR) end
local function setCVar(v)
    cvarExpect = v
    return API.Yes(call(C_CVar.SetCVar, Marker.CVAR, v))
end

local function cvarOn()
    if NR.db.markerCVar ~= nil or cvar() ~= "0" then return end
    if setCVar("1") then NR.db.markerCVar = "0" else cvarExpect = nil end
end
local function cvarBack()
    local old = NR.db.markerCVar
    if old == nil then return end
    NR.db.markerCVar = nil
    if cvar() == "1" then setCVar(old) end
    cvarExpect = nil
end

-- The compass's target gone (its records cleared: tracking off, a loading
-- screen, death, Compass.Reset): no point now, ours cleared (Codex, PR #74).
function Marker.TargetGone()
    want = nil
    Marker.Reconcile()
end

-- The setting or NodeRadar turned on or off (NR.Set, /nr reset).
function Marker.Toggle()
    if Marker.On() then cvarOn() else cvarBack(); want = nil end
    Marker.Reconcile()
end

--------------------------------------------------------------------------------
-- Blizzard's own marker (a small gold diamond, its distance under it: the world
-- round, 70450), while our stars are on the spot: the diamond hidden (the stars mark
-- it), its distance kept, unless the compass shows the distance already, then
-- the whole marker hidden (Codex's choice, the owner's leave, 2026-10-20). Only
-- while our waypoint is the one tracked and on screen: behind, its edge arrow
-- stays; anything the player tracks, theirs is untouched. A post-hook on its
-- UpdateAlpha (its OnUpdate calls it every frame): the frame's alpha set to 0
-- after Blizzard's own, so it fades back in by itself; the diamond's (Icon,
-- whose alpha Blizzard never sets) put back once when we stop.
--------------------------------------------------------------------------------

-- Only while the stars are actually on the spot, and our waypoint is still the
-- one tracked, alone, read now: a quest the player tracks while our clear is
-- held (combat, the map) keeps its own marker (Codex, PR #75).
local function covered()
    return root:IsShown() and isOurs() and trackingWaypoint() and not trackingOther()
        and not yes(C_Navigation.WasClampedToScreen)
end
Marker.Covered = covered

local hooked
local function hookBlizzard()
    local f = rawget(_G, "SuperTrackedFrame")
    if hooked or type(f) ~= "table" or type(f.UpdateAlpha) ~= "function" then return end
    hooked = true
    local iconHidden
    hooksecurefunc(f, "UpdateAlpha", function(self)
        local c = covered()
        if c and NR.Compass.On() then self:SetAlpha(0) end
        local icon = self.Icon
        if type(icon) ~= "table" then return end
        if c then
            icon:SetAlpha(0)
            iconHidden = true
        elseif iconHidden then
            icon:SetAlpha(1)
            iconHidden = nil
        end
    end)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
API.RegisterEvents(events, { "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_REGEN_ENABLED", "USER_WAYPOINT_UPDATED",
    "SUPER_TRACKING_CHANGED", "NAVIGATION_FRAME_CREATED", "NAVIGATION_FRAME_DESTROYED", "CVAR_UPDATE",
    "ADDON_LOADED" })
events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "Blizzard_QuestNavigation" then hookBlizzard() end
        return
    end
    if not (NR.db and NR.charDb) then return end
    if event == "PLAYER_LOGIN" then
        hookBlizzard()
        -- A waypoint left from before is ours only if it's the saved one
        -- (within MATCH, as saved), its clear at logout never done (a crash,
        -- a disconnect).
        local s = NR.charDb.marker
        local map, x, y = point()
        if type(s) == "table" and map and API.Num(s.map) and API.Num(s.x) and API.Num(s.y) and same(s, map, x, y) then
            ours = { map = map, x = x, y = y }
        else
            NR.charDb.marker = nil
        end
        nav = call(C_Navigation.GetFrame)
        if Marker.On() then cvarOn() else cvarBack() end
        Marker.Reconcile()
    elseif event == "PLAYER_LOGOUT" then
        if ours and not busy() then clear() end         -- a reload sets it again
    elseif event == "USER_WAYPOINT_UPDATED" then
        if writing then return end
        if ours and not isOurs() then forget() end
        Marker.Reconcile()
    elseif event == "NAVIGATION_FRAME_CREATED" then
        nav = call(C_Navigation.GetFrame)
        Marker.Reconcile()
    elseif event == "NAVIGATION_FRAME_DESTROYED" then
        nav = nil
        root:ClearAllPoints()
        Marker.Reconcile()
    elseif event == "CVAR_UPDATE" then
        local name = ...
        if type(name) == "string" and name:lower() == Marker.CVAR:lower() and NR.db.markerCVar ~= nil
            and cvar() ~= cvarExpect then
            NR.db.markerCVar = nil                     -- someone else's change: theirs stands
            cvarExpect = nil
        end
    else
        Marker.Reconcile()                             -- SUPER_TRACKING_CHANGED, PLAYER_REGEN_ENABLED
    end
end)

Marker._test = {
    root = root, stars = stars, driver = driver, hooked = function() return hooked end,
    ours = function() return ours end,
    want = function() return want end,
    nav = function() return nav end,
    reset = function() ours, want, nav = nil, nil, nil end,   -- a fresh load
}
