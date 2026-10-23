-- The distant beacon: real scanner/selector integration, waypoint ownership,
-- deferred cleanup, startup, and the handoff to exact object-plate sparkles.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.LIBRARY.enUS.Peacebloom = "herbs"
NR.Track.SetSmart(false)
local F, M = NR.FarMarker, NR.FarMarker._test
local function frames(seconds)
    for _ = 1, math.floor(seconds / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end
end
local function step()
    WoW.blips = { { "Silverleaf", 0, 20, kind = "herbs" } }
    NR.Step(WoW.now)
end
local function distance()
    local r = NR.Compass.Chosen()
    return r and math.sqrt((r.north - WoW.pos[1]) ^ 2 + (r.west - WoW.pos[2]) ^ 2)
end
local function settle()
    WoW.navDistance = distance()
    frames(0.6)
end
local function shown() return M.root._shown end
local function restart()
    NR.Set("marker", false)
    NR.Set("marker", true)
    step(); settle()
end
local function keepPoint()
    local p = WoW.waypoint
    return { map = p.map, x = p.x, y = p.y }
end

NR.Set("marker", true)
step(); frames(1)
eq(WoW.waypoint, nil, "startup: no navigation claimed before sync settles")
eq(WoW.cvars.showInGameNavigation, "0", "startup: navigation CVar untouched")
frames(NR.Marker.SETTLE)
step(); settle()
check(NR.Compass.Chosen() ~= nil, "marker alone keeps records and chooses a node")
eq(NR.Compass._test.root._shown, false, "marker alone leaves compass ring hidden")
eq(WoW.superTracked, "waypoint", "our node tracked")
check(M.ours() and NR.charDb.farMarker, "ownership saved")
eq(shown(), true, "beacon shown after navigation settles")
eq(M.root._points[1][2], WoW.navFrame, "beacon follows the camera through navigation anchor")
check(M.label()._text:find("Silverleaf", 1, true), "node named")
eq(M.label()._text, "Silverleaf", "name only: no duplicate distance readout")
eq(M.root._parent, UIParent, "beacon belongs to our UIParent frame")
eq(M.root._mouse, false, "beacon passes clicks through")
-- The art gets smaller and fades away, then frees the waypoint slot entirely.
local startPos = WoW.pos
local chosen = NR.Compass.Chosen()
local previousScale, previousAlpha
Minimap:Hide()
for _, yards in ipairs({ 20, 35, 50, 59 }) do
    WoW.pos = { chosen.north - yards, chosen.west, 1 }
    WoW.navDistance = yards
    frames(0.1)
    eq(shown(), true, yards .. " yards: beacon remains visible")
    local scale, alpha = M.art():GetScale(), M.root:GetAlpha()
    check(not previousScale or scale < previousScale, yards .. " yards: all art gets smaller with distance")
    if yards >= 50 then check(alpha < previousAlpha and alpha > 0, yards .. " yards: outer range fades") end
    previousScale, previousAlpha = scale, alpha
    eq(M.label()._text, "Silverleaf", yards .. " yards: distance stays off label")
end
for _, yards in ipairs({ 60, 90 }) do
    WoW.pos = { chosen.north - yards, chosen.west, 1 }
    WoW.navDistance = yards
    frames(0.6)
    eq(shown(), false, yards .. " yards: no beacon")
    eq(WoW.waypoint, nil, yards .. " yards: no native waypoint marker either")
    for _, s in ipairs(M.sparks) do eq(s.anim._playing, false, "hidden sparks stop animating") end
    for _, w in ipairs(M.vapor().wisps) do eq(w.anim._playing, false, "out-of-range vapor stops") end
end
WoW.pos = startPos
Minimap:Show()
step(); settle()
for _, w in ipairs(M.vapor().wisps) do
    eq(w.anim._playing, true, "vapor returns with the beacon")
    w.anim:Stop()
    w.anim._scripts.OnFinished()
    eq(w.anim._playing, true, "visible vapor renews after dissolving")
end
for _, s in ipairs(M.sparks) do
    eq(s.anim._playing, true, "each sparkle has its own running animation")
    eq(s.drift._type, "Translation", "each sparkle drifts")
end
check(M.sparks[1].anim ~= M.sparks[2].anim, "sparkles animate independently")
local sparkle = M.sparks[1]
local previousX, previousY = sparkle._points[1][4], sparkle._points[1][5]
sparkle.anim._scripts.OnFinished()
check(sparkle._points[1][4] ~= previousX or sparkle._points[1][5] ~= previousY, "next twinkle moves to a new spot")
eq(sparkle.anim._playing, true, "next twinkle starts again")
WoW.combat = true
WoW.pos = { chosen.north - 90, chosen.west, 1 }
WoW.navDistance = 90
Minimap:Hide()
frames(0.1)
eq(shown(), false, "moving beyond range in combat hides the sparks immediately")
check(WoW.waypoint ~= nil, "combat holds waypoint cleanup")
SuperTrackedFrame:UpdateAlpha()
eq(SuperTrackedFrame:GetAlpha(), 0, "held out-of-range waypoint cannot expose native distance marker")
frames(NR.db.interval + F.GRACE + 0.6)
SuperTrackedFrame:UpdateAlpha()
eq(SuperTrackedFrame:GetAlpha(), 0, "out-of-range native marker stays hidden even after target expires in combat")
WoW.combat = false; frames(0.6)
eq(WoW.waypoint, nil, "out-of-range point cleared after combat")
WoW.pos = startPos; Minimap:Show(); step(); settle()
eq(WoW.cvars.showInGameNavigation, "1", "navigation enabled")
SuperTrackedFrame:UpdateAlpha()
eq(SuperTrackedFrame:GetAlpha(), 0, "native diamond covered only while our beacon shows")

local setPoint, clearPoint, track = C_Map.SetUserWaypoint, C_Map.ClearUserWaypoint, C_SuperTrack.SetSuperTrackedUserWaypoint
local sets = 0
C_Map.SetUserWaypoint = function(...) sets = sets + 1; return setPoint(...) end
step(); step()
eq(sets, 0, "same measured node: no repeated waypoint writes")
C_Map.SetUserWaypoint = setPoint
NR.Compass.Chosen().height = "above"
frames(0.1)
check(M.label()._text:find("above", 1, true), "above hint visible")
check(M.beam()._points[1][5] > 0, "above: column extends upward")
NR.Compass.Chosen().height = "below"
frames(0.1)
check(M.label()._text:find("below", 1, true), "below hint visible")
check(M.beam()._points[1][5] < 0, "below: column extends downward")

WoW.navClamped = true; frames(0.1)
eq(shown(), false, "off screen: no beacon")
SuperTrackedFrame:UpdateAlpha()
eq(SuperTrackedFrame:GetAlpha(), 1, "native edge indicator left visible")
WoW.navClamped = false; frames(0.1)
eq(shown(), true, "turning back: beacon returns without a sweep")
WoW.navDistance = distance() + 50; frames(0.1)
eq(shown(), false, "stale navigation position hidden")
settle()

-- Any wanted nearby object gets the exact cue, even a different node.
WoW.plates = { { unit = "nameplate1", name = "Peacebloom", object = true, soft = true } }
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
frames(0.6)
eq(NR.Marker.Nearby(), true, "nearby object receives exact sparks")
eq(shown(), false, "nearby stars suppress distant beacon")
eq(WoW.waypoint, nil, "handoff releases navigation slot")
WoW.plates = {}
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
step(); settle()
eq(shown(), true, "distant cue returns when nearby plate disappears")
local savedPos = WoW.pos[1]
WoW.pos[1] = NR.Compass.Chosen().north - 10
settle()
eq(shown(), true, "ten yards with no qualifying plate: beacon remains as fallback")
WoW.pos[1] = savedPos
step(); settle()

-- Player navigation takes priority, including a waypoint not supertracked.
local playerPoint = UiMapPoint.CreateFromCoordinates(1411, 0.2, 0.3)
setPoint(playerPoint)
eq(M.ours(), nil, "player's replacement ends ownership")
NR.Set("marker", false)
eq(WoW.waypoint.x, 0.2, "disable preserves player's waypoint")
eq(WoW.cvars.showInGameNavigation, "0", "disable restores navigation setting")
NR.Set("marker", true); step(); settle()
eq(WoW.waypoint.x, 0.2, "occupied slot never replaced")
eq(shown(), false, "occupied slot hides beacon")
SuperTrackedFrame:UpdateAlpha()
eq(SuperTrackedFrame:GetAlpha(), 1, "player's navigation is not covered")
WoW.SetSuperTracked(nil); clearPoint()
step(); settle()
eq(shown(), true, "freed slot reclaimed")

-- Stop during combat/map: hide now, restore only when safe.
for _, gate in ipairs({ "combat", "worldMapShown", "gamepadUI" }) do
    WoW[gate] = true
    NR.Set("marker", false)
    eq(shown(), false, gate .. ": disabled beacon hidden immediately")
    check(WoW.waypoint ~= nil, gate .. ": cleanup waits")
    frames(0.6)
    check(M.ours() ~= nil, gate .. ": ownership retained while blocked")
    WoW[gate] = false
    frames(0.6)
    eq(WoW.waypoint, nil, gate .. ": deferred cleanup completed")
    eq(WoW.cvars.showInGameNavigation, "0", gate .. ": setting restored")
    eq(M.driver._scripts.OnUpdate, nil, gate .. ": no idle driver after cleanup")
    restart()
end

-- Failed untracking must not create a stranded supertrack with no waypoint.
C_SuperTrack.SetSuperTrackedUserWaypoint = function() end
NR.Set("marker", false)
check(WoW.waypoint and M.ours(), "failed untrack: waypoint and ownership kept")
C_SuperTrack.SetSuperTrackedUserWaypoint = track
frames(0.6)
eq(WoW.waypoint, nil, "untrack retry succeeds")
restart()
C_Map.ClearUserWaypoint = function() end
NR.Set("marker", false)
check(WoW.waypoint and M.ours() and NR.charDb.farMarker, "failed clear: ownership remains saved")
C_Map.ClearUserWaypoint = clearPoint
frames(0.6)
eq(WoW.waypoint, nil, "clear retry succeeds")

-- Another handler chooses a quest while our waypoint is being set.
local trackingAnything = C_SuperTrack.IsSuperTrackingAnything
C_SuperTrack.IsSuperTrackingAnything = function() return WoW.Secret("tracking") end
NR.Set("marker", true); step()
eq(WoW.waypoint, nil, "unreadable navigation availability: no claim")
C_SuperTrack.IsSuperTrackingAnything = trackingAnything
NR.Set("marker", false)
C_Map.SetUserWaypoint = function(p)
    local result = setPoint(p)
    WoW.SetSuperTracked("quest")
    return result
end
NR.Set("marker", true); step()
eq(WoW.superTracked, "quest", "synchronous quest choice wins over our set")
frames(0.6)
eq(WoW.superTracked, "quest", "cleanup preserves the quest")
eq(WoW.waypoint, nil, "unused own point removed")
C_Map.SetUserWaypoint = setPoint
WoW.SetSuperTracked(nil)
restart()

-- A synchronous handler replaces our point while untracking it.
C_SuperTrack.SetSuperTrackedUserWaypoint = function(on)
    track(on)
    if not on then setPoint(playerPoint) end
end
NR.Set("marker", false)
eq(WoW.waypoint.x, 0.2, "replacement inside untrack is never cleared")
C_SuperTrack.SetSuperTrackedUserWaypoint = track
clearPoint()
restart()
-- A handler opens the map after untracking: defer the next mutation.
C_SuperTrack.SetSuperTrackedUserWaypoint = function(on)
    track(on)
    if not on then WoW.worldMapShown = true end
end
NR.Set("marker", false)
check(WoW.waypoint and M.ours(), "map opened inside untrack: clear deferred")
C_SuperTrack.SetSuperTrackedUserWaypoint = track
WoW.worldMapShown = false; frames(0.6)
eq(WoW.waypoint, nil, "clear resumes after map closes")

restart()
C_CVar.SetCVar("showInGameNavigation", "0")
frames(0.6); step()
eq(WoW.cvars.showInGameNavigation, "0", "external navigation setting respected")
eq(shown(), false, "external navigation setting hides beacon")
check(NR.db.farNavigation and NR.db.farNavigation.cancelled, "external change remains cancelled until toggle")
restart()
eq(shown(), true, "explicit off/on clears cancellation")

-- Missing sweeps and target invalidation must release the waypoint.
Minimap:Hide()
frames(NR.db.interval + F.GRACE + 0.6)
eq(shown(), false, "stale node hidden")
eq(WoW.waypoint, nil, "stale node releases navigation")
Minimap:Show()
step(); settle()
NR.Compass.Snooze("15")
eq(shown(), false, "snoozing drops beacon immediately")
eq(WoW.waypoint, nil, "snoozing drops waypoint immediately")
NR.Compass.ClearSnoozes(); step(); settle()
NR.Icons.Clear()
eq(WoW.waypoint, nil, "tracking/record reset immediately releases waypoint")
step(); settle()

-- Logout restores both resources; delayed notifications must not reclaim them.
WoW.fire("PLAYER_LOGOUT")
eq(WoW.waypoint, nil, "logout clears own waypoint")
eq(WoW.cvars.showInGameNavigation, "0", "logout restores navigation setting")
WoW.fire("CVAR_UPDATE", "showInGameNavigation", "0")
frames(3)
eq(WoW.waypoint, nil, "logout callbacks cannot reclaim navigation")
WoW.fire("PLAYER_LOGIN")
WoW.fire("CVAR_UPDATE", "showInGameNavigation", "0")
WoW.fire("PLAYER_ENTERING_WORLD")
step(); frames(1)
eq(WoW.cvars.showInGameNavigation, "0", "reload waits for settings sync")
frames(NR.Marker.SETTLE); step(); settle()
eq(shown(), true, "reload can reacquire and show the beacon")
-- A failed logout cleanup leaves a saved point for the next load to clean.
WoW.combat = true
local saved = keepPoint()
WoW.fire("PLAYER_LOGOUT")
check(NR.charDb.farMarker ~= nil, "combat logout keeps pending ownership")
WoW.combat = false
NR.db.marker = false
WoW.fire("PLAYER_LOGIN"); WoW.fire("PLAYER_ENTERING_WORLD")
frames(NR.Marker.SETTLE + 0.6)
eq(WoW.waypoint, nil, "off at login: saved own point cleared without a sweep")
eq(NR.charDb.farMarker, nil, "saved cleanup finished")
eq(WoW.cvars.showInGameNavigation, "0", "off at login: saved CVar restored")
eq(next(NR.failures), nil, "no API failures")
checkMethods({ "FontString:SetFont", "Texture:SetSize", "Texture:SetPoint" })
done("test_farmarker")
