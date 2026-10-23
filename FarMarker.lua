-- One distant beacon, using the navigation anchor measured in #61. Its height
-- is approximate: sparkles, vapor, and a height hint guide the approach; Marker.lua's
-- object plate supplies the exact nearby spot. The player's navigation wins.
local NR = NodeRadar
local API = NR.API
local Far = {}
NR.FarMarker = Far

Far.SETTLE, Far.GRACE, Far.MATCH = 0.3, 2, 1e-6
Far.RANGE, Far.FADE = 60, 45
local CVAR = "showInGameNavigation"
local want, ours, nav, writing, writingCVar, exiting, reconciling, rangeHidden
local initialRead, settledAt, elapsed = true, 0, 0
local root = CreateFrame("Frame", nil, UIParent)
root:SetSize(1, 1)
root:EnableMouse(false)
root:SetFrameStrata("BACKGROUND")
root:Hide()
local driver = CreateFrame("Frame")
local art, beam, vapor, label
local anchored, dressedHeight, low = nil, nil, -50
local sparks = {}

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok and not API.IsSecret(value) then return value end
end
-- nil is unknown, not permission to occupy or clear the navigation slot.
local function boolean(fn, ...)
    local value = call(fn, ...)
    if type(value) == "boolean" then return value end
end
local function point()
    local p = call(C_Map.GetUserWaypoint)
    if type(p) ~= "table" then return end
    local pos = p.position
    if API.IsSecret(pos) or type(pos) ~= "table" then return end
    local map, x, y = API.Num(p.uiMapID), API.Num(pos.x), API.Num(pos.y)
    if map and x and y then return { map = map, x = x, y = y } end
end
local function same(a, b)
    return a and b and a.map == b.map and math.abs(a.x - b.x) <= Far.MATCH and math.abs(a.y - b.y) <= Far.MATCH
end
local function own()
    if not ours then return false end
    local p = point()
    if p then return same(ours, p) and true or false end
    if boolean(C_Map.HasUserWaypoint) == false then return false end
end
local function tracked() return boolean(C_SuperTrack.IsSuperTrackingUserWaypoint) end
local function other()
    local any, wp = boolean(C_SuperTrack.IsSuperTrackingAnything), tracked()
    if any == nil or wp == nil then return nil end
    if any and not wp then return true end
    for _, name in ipairs({ "IsSuperTrackingQuest", "IsSuperTrackingCorpse", "IsSuperTrackingContent", "IsSuperTrackingMapPin" }) do
        local value = boolean(C_SuperTrack[name])
        if value == nil then return nil end
        if value then return true end
    end
    local ok, v = pcall(C_SuperTrack.GetSuperTrackedVignette)
    if not ok or API.IsSecret(v) then return nil end
    return v ~= nil
end
local function free()
    return boolean(C_Map.HasUserWaypoint) == false and boolean(C_SuperTrack.IsSuperTrackingAnything) == false
        and other() == false
end
local function busy()
    if InCombatLockdown() or API.Gamepad() then return true end
    local map = rawget(_G, "WorldMapFrame")
    return map and boolean(map.IsShown, map) ~= false or false
end
local function save() NR.charDb.farMarker = ours and { map = ours.map, x = ours.x, y = ours.y } or nil end
local function forget() ours, rangeHidden = nil, nil; save() end
local function status(reason)
    if Far.reason ~= reason then
        Far.reason = reason
        NR.Marker.Note("distant beacon", "state", reason)
    end
end
local function hide(reason)
    root:Hide()
    for _, s in ipairs(sparks) do s.anim:Stop() end
    if vapor then vapor:Stop() end
    status(reason)
end

-- Revalidate after every call: synchronous handlers can change the slot or
-- open the map. Failed writes retain ownership for the next cleanup attempt.
local function clear()
    if own() == false then forget(); return end
    if own() ~= true or busy() then return end
    writing = true
    if tracked() == true and other() == false then call(C_SuperTrack.SetSuperTrackedUserWaypoint, false) end
    if not busy() and own() == true and tracked() == false then call(C_Map.ClearUserWaypoint) end
    if own() == false then forget() end
    writing = false
end
local function trackOurs()
    if not busy() and own() == true and boolean(C_SuperTrack.IsSuperTrackingAnything) == false and other() == false then
        writing = true
        call(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        writing = false
        settledAt = GetTime() + Far.SETTLE
    end
end
local function setPoint(d)
    if busy() or not free() then return end
    writing = true
    local p = call(UiMapPoint.CreateFromCoordinates, d.map, d.x, d.y)
    local ok = p and boolean(C_Map.SetUserWaypoint, p)
    local back = point()
    if ok and same(d, back) then ours = back; save() end
    writing = false
    if ours then trackOurs() end
end

local function cvar() return call(C_CVar.GetCVar, CVAR) end
local function putCVar(value)
    writingCVar = true
    call(C_CVar.SetCVar, CVAR, value)
    writingCVar = false
    return cvar() == value
end
local function releaseCVar()
    local e = NR.db.farNavigation
    if not e or busy() then return end
    if e.cancelled then NR.db.farNavigation = nil; return end
    local now = cvar()
    if now == nil then return end
    if now ~= e.ours or putCVar(e.old) then NR.db.farNavigation = nil end
end
local function claimCVar()
    local e, now = NR.db.farNavigation, cvar()
    if e and e.cancelled then return false end
    if now == nil or busy() then return false end
    if e then
        if now == e.ours then return true end
        -- A restore left across a reload: read once after the sync window.
        if initialRead and now == e.old then return putCVar(e.ours) end
        NR.db.farNavigation = { cancelled = true }
        return false
    end
    if now == "1" then return true end
    if putCVar("1") then NR.db.farNavigation = { old = now, ours = "1" }; return true end
    return false
end

local function placeSpark(s, delay)
    s:ClearAllPoints()
    local radius, angle = math.sqrt(math.random()), math.random() * 2 * math.pi
    s:SetPoint("CENTER", art, "CENTER", radius * math.cos(angle) * 30, low + 50 + radius * math.sin(angle) * 18)
    local size = 34 + math.random() * 24
    s:SetSize(size, size)
    s.wait:SetStartDelay(delay or (0.15 + math.random() * 0.4))
    s.drift:SetOffset(-2 - math.random() * 5, 3 + math.random() * 5)
end
local function build()
    if beam then return end
    art = CreateFrame("Frame", nil, root)
    art:SetSize(1, 1)
    art:SetPoint("CENTER", root, "CENTER")
    art:EnableMouse(false)
    beam = art:CreateTexture(nil, "ARTWORK")
    beam:SetTexture("Interface\\AddOns\\NodeRadar\\Media\\SonarGlow")
    beam:SetBlendMode("ADD")
    beam:SetVertexColor(0.35, 0.9, 0.75, 0.12)
    vapor = NR.Marker.CreateVapor(art)
    for i = 1, 4 do
        local s = CreateFrame("Frame", nil, art)
        s:EnableMouse(false)
        s:SetAlpha(0)
        local texture = s:CreateTexture(nil, "OVERLAY")
        texture:SetTexture("Interface\\AddOns\\NodeRadar\\Media\\MarkerStar.tga")
        texture:SetAllPoints(s)
        texture:SetBlendMode("ADD")
        texture:SetVertexColor(1, 1, 1)
        local ag = s:CreateAnimationGroup()
        s.wait = ag:CreateAnimation("Alpha")
        s.wait:SetFromAlpha(0); s.wait:SetToAlpha(0); s.wait:SetDuration(0.01); s.wait:SetOrder(1)
        local flash = ag:CreateAnimation("Alpha")
        flash:SetFromAlpha(0); flash:SetToAlpha(1); flash:SetDuration(0.12); flash:SetOrder(2); flash:SetSmoothing("OUT")
        local grow = ag:CreateAnimation("Scale")
        grow:SetScaleFrom(0.2, 0.2); grow:SetScaleTo(1, 1); grow:SetDuration(0.12); grow:SetOrder(2); grow:SetSmoothing("OUT")
        local fade = ag:CreateAnimation("Alpha")
        fade:SetFromAlpha(1); fade:SetToAlpha(0); fade:SetDuration(0.54); fade:SetOrder(3); fade:SetSmoothing("OUT")
        local shrink = ag:CreateAnimation("Scale")
        shrink:SetScaleFrom(1, 1); shrink:SetScaleTo(0.25, 0.25); shrink:SetDuration(0.54); shrink:SetOrder(3); shrink:SetSmoothing("IN")
        s.drift = ag:CreateAnimation("Translation")
        s.drift:SetDuration(0.54); s.drift:SetOrder(3)
        ag:SetScript("OnFinished", function()
            if root:IsShown() then placeSpark(s); ag:Play() end
        end)
        s.anim = ag
        sparks[i] = s
    end
    label = root:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    label:SetTextColor(0.8, 1, 0.9)
end
local function here()
    local ok, n, w = pcall(UnitPosition, "player")
    if ok then return API.Num(n), API.Num(w) end
end
local function targetDistance()
    local pn, pw = here()
    if not (want and pn and pw) then return nil end
    local r = want.record
    return math.sqrt((r.north - pn) ^ 2 + (r.west - pw) ^ 2)
end
local function inRange()
    local d = targetDistance()
    return d and d >= 6 and d < Far.RANGE
end
local function fresh()
    return want and GetTime() - want.at <= NR.db.interval + Far.GRACE
        and NR.Compass.Chosen() == want.record and NR.Alert.Wanted(want.record.name)
        and not NR.Compass.Snoozed(want.record)
end
local function usable()
    return NR.Marker.On() and not exiting and NR.Marker.Settled() and not API.Gamepad()
        and not NR.Learn.loading and not API.Dead() and not call(UnitOnTaxi, "player")
end
local function render()
    if not usable() then hide("inactive or settling"); return end
    if NR.Marker.Nearby() then hide("nearby stars"); return end
    if not fresh() then hide("no fresh target"); return end
    if not inRange() then rangeHidden = true; hide("outside beacon range"); return end
    rangeHidden = nil
    if NR.db.farNavigation and NR.db.farNavigation.cancelled then hide("navigation setting relinquished"); return end
    if not (ours and same(ours, want) and own() == true and tracked() == true and other() == false) then
        hide("navigation unavailable"); return
    end
    if cvar() ~= "1" then hide("navigation setting off"); return end
    if not nav or GetTime() < settledAt or boolean(C_Navigation.HasValidScreenPosition) ~= true
        or boolean(C_Navigation.WasClampedToScreen) ~= false then hide("navigation not ready or off screen"); return end
    local pn, pw = here()
    local theirs = API.Num(call(C_Navigation.GetDistance))
    if not (pn and pw and theirs) then hide("position unreadable"); return end
    local r = want.record
    local distance = math.sqrt((r.north - pn) ^ 2 + (r.west - pw) ^ 2)
    if distance < 6 or math.abs(distance - theirs) > 10 then hide("near or navigation moving"); return end
    build()
    if anchored ~= nav then
        root:ClearAllPoints()
        if not pcall(root.SetPoint, root, "CENTER", nav, "CENTER", 0, 0) then hide("anchor unavailable"); return end
        anchored = nav
    end
    -- Shrink the art with distance. The root's alpha handles the outer fade;
    -- independent child animations can twinkle without overriding that fade.
    local scale = math.max(0.35, math.min(1.2, 24 / distance))
    art:SetScale(scale)
    root:SetAlpha(math.min(1, math.max(0, (Far.RANGE - distance) / (Far.RANGE - Far.FADE))))
    if dressedHeight ~= r.height or Far.named ~= r.name then
        dressedHeight, Far.named = r.height, r.name
        low = r.height == "above" and -15 or r.height == "below" and -85 or -50
        beam:SetSize(96, 76)
        beam:ClearAllPoints(); beam:SetPoint("CENTER", art, "CENTER", 0, low + 50)
        vapor:ClearAllPoints(); vapor:SetPoint("CENTER", art, "CENTER", 0, low + 50)
        for i, s in ipairs(sparks) do placeSpark(s, (i - 1) * 0.25) end
        local hint = r.height == "above" and " - above" or r.height == "below" and " - below" or ""
        label:SetText(r.name .. hint)
    end
    label:ClearAllPoints(); label:SetPoint("BOTTOM", root, "CENTER", 0, (low + 100) * scale + 6)
    if not root:IsShown() then
        root:Show()
        vapor:Play()
        for i, s in ipairs(sparks) do placeSpark(s, (i - 1) * 0.25); s.anim:Play() end
    end
    status("shown")
end

local function arm()
    local active = NR.db and (NR.Marker.On() or ours or NR.db.farNavigation)
    driver:SetScript("OnUpdate", active and function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 0.5 then elapsed = 0; Far.Reconcile() end
        render()
    end or nil)
end
function Far.Reconcile()
    if reconciling or not (NR.db and NR.charDb) then return end
    reconciling = true
    if ours and own() == false then forget() end
    if want and not fresh() then want = nil end
    if NR.Marker.Settled() and not busy() then
        local desired = usable() and want and inRange() and not NR.Marker.Nearby() and want or nil
        if ours and (not desired or not same(ours, desired) or other() == true) then clear() end
        if desired and ((ours and own() == true and other() == false) or free()) then
            if claimCVar() then
                if not ours then setPoint(desired)
                elseif same(ours, desired) then trackOurs() end
            else
                if ours then clear() end
            end
        elseif not ours then
            -- A cancellation lasts until an explicit marker off/on.
            local e = NR.db.farNavigation
            if not (e and e.cancelled and NR.Marker.On()) then releaseCVar() end
        end
        initialRead = false
    end
    reconciling = false
    arm()
    render()
end

function Far.Update(result)
    if not NR.Marker.On() then return end
    local r, where = NR.Compass.Chosen(), result and result.where
    if r and want and want.record == r and where and where.map == want.map
        and math.abs(r.north - want.north) < 1 and math.abs(r.west - want.west) < 1 then
        want.at = GetTime()
    else
        want = nil
        local pn, pw = here()
        if r and where and pn and pw and where.w and where.h and where.w > 0 and where.h > 0 then
            local x, y = where.x + (pw - r.west) / where.w, where.y - (r.north - pn) / where.h
            if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                want = { map = where.map, x = x, y = y, record = r, north = r.north, west = r.west, at = GetTime() }
            end
        end
    end
    Far.Reconcile()
end
function Far.TargetGone() want = nil; Far.Reconcile() end
function Far.Toggle()
    if not NR.Marker.On() then
        want = nil
        if NR.db.farNavigation and NR.db.farNavigation.cancelled then NR.db.farNavigation = nil end
    end
    Far.Reconcile()
end

-- Our label replaces the native diamond and distance only while our own
-- beacon is visible. Blizzard restores its frame alpha on its next update.
local hooked
local function hookBlizzard()
    local f = rawget(_G, "SuperTrackedFrame")
    if hooked or type(f) ~= "table" or type(f.UpdateAlpha) ~= "function" then return end
    hooked = true
    hooksecurefunc(f, "UpdateAlpha", function(self)
        -- Keep suppression through a stale target while cleanup waits in combat.
        local outside = rangeHidden
        if (root:IsShown() or outside) and own() == true and tracked() == true and other() == false
            and (outside or boolean(C_Navigation.WasClampedToScreen) == false) then self:SetAlpha(0) end
    end)
end
local events = CreateFrame("Frame")
API.RegisterEvents(events, { "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
    "USER_WAYPOINT_UPDATED", "SUPER_TRACKING_CHANGED", "NAVIGATION_FRAME_CREATED", "NAVIGATION_FRAME_DESTROYED",
    "CVAR_UPDATE", "ADDON_LOADED" })
events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then if ... == "Blizzard_QuestNavigation" then hookBlizzard() end; return end
    if not (NR.db and NR.charDb) then return end
    if event == "PLAYER_LOGIN" then
        exiting, initialRead, want = nil, true, nil
        local s = NR.charDb.farMarker
        if type(s) == "table" and API.Num(s.map) and API.Num(s.x) and API.Num(s.y) and same(s, point()) then ours = s
        else forget() end
        nav = call(C_Navigation.GetFrame)
        hookBlizzard()
    elseif event == "PLAYER_LOGOUT" then
        exiting, want = true, nil
        hide("logout")
        if not busy() then clear(); if not ours then releaseCVar() end end
        driver:SetScript("OnUpdate", nil)
        return
    elseif event == "NAVIGATION_FRAME_CREATED" then
        nav = call(C_Navigation.GetFrame)
        settledAt = GetTime() + Far.SETTLE
    elseif event == "NAVIGATION_FRAME_DESTROYED" then
        nav, anchored = nil, nil; root:ClearAllPoints(); hide("navigation frame gone")
    elseif event == "CVAR_UPDATE" then
        if not NR.Marker.Settled() or initialRead or exiting or writingCVar or API.Gamepad() then return end
        local e = NR.db.farNavigation
        local now = cvar()
        if e and not e.cancelled and now and now ~= e.ours then NR.db.farNavigation = { cancelled = true } end
    end
    if not writing and not exiting then Far.Reconcile() end
end)

Far._test = { root = root, driver = driver, label = function() return label end, beam = function() return beam end,
    art = function() return art end, vapor = function() return vapor end, sparks = sparks,
    ours = function() return ours end, want = function() return want end }
