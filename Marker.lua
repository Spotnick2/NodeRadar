-- Marker.lua: the marker on the node's soft-interact plate (#78, experimental,
-- off by default; docs/PLAN.md, "The marker on the node's soft-interact plate").
--
-- Twinkling stars on the herb or ore itself, as gathering points sparkle in
-- Final Fantasy XIV. The game gives its soft-interact target a nameplate that
-- sits on the object at its real height, within about 15 yards (measured): the
-- stars go on it when the target is a node NodeRadar knows and the player
-- wants. That needs three of the player's interact CVars changed while the
-- marker is on; they're the player's, so each is claimed only when the marker
-- is turned on, put back when it goes off, and given up to anyone who changes
-- it meanwhile. Nothing is judged inside the gamepad UI (Blizzard puts its own
-- temporary values on these CVars there), nothing written in combat.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Marker = {}
NR.Marker = Marker

-- The CVars the plate needs, and ours: the ablation round (70450, 2026-10-22).
Marker.CVARS = {
    { "softTargetInteract", "3" },       -- interact targeting always on
    { "SoftTargetIconGameObject", "1" }, -- without the object's icon, no plate
    { "SoftTargetInteractRange", "60" }, -- past the default 10 (the plate reaches about 15 whatever this is)
}
Marker.TICK = 0.5      -- seconds between passes while on, or while a claim is left to put back
Marker.SETTLE = 5      -- seconds after entering the world before the login's read: the client's synced
                       -- CVars arrive after PLAYER_LOGIN and overwrite ours (the owner's run, #79)
Marker.STAR = 48       -- the reference's long diagonal rays, varied per flare
Marker.SPREAD = 30     -- how far from the spot a star can light
Marker.GLOW = 96
Marker.STARS = 4
Marker.TEAL = { 0.35, 0.9, 0.75 } -- a faint haze, not a bright central orb
Marker.WHITE = { 1, 1, 1 }       -- the star texture carries its mint/blue halo

local bound      -- { unit, plate }: the plate the stars are on
local writing    -- inside our own SetCVar: its CVAR_UPDATE is ours
local loggingOut -- logout restores can raise CVAR_UPDATE after SetCVar returns
local wasPad     -- the gamepad UI on at the last pass
local loginPhase = true -- from file load to the first PLAYER_ENTERING_WORLD; sync events can precede PLAYER_LOGIN
local settleUntil -- then SETTLE seconds: the client's synced CVars still coming
local readDue    -- a login read waiting (the window, the gamepad UI)
-- No CVar written or judged in the login window nor while its read waits.
local function waiting()
    return loggingOut or loginPhase or readDue or (settleUntil ~= nil and GetTime() < settleUntil) and true or false
end
function Marker.Settled() return not waiting() end
function Marker.Nearby() return bound ~= nil end

-- Recent CVar decisions stay in memory until NodeRadarProbe loads; its sink
-- saves them across reloads. Logging must never interrupt the marker.
Marker.Decisions = {}
local decisionSink
local function decision(name, action, why)
    local line = ("%.2f %s: %s; %s"):format(GetTime(), name, action, why)
    local log = Marker.Decisions
    log[#log + 1] = line
    if #log > 100 then table.remove(log, 1) end
    if decisionSink then pcall(decisionSink, line) end
end
Marker.Note = decision
function Marker.SetDecisionSink(sink)
    decisionSink = type(sink) == "function" and sink or nil
    if decisionSink then
        for _, line in ipairs(Marker.Decisions) do pcall(decisionSink, line) end
    end
end

function Marker.On()
    local db = NR.db
    return db and db.marker and db.enabled and true or false
end

--------------------------------------------------------------------------------
-- What the client says
--------------------------------------------------------------------------------

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return v end
end
local function text(v) if type(v) == "string" and not API.IsSecret(v) then return v end end
local function yes(fn, ...) return API.Yes(call(fn, ...)) end

-- CVars can read back reformatted ("60.000000" for 60).
local function get(name)
    local value = text(call(C_CVar.GetCVar, name))
    return value -- exactly one result, including nil for unreadable diagnostic reads
end
local function same(a, b) return a == b or (tonumber(a) ~= nil and tonumber(a) == tonumber(b)) end
local function put(name, value)
    writing = true
    call(C_CVar.SetCVar, name, value)
    writing = false
    return same(get(name), value)
end

--------------------------------------------------------------------------------
-- The CVars: NodeRadarDB.softCVars = { [name] = { old, ours } or { cancelled = true } },
-- NodeRadarDB.softClaim while a turn-on claim waits (combat, the gamepad UI).
--------------------------------------------------------------------------------

local function claims()
    NR.db.softCVars = NR.db.softCVars or {}
    return NR.db.softCVars
end
local function blocked() return InCombatLockdown() or API.Gamepad() end

-- The marker turned on: each CVar that differs set, its old value kept once
-- the game takes ours. One already claimed or cancelled is left as it is.
local function claim()
    if blocked() then NR.db.softClaim = true; return end
    NR.db.softClaim = nil
    local c = claims()
    for _, cv in ipairs(Marker.CVARS) do
        local name, ours = cv[1], cv[2]
        local old = get(name)
        if c[name] ~= nil then
            decision(name, c[name].cancelled and "claim skipped" or "kept",
                c[name].cancelled and "cancelled until marker off/on" or "already claimed")
        elseif old == nil then
            decision(name, "claim skipped", "current value unreadable")
        elseif same(old, ours) then
            decision(name, "claim skipped", "already at " .. ours .. "; player's value")
        else
            if put(name, ours) then
                c[name] = { old = old, ours = ours }
                decision(name, "claimed", "turn-on: " .. old .. " -> " .. ours)
            else
                decision(name, "claim failed", "turn-on: " .. old .. " -> " .. ours .. ", read-back " .. tostring(get(name)))
            end
        end
    end
end

-- Each claim given back: ours still there, the old value; anything else is
-- someone else's, left. Cancelled ones just go. Held in combat and in the
-- gamepad UI, done by a later pass. Unreadable values and unconfirmed restores
-- retain the saved original and keep the cleanup ticker alive.
local function release()
    NR.db.softClaim = nil
    if blocked() then return end
    local c = claims()
    for name, e in pairs(c) do
        if e.cancelled then
            decision(name, "given up", "marker off: cancelled claim forgotten")
            c[name] = nil
        else
            local now = get(name)
            if now == nil then
                decision(name, "restore deferred", "marker off: current value unreadable; claim retained")
            elseif same(now, e.ours) then
                local restored = put(name, e.old)
                decision(name, restored and "put back" or "restore failed",
                    "marker off: " .. tostring(e.ours) .. " -> " .. tostring(e.old)
                    .. ", read-back " .. tostring(get(name)))
                if restored then c[name] = nil end
            else
                decision(name, "given up", "marker off: current " .. tostring(now)
                    .. " differs from ours " .. tostring(e.ours))
                c[name] = nil
            end
        end
    end
end

-- Each claim read again, the marker on: still ours, kept; the old value (a
-- logout restore that stuck), ours set again (`fromOld`, at login only);
-- anything else, someone else's: cancelled, and it stays so until the marker
-- is turned off and on.
local function judge(fromOld)
    for name, e in pairs(claims()) do
        if e.cancelled then
            decision(name, "claim skipped", "prior cancellation kept at login/gamepad read")
        else
            local now = get(name)
            if same(now, e.ours) then
                decision(name, "kept", "login/gamepad read: still ours " .. tostring(now))
            elseif fromOld and same(now, e.old) then
                if put(name, e.ours) then
                    decision(name, "claimed", "login read: restored " .. tostring(e.old)
                        .. " -> " .. tostring(e.ours))
                else
                    decision(name, "given up", "login read: reapply failed; old " .. tostring(e.old)
                        .. ", read-back " .. tostring(get(name)))
                    claims()[name] = { cancelled = true }
                end
            else
                decision(name, "given up", (fromOld and "login read" or "gamepad exit")
                    .. ": current " .. tostring(now) .. ", ours " .. tostring(e.ours)
                    .. ", old " .. tostring(e.old))
                claims()[name] = { cancelled = true }
            end
        end
    end
end

-- At logout, best effort: ours put back so that removing NodeRadar leaves the
-- player's values, the claims kept (a read-back doesn't prove the file got it).
local function atLogout()
    if blocked() or not NR.db.softCVars then return end
    for name, e in pairs(NR.db.softCVars) do
        if e.cancelled then
            decision(name, "restore skipped", "logout: claim cancelled")
        elseif not same(get(name), e.ours) then
            decision(name, "restore skipped", "logout: current " .. tostring(get(name))
                .. " differs from ours " .. tostring(e.ours))
        else
            local restored = put(name, e.old)
            decision(name, restored and "put back" or "restore failed",
                "logout: " .. tostring(e.ours) .. " -> " .. tostring(e.old)
                .. ", claim retained; read-back " .. tostring(get(name)))
        end
    end
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
local glow, vapor, stars = nil, nil, {}

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

-- The same drifting vapor surrounds the nearby object and the approach beacon.
-- Three staggered wisps expand and dissolve; only the engine animates them.
function Marker.CreateVapor(parent)
    local cloud = CreateFrame("Frame", nil, parent)
    cloud:SetSize(1, 1)
    cloud:EnableMouse(false)
    cloud.wisps = {}
    local playing = false
    local function placeWisp(w, delay)
        w:ClearAllPoints()
        w:SetPoint("CENTER", cloud, "CENTER", math.random(-10, 10), math.random(-12, -4))
        w.tex:SetRotation(math.random() * 0.8 - 0.4)
        w.wait:SetStartDelay(delay or math.random() * 0.2)
        w.drift:SetOffset(math.random(-12, 12), 18 + math.random() * 12)
    end
    for i = 1, 3 do
        local w = CreateFrame("Frame", nil, cloud)
        w:SetSize(112, 70)
        w:EnableMouse(false)
        w:SetAlpha(0)
        w.tex = w:CreateTexture(nil, "ARTWORK")
        w.tex:SetTexture(MEDIA .. "MarkerVapor.tga")
        w.tex:SetAllPoints(w)
        w.tex:SetBlendMode("ADD")
        w.tex:SetVertexColor(0.4, 0.9, 0.75)
        local ag = w:CreateAnimationGroup()
        w.wait = anim(ag, "Alpha", 0, 0, 0.01, 1)
        anim(ag, "Alpha", 0, 0.38, 0.65, 2):SetSmoothing("OUT")
        anim(ag, "Alpha", 0.38, 0, 1.6, 2, 0.65):SetSmoothing("IN")
        anim(ag, "Scale", 0.65, 1.2, 2.25, 2)
        w.drift = ag:CreateAnimation("Translation")
        w.drift:SetDuration(2.25); w.drift:SetOrder(2)
        ag:SetScript("OnFinished", function()
            if playing then placeWisp(w); ag:Play() end
        end)
        w.anim = ag
        cloud.wisps[i] = w
    end
    function cloud:Play()
        playing = true
        for i, w in ipairs(self.wisps) do placeWisp(w, (i - 1) * 0.75); w.anim:Play() end
    end
    function cloud:Stop()
        playing = false
        for _, w in ipairs(self.wisps) do w.anim:Stop() end
    end
    return cloud
end

-- The reference: diagonal flares of different sizes, a little upward drift,
-- and independent pauses. The engine handles the motion between flares.
local function place(s, delay)
    local r, a = Marker.SPREAD * math.sqrt(math.random()), math.random() * 2 * math.pi
    s:ClearAllPoints()
    s:SetPoint("CENTER", root, "CENTER", r * math.cos(a), r * math.sin(a) * 0.6)
    local size = Marker.STAR * (0.7 + 0.5 * math.random())
    s:SetSize(size, size)
    s.drift:SetOffset(-2 - 5 * math.random(), 3 + 5 * math.random())
    s.wait:SetStartDelay(delay or (0.08 + 0.22 * math.random()))
end

local function build()
    if glow then return end
    glow = part("SonarGlow", Marker.GLOW, "ARTWORK", Marker.TEAL)
    local g = glow:CreateAnimationGroup()
    anim(g, "Alpha", 0.06, 0.14, 1.6, 1)
    g:SetLooping("BOUNCE")
    glow.anim = g
    vapor = Marker.CreateVapor(root)
    vapor:SetPoint("CENTER", root, "CENTER", 0, 0)
    for i = 1, Marker.STARS do
        local s = part("MarkerStar", Marker.STAR, "OVERLAY", Marker.WHITE)
        s:SetAlpha(0)                                  -- seen only while its animation runs
        local ag = s:CreateAnimationGroup()
        s.wait = anim(ag, "Alpha", 0, 0, 0.01, 1, 0)
        anim(ag, "Alpha", 0, 1, 0.12, 2):SetSmoothing("OUT")
        anim(ag, "Scale", 0.2, 1, 0.12, 2):SetSmoothing("OUT")
        anim(ag, "Alpha", 1, 0, 0.54, 3):SetSmoothing("OUT")
        anim(ag, "Scale", 1, 0.25, 0.54, 3):SetSmoothing("IN")
        s.drift = ag:CreateAnimation("Translation")
        s.drift:SetDuration(0.54)
        s.drift:SetOrder(3)
        ag:SetScript("OnFinished", function() if root:IsShown() then place(s); ag:Play() end end)
        s.anim = ag
        stars[i] = s
    end
end

local function play(on)
    for i, f in ipairs(stars) do
        if on then
            place(f, (i - 1) * 0.82 / Marker.STARS)
            f.anim:Play()
        else
            f.anim:Stop()
        end
    end
    if glow then if on then glow.anim:Play() else glow.anim:Stop() end end
    if vapor then if on then vapor:Play() else vapor:Stop() end end
end

-- The stars off their plate: hidden, still, unanchored.
local function unbind()
    if bound or root:IsShown() then
        root:Hide()
        play(false)
        root:ClearAllPoints()
    end
    bound = nil
end

--------------------------------------------------------------------------------
-- The plate
--------------------------------------------------------------------------------

-- A plate's unit token, or nil.
local function unitOf(plate)
    if type(plate) ~= "table" then return nil end
    local u = text(plate.namePlateUnitToken)
    if u then return u end
    local uf = plate.UnitFrame
    return type(uf) == "table" and text(uf.unit) or nil
end

-- The stars' plate: a game object, the soft-interact target, a node known and
-- wanted. Every read secret-tested; a secret or an error: no.
local function qualifies(unit)
    if not (yes(UnitIsGameObject, unit) and yes(UnitIsUnit, unit, "softinteract")) then return false end
    local name = text(call(UnitName, unit))
    return name ~= nil and NR.Learn.Kind(name) ~= nil and NR.Alert.Wanted(name)
end

local function shownPlate(plate) return yes(plate.IsShown, plate) end

-- What should be against what is: the bound plate checked again (it's reused
-- for another unit), then a new one looked for.
function Marker.Reconcile()
    if not (NR.db and Marker.On()) or API.Gamepad() then unbind(); return end
    if bound and not (shownPlate(bound.plate) and unitOf(bound.plate) == bound.unit and qualifies(bound.unit)) then
        unbind()
    end
    if bound then return end
    local list = call(C_NamePlate.GetNamePlates)
    if type(list) ~= "table" then return end
    for _, plate in ipairs(list) do
        local unit = unitOf(plate)
        if unit and shownPlate(plate) and qualifies(unit) then
            build()
            root:ClearAllPoints()
            if pcall(root.SetPoint, root, "CENTER", plate, "BOTTOM", 0, 0) then
                bound = { unit = unit, plate = plate }
                root:Show()
                play(true)
            end
            return
        end
    end
end

--------------------------------------------------------------------------------
-- The ticker: while on, or while a claim is left to put back
--------------------------------------------------------------------------------

local driver = CreateFrame("Frame")
local since = 0
local function pending()
    return NR.db and (NR.db.softClaim or (NR.db.softCVars and next(NR.db.softCVars) ~= nil)) and true or false
end
local function pass()
    if waiting() then Marker.Reconcile(); return end
    local pad = API.Gamepad()
    if pad then
        wasPad = true
        unbind()
        return
    end
    if wasPad then
        wasPad = nil
        if Marker.On() then judge(false) end           -- Blizzard's temporary values gone: read again
    end
    if Marker.On() then
        if NR.db.softClaim and not InCombatLockdown() then claim() end
        Marker.Reconcile()
    else
        release()
    end
end
local function arm()
    local run = NR.db and (Marker.On() or pending())
    driver:SetScript("OnUpdate", run and function(_, elapsed)
        since = since + elapsed
        if since < Marker.TICK then return end
        since = 0
        pass()
        if not (Marker.On() or pending()) then driver:SetScript("OnUpdate", nil) end
    end or nil)
    if not Marker.On() then unbind() end
end

-- The setting or NodeRadar turned on or off (NR.Set, /nr reset). Inside the
-- login window the CVars wait (Codex, PR #79): on, a claim the ticker makes
-- once it's over; off, the claims the ticker puts back then. The stars follow
-- at once.
function Marker.Toggle()
    if waiting() then
        if not Marker.On() and NR.db.softCVars then
            for name, e in pairs(NR.db.softCVars) do
                if e.cancelled then
                    NR.db.softCVars[name] = nil
                    decision(name, "given up", "marker off during login wait: cancellation forgotten")
                end
            end
        end
        NR.db.softClaim = Marker.On() or nil
    elseif Marker.On() then
        claim()
    else
        release()
    end
    arm()
    Marker.Reconcile()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- #61's waypoint marker, gone (never released): the navigation option it held
-- at 1 put back if it still reads 1; its saved waypoint only dropped, since a
-- matching point isn't proof it's ours (Codex, #78).
local function migrate()
    local old = NR.db.markerCVar
    if old ~= nil then
        if get("showInGameNavigation") == "1" then call(C_CVar.SetCVar, "showInGameNavigation", old) end
        NR.db.markerCVar = nil
    end
    if NR.charDb then NR.charDb.marker = nil end
end

-- On at login: each claim read again. Never any `softCVars` (the marker on
-- since #61, or set by hand): a first turn-on, claimed now (the owner, #79:
-- no stars, nothing claimed).
local function readAtLogin()
    if not Marker.On() then return end
    if NR.db.softCVars == nil then NR.db.softClaim = true end
    judge(true)
    if NR.db.softClaim then claim() end
end

-- The login's read waits for the client's synced CVars: SETTLE seconds after
-- the first PLAYER_ENTERING_WORLD, and out of the gamepad UI. Polled only while
-- it waits, and only with something to read (or a toggle in the window).
local loginDriver = CreateFrame("Frame")
local function startRead()
    readDue = true
    loginDriver:SetScript("OnUpdate", function()
        if loggingOut or loginPhase or (settleUntil and GetTime() < settleUntil) or API.Gamepad() then return end
        loginDriver:SetScript("OnUpdate", nil)
        readDue, settleUntil = nil, nil
        readAtLogin()
        arm()
        Marker.Reconcile()
    end)
end

local events = CreateFrame("Frame")
API.RegisterEvents(events, { "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "CVAR_UPDATE",
    "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" })
events:SetScript("OnEvent", function(_, event, ...)
    if not NR.db then return end
    if event == "PLAYER_LOGIN" then
        loggingOut = nil
        migrate()
        -- A value changed while NodeRadar wasn't loaded raises no CVAR_UPDATE
        -- for us: each claim read first (Codex, #78), once the client's synced
        -- values are in and out of the gamepad UI; nothing judged till then.
        loginPhase = true
        arm()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if loginPhase then
            loginPhase, settleUntil = nil, GetTime() + Marker.SETTLE
            if Marker.On() or pending() then startRead() end
        end
    elseif event == "PLAYER_LOGOUT" then
        -- Keep claims through the queued notifications from our own restore.
        -- Login will compare the final values after the client's sync window.
        loggingOut = true
        atLogout()
    elseif event == "CVAR_UPDATE" then
        -- Someone else's change (the player, another addon): theirs stands.
        -- Ours inside put(), and anything inside the gamepad UI, never counts.
        if writing or waiting() or API.Gamepad() or not NR.db.softCVars then return end
        for name, e in pairs(NR.db.softCVars) do
            if not e.cancelled then
                local now = get(name)
                if now ~= nil and not same(now, e.ours) then
                    decision(name, "given up", "CVAR_UPDATE: current " .. tostring(now)
                        .. " differs from ours " .. tostring(e.ours))
                    NR.db.softCVars[name] = Marker.On() and { cancelled = true } or nil
                end
            end
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        Marker.Reconcile()
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        -- The bound one goes at once: Blizzard clears the plate's unit in its
        -- own handler, and the next pass or add finds the new one (Codex, #78).
        if bound and ... == bound.unit then unbind() end
    end
end)

Marker._test = {
    root = root, stars = stars, driver = driver,
    vapor = function() return vapor end,
    bound = function() return bound end,
    pass = pass, loginDriver = loginDriver,
    reset = function()                                 -- a fresh load
        bound, writing, wasPad, loginPhase, settleUntil, readDue = nil, nil, nil, nil, nil, nil
        loginPhase = true
        loggingOut = nil
        since = 0
        loginDriver:SetScript("OnUpdate", nil)
    end,
}
