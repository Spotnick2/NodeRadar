-- The marker on the node's soft-interact plate (#78, experimental; docs/PLAN.md
-- "The marker on the node's soft-interact plate"): the stars on the plate of
-- the soft-interact target when it's a node known and wanted, each condition
-- alone; the bound plate's removal and reuse; the three CVars claimed when the
-- marker is turned on, put back when it goes off, someone else's change kept
-- and never claimed again until off and on; nothing written in combat; nothing
-- judged inside the gamepad UI; logout and login; /nr reset; #61's migration.
-- Off, nothing runs.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.cvars.softTargetInteract = "1"
WoW.cvars.SoftTargetIconGameObject = "0"
WoW.cvars.SoftTargetInteractRange = "10.000000"
WoW.cvars.showInGameNavigation = "1"
-- #61's waypoint marker, left from before: its CVar to put back, its waypoint saved.
local NR = loadAddon({ db = { markerCVar = "0" }, charDb = { marker = { map = 1411, x = 0.4, y = 0.4 } } })
NR.Track.SetSmart(false)
local M = NR.Marker._test

local function frames(seconds) for _ = 1, math.floor(seconds / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end end
local function shown() return M.root._shown end
local function cv(name) return WoW.cvars[name] end
local function claims() return NR.db.softCVars or {} end
local function plate(unit) return C_NamePlate.GetNamePlateForUnit(unit) end
local function setPlates(list) WoW.plates = list; WoW.fire("NAME_PLATE_UNIT_ADDED", list[1] and list[1].unit) end
-- A login: PLAYER_LOGIN, entering the world, and the settling wait for the
-- client's synced CVars (`synced`: the values it puts back meanwhile).
local function login(synced)
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    frames(1.2)                                -- a pass or two first
    for name, v in pairs(synced or {}) do C_CVar.SetCVar(name, v) end
    frames(NR.Marker.SETTLE + 0.6)
end
local SILVERLEAF = { unit = "nameplate1", name = "Silverleaf", object = true, soft = true }
local function soft(over)
    local p = {}
    for k, v in pairs(SILVERLEAF) do p[k] = v end
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end

--------------------------------------------------------------------------------
-- #61's migration, at login
--------------------------------------------------------------------------------

eq(cv("showInGameNavigation"), "0", "#61's navigation option put back")
eq(NR.db.markerCVar, nil, "...its key gone")
eq(NR.charDb.marker, nil, "#61's saved waypoint dropped")

--------------------------------------------------------------------------------
-- Off: nothing
--------------------------------------------------------------------------------

eq(NR.db.marker, false, "off by default")
setPlates({ soft() })
frames(1)
eq(shown(), false, "off: no stars")
eq(M.driver._scripts.OnUpdate, nil, "...nothing per frame")
eq(M.loginDriver._scripts.OnUpdate, nil, "...nor waiting for a login read")
eq(cv("softTargetInteract"), "1", "...the CVars untouched")
eq(next(claims()), nil, "...nothing claimed")
frames(NR.Marker.SETTLE)                                   -- past the login window

--------------------------------------------------------------------------------
-- On: the CVars claimed, the stars on the soft target's plate
--------------------------------------------------------------------------------

WoW.cvars.SoftTargetIconGameObject = "1"                   -- already as ours: the player's, not claimed
NR.Set("marker", true)
eq(cv("softTargetInteract"), "3", "on: interact targeting always on")
eq(cv("SoftTargetInteractRange"), "60", "...its range past 10")
eq(claims().softTargetInteract and claims().softTargetInteract.old, "1", "...the old value kept")
eq(claims().SoftTargetInteractRange and claims().SoftTargetInteractRange.old, "10.000000", "...as it read")
eq(claims().SoftTargetIconGameObject, nil, "...one already as ours not claimed")
eq(shown(), true, "the soft target's plate, a node known and wanted: the stars")
local p1 = plate("nameplate1")
check(M.root._points[1] and M.root._points[1][1] == "CENTER" and M.root._points[1][2] == p1
    and M.root._points[1][3] == "BOTTOM", "...on the plate's bottom")
eq(M.root._parent, UIParent, "...a child of UIParent, never of Blizzard's plate")
eq(M.stars[1].anim._playing, true, "...twinkling")
for _, w in ipairs(M.vapor().wisps) do eq(w.anim._playing, true, "nearby vapor starts with the stars") end
check(M.driver._scripts.OnUpdate ~= nil, "...the ticker on")

-- Each condition alone.
for _, case in ipairs({
    { { object = false }, "not a game object" },
    { { soft = false }, "not the soft-interact target" },
    { { name = "Mailbox" }, "a name NodeRadar doesn't know" },
    { { name = WoW.Secret("name") }, "a secret name" },
}) do
    setPlates({ soft(case[1]) })
    frames(0.6)
    eq(shown(), false, case[2] .. ": no stars")
    setPlates({ soft() })
    frames(0.6)
    eq(shown(), true, "...the node again: the stars")
end

-- Wanted: a skip, within a tick.
NR.Track.Set(765, false)
frames(0.6)
eq(shown(), false, "Silverleaf skipped: the stars off within a tick")
NR.Track.Set(765, true)
frames(0.6)
eq(shown(), true, "...followed again: back")

-- The bound plate's removal: hidden at once, before any pass.
WoW.plates = {}
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
eq(shown(), false, "the plate removed: hidden at once")
eq(M.bound(), nil, "...unbound")
eq(M.stars[1].anim._playing, false, "...the animations stopped")
for _, w in ipairs(M.vapor().wisps) do
    eq(w.anim._playing, false, "plate removal stops vapor")
    w.anim._scripts.OnFinished()
    eq(w.anim._playing, false, "a late vapor completion cannot restart a hidden marker")
end
eq(#M.root._points, 0, "...the anchor cleared")
-- Another unit's removal leaves ours.
setPlates({ soft() })
eq(shown(), true, "a new plate added: the stars at once")
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate7")
eq(shown(), true, "another unit's plate removed: ours stays")
-- The plate frame reused for another unit: the next pass lets it go.
p1.namePlateUnitToken = "nameplate9"
frames(0.6)
eq(shown(), false, "its plate reused for another unit: unbound")
p1.namePlateUnitToken = "nameplate1"
frames(0.6)
eq(shown(), true, "...the node's again: back")

--------------------------------------------------------------------------------
-- Someone else's change: theirs stands, never claimed again until off and on
--------------------------------------------------------------------------------

C_CVar.SetCVar("SoftTargetInteractRange", "25")            -- the player's own (fires CVAR_UPDATE)
eq(claims().SoftTargetInteractRange and claims().SoftTargetInteractRange.cancelled, true, "the player's change: cancelled")
frames(2)
eq(cv("SoftTargetInteractRange"), "25", "...never claimed again by the passes")
NR.Set("marker", false)
eq(cv("softTargetInteract"), "1", "off: ours put back")
eq(cv("SoftTargetInteractRange"), "25", "...the player's change kept")
eq(next(claims()), nil, "...nothing left")
eq(shown(), false, "...no stars")
frames(1)
eq(M.driver._scripts.OnUpdate, nil, "...the ticker stopped")
NR.Set("marker", true)
eq(claims().SoftTargetInteractRange and claims().SoftTargetInteractRange.old, "25", "off and on: claimed afresh, 25 kept to put back")

--------------------------------------------------------------------------------
-- Combat: nothing written
--------------------------------------------------------------------------------

WoW.combat = true
NR.Set("marker", false)
eq(cv("softTargetInteract"), "3", "off in combat: nothing written yet")
check(next(claims()) ~= nil, "...the claims kept")
frames(1)
eq(cv("softTargetInteract"), "3", "...still in combat")
WoW.combat = false
frames(0.6)
eq(cv("softTargetInteract"), "1", "...out of combat: put back")
eq(cv("SoftTargetInteractRange"), "25", "...each one")
eq(next(claims()), nil, "...nothing left")
frames(1)
eq(M.driver._scripts.OnUpdate, nil, "...the ticker stopped")
WoW.combat = true
NR.Set("marker", true)
eq(cv("softTargetInteract"), "1", "on in combat: nothing set")
eq(NR.db.softClaim, true, "...the claim waiting")
WoW.combat = false
frames(0.6)
eq(cv("softTargetInteract"), "3", "...out of combat: claimed")
eq(NR.db.softClaim, nil, "...done")

--------------------------------------------------------------------------------
-- The gamepad UI: nothing judged while it's on
--------------------------------------------------------------------------------

WoW.gamepadUI = true
frames(0.6)
eq(shown(), false, "the gamepad UI: no stars")
C_CVar.SetCVar("softTargetInteract", "1")                  -- Blizzard's temporary value
frames(1)
eq(claims().softTargetInteract and claims().softTargetInteract.ours, "3", "...its temporary value never cancels")
C_CVar.SetCVar("softTargetInteract", "3")                  -- removed: ours under it again
WoW.gamepadUI = false
frames(0.6)
eq(claims().softTargetInteract and claims().softTargetInteract.ours, "3", "out of it, ours under it: kept")
eq(shown(), true, "...the stars back")
-- Off inside the gamepad UI: put back once out.
WoW.gamepadUI = true
frames(0.6)
NR.Set("marker", false)
eq(cv("softTargetInteract"), "3", "off inside the gamepad UI: nothing written")
WoW.cvars.SoftTargetInteractRange = "30"                   -- someone's, under it, no event seen
WoW.gamepadUI = false
frames(0.6)
eq(cv("softTargetInteract"), "1", "...out of it: put back")
eq(cv("SoftTargetInteractRange"), "30", "...one no longer ours left alone")
eq(next(claims()), nil, "...nothing left")
WoW.cvars.SoftTargetInteractRange = "25"                   -- the player's, as before
-- Out of it, a value that isn't ours: someone else's, cancelled.
NR.Set("marker", true)
WoW.gamepadUI = true
frames(0.6)
WoW.cvars.SoftTargetInteractRange = "40"                   -- changed under it
WoW.gamepadUI = false
frames(0.6)
eq(claims().SoftTargetInteractRange and claims().SoftTargetInteractRange.cancelled, true,
    "out of it, a value not ours: cancelled")

--------------------------------------------------------------------------------
-- Logout and login, the claims kept
--------------------------------------------------------------------------------

-- A failed or unreadable off-time restore keeps its original and retries.
-- An unrelated CVar notification must not erase an unreadable pending claim.
for _, mode in ipairs({ "unreadable", "rejected", "unconfirmed" }) do
    NR.Set("marker", false)
    local name = "softTargetInteract"
    WoW.cvars[name] = "1"
    NR.Set("marker", true)
    local original = claims()[name].old
    local getCVar, setCVar = C_CVar.GetCVar, C_CVar.SetCVar
    local unreadable = mode == "unreadable"
    C_CVar.GetCVar = function(key)
        if key == name and unreadable then return nil end
        return getCVar(key)
    end
    C_CVar.SetCVar = function(key, value)
        if key == name and value == original then
            if mode == "rejected" then return false end
            local result = setCVar(key, value)
            if mode == "unconfirmed" then unreadable = true end
            return result
        end
        return setCVar(key, value)
    end
    NR.Set("marker", false)
    eq(claims()[name] and claims()[name].old, original, mode .. ": original retained after off")
    check(M.driver._scripts.OnUpdate ~= nil, mode .. ": cleanup ticker stays armed")
    WoW.fire("CVAR_UPDATE", "unrelatedSetting", "1")
    frames(0.6)
    eq(claims()[name] and claims()[name].old, original, mode .. ": pending restore survives notifications and retries")
    C_CVar.GetCVar, C_CVar.SetCVar = getCVar, setCVar
    frames(0.6)
    eq(cv(name), original, mode .. ": player's value confirmed on retry")
    eq(next(claims()), nil, mode .. ": confirmed cleanup drops claims")
    eq(M.driver._scripts.OnUpdate, nil, mode .. ": no idle ticker after cleanup")
end

-- Turning back on before a deferred restore retries must reconcile its claim.
WoW.cvars.softTargetInteract = "1"
NR.Set("marker", true)
local old = claims().softTargetInteract.old
local realGet = C_CVar.GetCVar
local unreadable = false
C_CVar.GetCVar = function(name)
    if name == "softTargetInteract" and unreadable then return nil end
    return realGet(name)
end
local realSet = C_CVar.SetCVar
C_CVar.SetCVar = function(name, value)
    local result = realSet(name, value)
    if name == "softTargetInteract" and value == old then unreadable = true end
    return result
end
NR.Set("marker", false)
eq(cv("softTargetInteract"), old, "quick toggle: off writes the original")
eq(claims().softTargetInteract.old, old, "quick toggle: unconfirmed restore retains ownership")
C_CVar.GetCVar, C_CVar.SetCVar = realGet, realSet
NR.Set("marker", true)
eq(cv("softTargetInteract"), "3", "quick toggle: on reapplies the interact value")
eq(claims().softTargetInteract.old, old, "quick toggle: original survives reapply")
eq(NR.db.softClaim, nil, "quick toggle: reapply is confirmed")
NR.Set("marker", false)
eq(cv("softTargetInteract"), old, "quick toggle: later off restores original")
eq(next(claims()), nil, "quick toggle: no claim left after confirmed restore")

-- A temporarily unreadable retained claim waits, then reapplies on the ticker.
NR.Set("marker", true)
C_CVar.GetCVar = function(name)
    if name == "softTargetInteract" then return nil end
    return realGet(name)
end
NR.Set("marker", false)
NR.Set("marker", true)
eq(claims().softTargetInteract.old, old, "unreadable on re-enable: original retained")
eq(NR.db.softClaim, true, "unreadable on re-enable: retry armed")
C_CVar.GetCVar = realGet
frames(0.6)
eq(cv("softTargetInteract"), "3", "readable retry reapplies interact value")
eq(NR.db.softClaim, nil, "readable retry clears pending claim")
NR.Set("marker", false)
eq(cv("softTargetInteract"), old, "readable retry: later off restores original")

-- A readable third-party value ends ownership rather than being overwritten.
NR.Set("marker", true)
C_CVar.GetCVar = function(name)
    if name == "softTargetInteract" then return nil end
    return realGet(name)
end
NR.Set("marker", false)
C_CVar.GetCVar = realGet
WoW.cvars.softTargetInteract = "2"
NR.Set("marker", true)
eq(cv("softTargetInteract"), "2", "quick toggle: external value left alone")
eq(claims().softTargetInteract and claims().softTargetInteract.cancelled, true,
    "quick toggle: external value cancels saved ownership")
NR.Set("marker", false)
eq(next(claims()), nil, "quick toggle: off forgets cancellation")
WoW.cvars.softTargetInteract = old

NR.Set("marker", false)
WoW.cvars.SoftTargetIconGameObject = "0"
NR.Set("marker", true)
WoW.fire("PLAYER_LOGOUT")
eq(cv("softTargetInteract"), "1", "logout: ours put back, best effort")
check(claims().softTargetInteract ~= nil, "...the claim kept")
-- The client queues these until after SetCVar returns (run #481, 70450).
for _, entry in ipairs(NR.Marker.CVARS) do
    WoW.fire("CVAR_UPDATE", entry[1], cv(entry[1]))
end
frames(0.6)
for _, entry in ipairs(NR.Marker.CVARS) do
    eq(claims()[entry[1]] and claims()[entry[1]].ours, entry[2],
        "logout's delayed notification retains " .. entry[1])
end
M.reset()
-- The next load receives synced CVar events before PLAYER_LOGIN (#496).
for _, entry in ipairs(NR.Marker.CVARS) do
    WoW.fire("CVAR_UPDATE", entry[1], cv(entry[1]))
    eq(claims()[entry[1]] and claims()[entry[1]].ours, entry[2],
        "before PLAYER_LOGIN: retains " .. entry[1])
end
login()
eq(cv("softTargetInteract"), "3", "login, the restore stuck: ours again")
-- The restore didn't stick: ours read at login, kept.
WoW.fire("PLAYER_LOGOUT")
WoW.cvars.softTargetInteract = "3"
M.reset()
login()
eq(claims().softTargetInteract and claims().softTargetInteract.ours, "3", "login, ours still there: kept")
-- Changed while NodeRadar wasn't loaded: theirs, cancelled, never claimed again.
WoW.fire("PLAYER_LOGOUT")
WoW.cvars.softTargetInteract = "2"
M.reset()
login()
eq(cv("softTargetInteract"), "2", "login, changed while unloaded: left alone")
eq(claims().softTargetInteract and claims().softTargetInteract.cancelled, true, "...cancelled")
frames(2)
eq(cv("softTargetInteract"), "2", "...and after the passes")
-- A login inside the gamepad UI: every claim kept until it ends.
NR.Set("marker", false)
NR.Set("marker", true)
WoW.fire("PLAYER_LOGOUT")
WoW.gamepadUI = true
WoW.cvars.SoftTargetInteractRange = "20"                   -- Blizzard's temporary value
M.reset()
login()
check(claims().SoftTargetInteractRange and not claims().SoftTargetInteractRange.cancelled, "login inside the gamepad UI: kept")
check(M.loginDriver._scripts.OnUpdate ~= nil, "...its read waiting")
WoW.cvars.SoftTargetInteractRange = claims().SoftTargetInteractRange.old   -- out: the logout's restore under it
WoW.gamepadUI = false
frames(0.6)
eq(cv("SoftTargetInteractRange"), "60", "...out of it: read, ours set again")
eq(M.loginDriver._scripts.OnUpdate, nil, "...the wait over")
-- Off at login, claims left from before: put back.
local old = claims().softTargetInteract.old
WoW.fire("PLAYER_LOGOUT")
NR.db.marker = false
WoW.cvars.softTargetInteract = "3"                         -- the logout's restore didn't stick
M.reset()
login({ softTargetInteract = "3" })                        -- the client's synced value: ours, after the login
frames(0.6)
eq(cv("softTargetInteract"), old, "off at login, a claim left: put back")
eq(next(claims()), nil, "...nothing left")
frames(1)
eq(M.driver._scripts.OnUpdate, nil, "...the ticker stopped")

--------------------------------------------------------------------------------
-- /nr reset, NodeRadar off
--------------------------------------------------------------------------------

WoW.cvars.softTargetInteract = "1"                         -- the player's own again
NR.Set("marker", true)
eq(cv("softTargetInteract"), "3", "on again")
SlashCmdList.NODERADAR("reset")
eq(NR.db.marker, false, "/nr reset: the marker off")
eq(cv("softTargetInteract"), "1", "...ours put back")
NR.Set("marker", true)
NR.Set("enabled", false)
eq(cv("softTargetInteract"), "1", "NodeRadar off: ours put back")
eq(shown(), false, "...no stars")
NR.Set("enabled", true)
eq(cv("softTargetInteract"), "3", "...on again: claimed")

-- The client's synced values arriving after PLAYER_LOGIN (the owner's run,
-- #79): never taken as someone else's; ours set again once they're in.
NR.Set("marker", false)
WoW.cvars.softTargetInteract, WoW.cvars.SoftTargetInteractRange = "1", "10.000000"
NR.Set("marker", true)
WoW.fire("PLAYER_LOGOUT")
M.reset()
login({ softTargetInteract = "1", SoftTargetInteractRange = "10.000000" })
eq(claims().softTargetInteract and claims().softTargetInteract.cancelled, nil, "synced values after login: not cancelled")
eq(cv("softTargetInteract"), "3", "...ours set again once they're in")
eq(cv("SoftTargetInteractRange"), "60", "...each one")
eq(M.loginDriver._scripts.OnUpdate, nil, "...the wait over")
-- Settling, only with something to read: off, nothing claimed, no wait.
NR.Set("marker", false)
M.reset()
WoW.fire("PLAYER_LOGIN")
WoW.fire("PLAYER_ENTERING_WORLD", true, false)
eq(M.loginDriver._scripts.OnUpdate, nil, "off, nothing claimed: no settling wait")

-- Toggled inside the login window (Codex, PR #79): the CVars wait for its read.
-- On, the marker off at login: nothing written before the client's values are in.
NR.Set("marker", false)
WoW.cvars.softTargetInteract = "1"
M.reset()
WoW.fire("PLAYER_LOGIN")
WoW.fire("PLAYER_ENTERING_WORLD", true, false)
eq(M.loginDriver._scripts.OnUpdate, nil, "off at login, nothing claimed: no wait")
NR.Set("marker", true)
eq(cv("softTargetInteract"), "1", "on inside the window: nothing written yet")
setPlates({ soft() })
frames(1)
C_CVar.SetCVar("softTargetInteract", "1")                  -- the client's synced value
frames(NR.Marker.SETTLE)
eq(cv("softTargetInteract"), "3", "...claimed once the window is over")
eq(claims().softTargetInteract and claims().softTargetInteract.old, "1", "...the synced value kept to put back")
-- Off inside the window, claims left: put back once it's over, after the sync.
WoW.fire("PLAYER_LOGOUT")
WoW.cvars.softTargetInteract = "3"                         -- the logout's restore didn't stick
M.reset()
WoW.fire("PLAYER_LOGIN")
WoW.fire("PLAYER_ENTERING_WORLD", true, false)
NR.Set("marker", false)
eq(shown(), false, "off inside the window: the stars hidden at once")
eq(cv("softTargetInteract"), "3", "...the CVars wait")
check(claims().softTargetInteract ~= nil, "...the claim kept")
frames(1.2)
C_CVar.SetCVar("softTargetInteract", "3")                  -- the client's synced value: ours
frames(NR.Marker.SETTLE + 0.6)
eq(cv("softTargetInteract"), "1", "...put back once it's over")
eq(next(claims()), nil, "...nothing left")

-- On since #61, nothing ever claimed (the owner, #79): a first turn-on at login.
NR.Set("marker", false)
WoW.cvars.softTargetInteract = "1"
NR.db.marker, NR.db.softCVars = true, nil
M.reset()
login()
eq(cv("softTargetInteract"), "3", "on from before, never claimed: claimed at login")
eq(claims().softTargetInteract and claims().softTargetInteract.old, "1", "...the old value kept")
setPlates({ soft() })
frames(0.6)
eq(shown(), true, "...the stars")
-- Claimed already, all of them cancelled: a login claims nothing again.
NR.db.softCVars = { softTargetInteract = { cancelled = true } }
WoW.cvars.softTargetInteract = "2"
M.reset()
login()
eq(cv("softTargetInteract"), "2", "a claim cancelled before: not taken at login")
local skipped
for _, line in ipairs(NR.Marker.Decisions or {}) do
    if line:find("softTargetInteract: claim skipped; prior cancellation") then skipped = true end
end
check(skipped, "the login note explains why the cancelled claim had no write")

-- Off then on during the next login window starts a fresh claim. Discarding
-- the cancellation on the off toggle needs no CVar write.
M.reset()
WoW.fire("PLAYER_LOGIN")
WoW.fire("PLAYER_ENTERING_WORLD", true, false)
NR.Set("marker", false)
eq(claims().softTargetInteract, nil, "off in the window: the cancelled claim forgotten")
NR.Set("marker", true)
eq(cv("softTargetInteract"), "2", "on in the window: no early CVar write")
frames(NR.Marker.SETTLE + 0.6)
eq(cv("softTargetInteract"), "3", "after the window: claimed again")
eq(claims().softTargetInteract and claims().softTargetInteract.old, "2", "...the current value kept to restore")
C_CVar.SetCVar("softTargetInteract", "2")                  -- another change, with its reason recorded

local decisions = NR.Marker.Decisions or {}
local function decisionHas(pattern)
    for _, line in ipairs(decisions) do if line:find(pattern) then return true end end
end
check(decisionHas("softTargetInteract: claimed"), "decisions record a claim")
check(decisionHas("softTargetInteract: put back"), "decisions record a restore")
check(decisionHas("softTargetInteract: given up"), "decisions record why a claim was cancelled")
check(decisionHas("softTargetInteract: given up; CVAR_UPDATE"), "a CVar change names its cause")

checkMethods({ "AnimationGroup:SetLooping", "Alpha:SetFromAlpha", "Alpha:SetToAlpha", "Scale:SetScaleFrom",
    "Scale:SetScaleTo", "Alpha:SetStartDelay", "Alpha:SetSmoothing", "Scale:SetSmoothing",
    "Translation:SetOffset", "Translation:SetDuration", "Translation:SetOrder", "Texture:SetBlendMode",
    "Frame:IsShown", "Texture:SetRotation" })
done("test_marker")
