-- The waypoint procedure (/fp steps nr waypoint, #29): our user waypoint on
-- the nearest node (NodeRadar's own Scan.MapPosition), super-tracked; the
-- marker read; clamped; arrival; the player's own waypoint over ours;
-- both clearing orders; the reload, and the final cleanup (tracking first).
-- Then /fp steps nr waypointframe, SuperTrackedFrame read again. Events fired
-- inside our setters are marked "(ours)". Runs locally only (ForeverProbe is
-- private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
local NR = loadAddon()
NR.db.enabled = false                                      -- the probe sweeps; the radar stays out of it
local FP = loadForeverProbe()
local T = loadProbe()._test
local S = FP.Steps
local db = NodeRadarProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") and not l:find("UI_ERROR_MESSAGE") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 30 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/waypoint"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail) end

WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.4 }, { 5287, 3525 }
WoW.navFrame = CreateFrame("Frame")
local stf = CreateFrame("Frame")
stf:Show()
rawset(_G, "SuperTrackedFrame", stf)
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" }, { "Silverleaf", -60, 60, kind = "herbs" } }

-- Not free: a quest super-tracked waits.
WoW.superTracked = "quest"
fp("steps nr waypoint")
poll()
eq(record().at, 1, "waits while a quest is super-tracked")
WoW.superTracked = nil
poll()
eq(result(1).status, "done", "free: no waypoint, nothing super-tracked")

-- Set: the nearest node's map point, from NodeRadar's own conversion.
S.Run()
eq(result(2).status, "done", "set: " .. tostring(result(2).lastError))
check(WoW.waypoint and WoW.waypoint.map == 1411, "our waypoint is on the zone")
local r = NR.Scan.Sweep()
local near
for _, b in ipairs(r.blips) do if b.name == "Wilted Peacebloom" then near = b end end
local _, ex, ey = NR.Scan.MapPosition(r, near)
check(math.abs(WoW.waypoint.x - ex) < 1e-9 and math.abs(WoW.waypoint.y - ey) < 1e-9,
    "...at the nearest node's coordinates (Wilted Peacebloom, not the farther Silverleaf)")
eq(WoW.superTracked, "waypoint", "...and super-tracked")
check(detail(2):find("SetUserWaypoint %-> true") and detail(2):find("CanSetUserWaypointOnMap true"),
    "...the answers logged: " .. detail(2))
check(logged("USER_WAYPOINT_UPDATED %(ours%)") and logged("SUPER_TRACKING_CHANGED %(ours%)"),
    "the events fired inside our setters are marked ours")

-- The nearest node, whichever the sweep lists first: two of a name, the far
-- one lower (the grid reads the bottom row first) or higher.
for _, farY in ipairs({ -70, 70 }) do
    WoW.blips = { { "Wilted Peacebloom", -70, farY, kind = "herbs" }, { "Wilted Peacebloom", 20, 10, kind = "herbs" } }
    check(T.nearestNode().x > 0.5, "the nearest node (east), the far one at y " .. farY)
end
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" }, { "Silverleaf", -60, 60, kind = "herbs" } }

-- The marker, clamped, arrival.
poll()
eq(result(3).status, "done", "the navigation frame read")
check(detail(3):find("nav frame present") and detail(3):find("super%-tracking anything true"), "...its state")
check(detail(3):find("SuperTrackedFrame shown"), "SuperTrackedFrame read as shown: " .. detail(3))
stf:Hide()
S.Answer(true)                                             -- 4: seen
settle()
poll()
eq(record().at, 5, "waits until clamped")
WoW.navClamped = true
poll()
settle()
eq(result(5).status, "done", "clamped")
S.Answer(true)                                             -- 6
poll()
eq(record().at, 7, "waits for arrival")
WoW.fire("NAVIGATION_DESTINATION_REACHED", true)
check(logged("NAVIGATION_DESTINATION_REACHED isWaypoint=true"), "arrival logged, not ours")
poll()
eq(result(7).status, "done", "arrival completes the walk")
S.Answer(true)                                             -- 8

-- Ours again, then the player's own over it.
eq(result(9).status, "done", "ours set again: " .. tostring(result(9).lastError))
check(detail(9):find("SuperTrackedFrame hidden"), "...and as hidden: " .. detail(9))
check(WoW.waypoint and WoW.superTracked == "waypoint", "...and tracked")
poll()
eq(record().at, 10, "waits for the player's own waypoint")
WoW.waypoint = { map = 1411, x = 0.2, y = 0.2 }
WoW.fire("USER_WAYPOINT_UPDATED")
check(logged("USER_WAYPOINT_UPDATED $") or logged("USER_WAYPOINT_UPDATED%s*$"), "the player's event isn't marked ours")
poll()
eq(result(10).status, "done", "the player's own waypoint seen")
poll()
eq(record().at, 11, "waits for the player to clear it")
WoW.waypoint, WoW.superTracked = nil, nil
poll()
eq(result(11).status, "done", "free again")

-- Both clearing orders.
eq(result(12).status, "done", "waypoint first: " .. tostring(result(12).lastError))
check(logged("waypoint cleared, tracking left alone"), "...its middle state logged")
eq(result(13).status, "done", "tracking first")
check(logged("tracking off, waypoint still set"), "...its middle state logged")
check(logged("cleared, tracking first: waypoint false"), "nothing left after the second order")
eq(result(14).status, "done", "set once more for the reload")
check(WoW.waypoint ~= nil, "...set")
eq(record().at, 15, "at the reload")
S.Next()
eq(result(16).status, "done", "read after the reload")
eq(result(17).status, "done", "cleared")
check(WoW.waypoint == nil and WoW.superTracked == nil,
    "the final cleanup leaves no waypoint and no super-track (tracking first)")
eq(record().at, 18, "at the last reload")
fp("steps stop")

-- SuperTrackedFrame read again, a few seconds after Set.
fp("steps nr waypointframe")
local function frec() return FP.db.steps.records["NodeRadarProbe/waypointframe"] end
poll()
eq(frec().results[1].status, "done", "free")
stf:Show()
S.Run()
eq(frec().results[2].status, "done", "set: " .. tostring(frec().results[2].lastError))
poll()
check(frec().at == 3 and (frec().results[3] or {}).status == nil, "waits a few seconds after Set: "
    .. tostring((frec().results[3] or {}).detail))
WoW.advance(2)
poll()
eq(frec().results[3].status, "done", "read")
check(tostring(frec().results[3].detail):find("SuperTrackedFrame shown"), "...shown: " .. tostring(frec().results[3].detail))
settle()
eq(frec().results[4].status, "done", "cleared")
check(WoW.waypoint == nil and WoW.superTracked == nil, "...tracking first: nothing left")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
eq(WoW.softCursor, false, "the soft cursor is off")

done("test_probe_waypoint")
