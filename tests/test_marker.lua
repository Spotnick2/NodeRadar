-- The marker in the world (#61, experimental; docs/PLAN.md "A marker in the
-- world"): the compass's node, our user waypoint on it read back before it's
-- super-tracked, the stars on the navigation frame after a settling interval
-- and while the distances agree; stepping aside for the player's waypoint, a
-- quest, a contested set, a half-cleared state; nothing written in combat or
-- with the map open; logout's clear and login's adoption; the CVar held and
-- put back. Off, nothing runs.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.Track.SetSmart(false)
local Icons, Compass, Marker = NR.Icons, NR.Compass, NR.Marker
local M, C, T = Marker._test, Compass._test, Icons._test

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y)                            -- at map offset (x, y) from the player now
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    nodes[#nodes + 1] = n
    return n
end
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        if not n.gone then
            list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
        end
    end
    WoW.blips = list
end
local function step(dt)
    WoW.now = WoW.now + (dt or 1)
    place()
    NR.Step(WoW.now)
end
local function frames(seconds) for _ = 1, math.floor(seconds / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6) end
local function yards(n) return math.sqrt((n.north - WoW.pos[1]) ^ 2 + (n.west - WoW.pos[2]) ^ 2) end
-- The map point a node should get: the player's spot plus its offset in yards.
local function mapOf(n)
    return 0.5 + (WoW.pos[2] - n.west) / WoW.mapSize[1], 0.5 - (n.north - WoW.pos[1]) / WoW.mapSize[2]
end
local function onNode(n)
    local w = WoW.waypoint
    local x, y = mapOf(n)
    -- within a yard: a record is the node as measured
    return w ~= nil and w.map == 1411 and near(w.x, x, 1 / WoW.mapSize[1]) and near(w.y, y, 1 / WoW.mapSize[2])
end
local function shown() return M.root._shown end
local function fresh()
    nodes = {}
    Icons.Clear()
    WoW.pos = { 0, 0, 1 }
    WoW.combat, WoW.worldMapShown, WoW.onTaxi, WoW.navClamped = false, false, false, false
    step(1)
end
-- The navigation agreeing with our distance to n, then the settling interval past.
local function settle(n)
    WoW.navDistance = yards(n)
    frames(0.5)
end

--------------------------------------------------------------------------------
-- Off: nothing
--------------------------------------------------------------------------------

eq(NR.db.marker, false, "off by default")
fresh()
node("Silverleaf", 0, 40)
step(1)
eq(WoW.waypoint, nil, "off: no waypoint")
eq(WoW.cvars.showInGameNavigation, "0", "...the CVar untouched")
eq(M.driver._scripts.OnUpdate, nil, "...nothing per frame")
check(M.root._parent == UIParent and M.root._mouse == false, "the stars: a child of UIParent, no mouse")

--------------------------------------------------------------------------------
-- On: the compass's node, its waypoint, the stars
--------------------------------------------------------------------------------

NR.Set("marker", true)
eq(WoW.cvars.showInGameNavigation, "1", "on: Blizzard's navigation on")
eq(NR.db.markerCVar, "0", "...its old value kept to put back")
fresh()
local a = node("Silverleaf", 0, 40)
step(1)
check(Compass.Chosen() and near(Compass.Chosen().north, a.north, 1), "the compass off: the node chosen still")
eq(C.root._shown, false, "...its ring not shown")
check(onNode(a), "the waypoint on the node's map point")
eq(WoW.superTracked, "waypoint", "...super-tracked")
check(NR.charDb.marker and near(NR.charDb.marker.x, WoW.waypoint.x), "...saved as ours")
eq(shown(), false, "right after: the stars wait for the settling interval")
settle(a)
eq(shown(), true, "settled, the distances agreeing: the stars on the node")
check(M.root._points[1] and M.root._points[1][2] == WoW.navFrame, "...anchored to the navigation frame")
eq(M.stars[1].anim._playing, true, "...twinkling")
local calls = 0
local real = C_Map.SetUserWaypoint
C_Map.SetUserWaypoint = function(...) calls = calls + 1; return real(...) end
step(1); step(1)
eq(calls, 0, "the same node: no waypoint call again")

-- The navigation stale, clamped, near, on a taxi: hidden; back when it's right.
WoW.navDistance = yards(a) + 50
frames(0.3)
eq(shown(), false, "the navigation's distance off by 50: hidden")
eq(M.stars[1].anim._playing, false, "...the animations stopped")
settle(a)
eq(shown(), true, "...agreeing again: shown")
WoW.navClamped = true
frames(0.2)
eq(shown(), false, "behind (clamped at the screen's edge): hidden")
WoW.navClamped = false
frames(0.2)
eq(shown(), true, "...turned toward it: shown, no sweep needed")
WoW.onTaxi = true
frames(0.2)
eq(shown(), false, "on a taxi: hidden")
WoW.onTaxi = false
WoW.pos[1] = a.north - 10                                  -- 10 yards off
settle(a)
eq(shown(), false, "within 15 yards: hidden (Lueur's glow)")
WoW.pos[1] = 0
settle(a)

-- Another node as far, in another direction (the first snoozed, so it goes at
-- once): hidden through the settling interval.
local b = node("Silverleaf", 0, -40)
step(1)
Compass.Snooze("session", Compass.Chosen())
step(1)
check(onNode(b), "the target changed: the waypoint moved")
WoW.navDistance = yards(b)
frames(0.1)
eq(shown(), false, "as far, another way: hidden while it settles")
frames(0.4)
eq(shown(), true, "...then shown")
C_Map.SetUserWaypoint = real

--------------------------------------------------------------------------------
-- Stepping aside
--------------------------------------------------------------------------------

-- The player's own waypoint, as the world map sets it (Ctrl-click: the point,
-- then its super-track off; WaypointLocationDataProvider): theirs, kept.
C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1411, 0.2, 0.3))
C_SuperTrack.SetSuperTrackedUserWaypoint(false)
eq(NR.charDb.marker, nil, "the player's waypoint: ours forgotten")
step(1); step(1)
check(WoW.waypoint and WoW.waypoint.x == 0.2, "...theirs never replaced")
frames(0.2)
eq(shown(), false, "...no stars")
C_Map.ClearUserWaypoint()                                  -- their pin clicked off, as the map does
C_SuperTrack.SetSuperTrackedUserWaypoint(false)
step(1)
check(onNode(b), "theirs cleared, the same node: ours again")

-- A quest super-tracked: our waypoint cleared, the quest left alone.
WoW.SetSuperTracked("quest")
check(WoW.waypoint == nil and WoW.superTracked == "quest", "a quest tracked: our waypoint cleared, the quest kept")
step(1)
eq(WoW.waypoint, nil, "...nothing set while it's tracked")
WoW.SetSuperTracked(nil)
step(1)
check(onNode(b) and WoW.superTracked == "waypoint", "...the quest untracked: ours again")

-- A half-cleared state that isn't ours: left alone, blocking.
local order = {}
local realClear, realTrack = C_Map.ClearUserWaypoint, C_SuperTrack.SetSuperTrackedUserWaypoint
C_Map.ClearUserWaypoint = function() order[#order + 1] = "waypoint"; return realClear() end
C_SuperTrack.SetSuperTrackedUserWaypoint = function(on) order[#order + 1] = "track"; return realTrack(on) end
NR.Set("marker", false)
C_Map.ClearUserWaypoint, C_SuperTrack.SetSuperTrackedUserWaypoint = realClear, realTrack
eq(WoW.waypoint, nil, "off: ours cleared")
eq(table.concat(order, " "), "track waypoint", "...its super-track first, then the waypoint")
eq(WoW.superTracked, nil, "...both gone")
WoW.superTracked = "waypoint"                              -- someone cleared their waypoint before its track
NR.Set("marker", true)
step(1); step(1)
eq(WoW.waypoint, nil, "a half-cleared state not ours: nothing set")
eq(WoW.superTracked, "waypoint", "...and nothing repaired")
WoW.superTracked = nil
step(1)
check(onNode(b), "...cleared by them: ours")

-- A set contested inside our call: not ours, not super-tracked.
NR.Set("marker", false)
local rival = CreateFrame("Frame")
rival:RegisterEvent("USER_WAYPOINT_UPDATED")
local answered
rival:SetScript("OnEvent", function()
    if answered then return end
    answered = true
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1411, 0.9, 0.9))
end)
NR.Set("marker", true)
step(1)
check(WoW.waypoint and WoW.waypoint.x == 0.9, "another addon's point inside our call: kept")
eq(M.ours(), nil, "...not taken for ours")
eq(WoW.superTracked, nil, "...not super-tracked by us")
rival:UnregisterEvent("USER_WAYPOINT_UPDATED")
C_Map.ClearUserWaypoint()
step(1)
check(onNode(b), "...theirs gone: ours")

-- A clear checked again when it happens: replaced unseen, theirs is left.
WoW.waypoint = { map = 1411, x = 0.4, y = 0.4 }            -- no event
NR.Set("marker", false)
check(WoW.waypoint and WoW.waypoint.x == 0.4, "replaced unseen, then off: their waypoint untouched")
WoW.waypoint, WoW.superTracked = nil, nil
NR.Set("marker", true)
step(1)
check(onNode(b), "ours again")
WoW.waypoint = { map = 1411, x = 0.4, y = 0.4 }            -- replaced unseen, then a logout
WoW.fire("PLAYER_LOGOUT")
check(WoW.waypoint and WoW.waypoint.x == 0.4, "...at logout too: theirs untouched")
eq(WoW.superTracked, "waypoint", "...its super-track too (the user waypoint's, theirs now)")
WoW.waypoint, WoW.superTracked = nil, nil
step(1)
check(onNode(b), "ours again")
-- Another addon answering our super-track's change with its own waypoint, in
-- the middle of our clear: the waypoint checked again before it's cleared.
rival:RegisterEvent("SUPER_TRACKING_CHANGED")
answered = nil
NR.Set("marker", false)
rival:UnregisterEvent("SUPER_TRACKING_CHANGED")
check(WoW.waypoint and WoW.waypoint.x == 0.9, "theirs set in the middle of our clear: left")
WoW.waypoint, WoW.superTracked = nil, nil
NR.Set("marker", true)
step(1)

--------------------------------------------------------------------------------
-- Combat and the world map: nothing written meanwhile
--------------------------------------------------------------------------------

check(onNode(b), "ready")
b.gone = true
local c = node("Silverleaf", 30, 0)
WoW.combat = true
step(1)
check(onNode(b), "in combat: the waypoint not moved")
frames(0.2)
eq(shown(), false, "...the stars hidden meanwhile (not on the target)")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
check(onNode(c), "...out of combat: moved")
c.gone = true
local d = node("Silverleaf", -20, 0)
WoW.worldMapShown = true
step(1)
check(onNode(c), "the world map open: not moved")
WoW.worldMapShown = false
step(1)
check(onNode(d), "...closed: the next sweep moves it")

-- No node: cleared (a record goes after two sweeps without its blip).
d.gone = true
step(1); step(1)
eq(WoW.waypoint, nil, "no node: no waypoint")
eq(WoW.superTracked, nil, "...no super-track")
local e = node("Silverleaf", 0, 50)
step(1)

--------------------------------------------------------------------------------
-- The navigation frame's life
--------------------------------------------------------------------------------

settle(e)
eq(shown(), true, "shown")
WoW.fire("NAVIGATION_FRAME_DESTROYED")
eq(M.nav(), nil, "the frame destroyed: dropped")
eq(shown(), false, "...the stars hidden")
eq(M.driver._scripts.OnUpdate, nil, "...nothing per frame")
WoW.fire("NAVIGATION_FRAME_CREATED")
settle(e)
eq(shown(), true, "...created again: shown")

--------------------------------------------------------------------------------
-- Logout and login
--------------------------------------------------------------------------------

WoW.fire("PLAYER_LOGOUT")
eq(WoW.waypoint, nil, "logout: ours cleared (a reload sets it again)")
eq(NR.charDb.marker, nil, "...nothing saved as ours")
step(1)
check(onNode(e), "...and set again")
WoW.combat = true
WoW.fire("PLAYER_LOGOUT")
check(onNode(e) and NR.charDb.marker, "a reload in combat: not cleared, still saved as ours")
WoW.combat = false
-- The next load: ours only if it's the saved one.
local saved = NR.charDb.marker
M.reset()
WoW.fire("PLAYER_LOGIN")
check(M.ours() and near(M.ours().x, saved.x), "login: the saved waypoint adopted")
M.reset()
NR.charDb.marker = { map = 1411, x = saved.x + 0.01, y = saved.y }
WoW.fire("PLAYER_LOGIN")
eq(M.ours(), nil, "login: a waypoint not the saved one isn't ours")
eq(NR.charDb.marker, nil, "...the saved one dropped")
check(onNode(e), "...and left where it is")
NR.charDb.marker = { map = saved.map, x = saved.x, y = saved.y }
NR.db.marker = false                                       -- the setting off at the next load
M.reset()
WoW.fire("PLAYER_LOGIN")
eq(WoW.waypoint, nil, "login with the marker off: the adopted waypoint cleared")
NR.Set("marker", true)

--------------------------------------------------------------------------------
-- The CVar, and NodeRadar off
--------------------------------------------------------------------------------

NR.Set("marker", false)
eq(WoW.cvars.showInGameNavigation, "0", "off: the CVar put back")
eq(NR.db.markerCVar, nil, "...nothing pending")
NR.Set("marker", true)
C_CVar.SetCVar("showInGameNavigation", "0")                -- the player's change
C_CVar.SetCVar("showInGameNavigation", "1")
NR.Set("marker", false)
eq(WoW.cvars.showInGameNavigation, "1", "changed by someone else meanwhile: theirs stands")
NR.Set("marker", true)
eq(NR.db.markerCVar, nil, "already 1: nothing to put back")
step(1)
check(onNode(e), "on again")
NR.Set("enabled", false)
eq(WoW.waypoint, nil, "NodeRadar off: ours cleared")
NR.Set("enabled", true)

-- Every widget method called exists on Forever (the dump), the animation's among them.
checkMethods({ "AnimationGroup:SetLooping", "Alpha:SetFromAlpha", "Alpha:SetToAlpha", "Scale:SetScaleFrom",
    "Scale:SetScaleTo", "Alpha:SetStartDelay", "Texture:SetBlendMode", "Frame:SetScale" })
done("test_marker")
