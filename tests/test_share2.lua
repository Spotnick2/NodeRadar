-- Party nodes, step 2 (#83; docs/PLAN.md "Step 2: the compass, the beacon,
-- the stars and the sonar"): a receiver that never sweeps choosing a party
-- node for the compass and the beacon, each candidate by its own freshness,
-- the ticker choosing again as it moves, expiry read between two ticks, local
-- clears keeping a party target, the waypoint never churned, the stars on a
-- plate named as a party node nearby, and the sonar on a node arriving.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.showInGameNavigation = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
NR.Track.SetSmart(false)
local Icons, Share, Compass = NR.Icons, NR.Share, NR.Compass
local T, S, C, F = Icons._test, Share._test, Compass._test, NR.FarMarker._test
WoW.itemCached[765] = true                                 -- Silverleaf
WoW.itemCached[2449] = true                                -- Earthroot

WoW.units.player = { name = "Drakuza", realm = "Memphisto", full = "Drakuza Memphisto" }
WoW.units.party1 = { name = "Kalizo", realm = "Mistwalker", full = "Kalizo Mistwalker" }
local OTHER = "Kalizo Mistwalker"
WoW.group = true

local function K() return C_Minimap.GetViewRadius() / 99 end
local function frames(seconds)
    for _ = 1, math.floor(seconds / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end
end
local function fresh()
    WoW.blips = {}
    Icons.Clear()
    S.reset()
    WoW.group, WoW.raid, WoW.instanced = true, false, false
    WoW.pos, WoW.posSecret, WoW.dead, WoW.onTaxi, WoW.facing = { 0, 0, 1 }, false, false, false, 0
    WoW.tracking[1].active = false                         -- the main: no tracking, never a sweep
    WoW.units.party1 = { name = "Kalizo", realm = "Mistwalker", full = "Kalizo Mistwalker" }
    NR.Learn.loading = false
    WoW.now = WoW.now + 200
    Share.OnRoster()
end
local SENDER = 1000
local function msg(sq, ...)
    return ("1|%d|%d|1|%s"):format(SENDER, sq, table.concat({ ... }, ";"))
end
local function receive(text) WoW.fire("CHAT_MSG_ADDON", "NodeRadar", text, "PARTY", OTHER, "", 0, 0, "", 0) end
local function entry(name) for _, e in ipairs(T.shared()) do if e.name == name then return e end end end
local function ring() return C.root._shown == true end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 0.05) end

NR.Set("partyNodes", true)

--------------------------------------------------------------------------------
-- The compass on a receiver that never sweeps
--------------------------------------------------------------------------------

NR.Set("compass", true)
fresh()
receive(msg(1, "765,30.0,0.0,Silverleaf", "2449,-60.0,0.0,Earthroot"))
local leaf, root = entry("Silverleaf"), entry("Earthroot")
eq(Compass.Chosen(), leaf, "never swept: the nearest party node chosen")
check(ring(), "...the ring shown")
eq(C.icon._file, leaf.icon, "...its icon")
local _, label, yards = Compass.Target()
eq(label, "Item 765", "...named by the entry's item")
eq(yards, 30, "...and its distance")
frames(0.2)
check(ring(), "...kept shown frame after frame with no sweep")

-- The ticker chooses again as the receiver moves, with no message.
WoW.pos = { -45, 0, 1 }
frames(1.1)
eq(Compass.Chosen(), root, "moved toward another: the ticker chose it, no message")
WoW.pos = { 0, 0, 1 }
frames(1.1)
eq(Compass.Chosen(), leaf, "...and back")

-- A heartbeat keeps the incumbent: the same table.
receive(msg(2, "765,30.3,0.0,Silverleaf", "2449,-60.0,0.0,Earthroot"))
eq(entry("Silverleaf"), leaf, "a heartbeat: the same entry")
eq(Compass.Chosen(), leaf, "...still the target")

-- A snooze chooses again at once.
Compass.Snooze("15")
eq(Compass.Chosen(), root, "snoozed: the other chosen at once")
Compass.ClearSnoozes()
eq(Compass.Chosen(), leaf, "...unsnoozed: back")

-- Expiry read between two ticks: not live, not chosen, the ring hidden.
local heard = leaf.heard
WoW.now = heard + Share.EXPIRE - 0.01
check(Share.Live(leaf), "24.99 s: live")
WoW.now = heard + Share.EXPIRE
check(not Share.Live(leaf), "25 s, before the ticker removes it: not live")
eq(#T.shared(), 2, "...still kept (the ticker hasn't run)")
C.frame()
check(not ring(), "...the ring hidden")
Compass.Refresh()
eq(C.target(), nil, "...and not chosen")
WoW.tick(0)
eq(#T.shared(), 0, "the ticker: gone")

-- Another instance: not live.
fresh()
receive(msg(1, "765,30.0,0.0,Silverleaf"))
check(Share.Live(entry("Silverleaf")), "live in my instance")
WoW.pos = { 0, 0, 2 }
check(not Share.Live(entry("Silverleaf")), "...not from another")
frames(1.1)
eq(C.target(), nil, "...not chosen there")
WoW.pos = { 0, 0, 1 }

-- A nearer stale local record against a fresh party node.
fresh()
local rec = { name = "Earthroot", kind = "herbs", north = 10, west = 0, misses = 0 }
table.insert(T.records(), rec)
Compass.Reconcile({}, WoW.now)                             -- a local sweep, now
eq(Compass.Chosen(), rec, "a fresh local record chosen")
WoW.now = WoW.now + NR.db.interval + Compass.GRACE + 1     -- the sweeps stopped
receive(msg(1, "765,40.0,0.0,Silverleaf"))
eq(Compass.Chosen(), entry("Silverleaf"), "sweeps stopped: the farther live party node wins")
local partyTarget = Compass.Chosen()

-- A local clear (a tracking change) keeps a party target; turning the last
-- choosing feature off drops it.
WoW.fire("MINIMAP_UPDATE_TRACKING")
eq(Compass.Chosen(), partyTarget, "a tracking change: the party target kept")
Icons.Clear()
eq(Compass.Chosen(), partyTarget, "Icons.Clear: kept")
NR.Set("compass", false)
eq(C.target(), nil, "the compass off, nothing else choosing: no target")
check(not ring(), "...the ring hidden")
frames(1.1)
eq(C.target(), nil, "...and the ticker chooses nothing")

-- Own nodes first (the owner, two gatherers sharing with each other): a
-- farther own node beats a nearer party one, outright; the party's only with
-- no candidate of one's own (snoozed, stale), and own again at once.
NR.Set("compass", true)
fresh()
receive(msg(1, "765,10.0,0.0,Silverleaf"))
local pleaf = entry("Silverleaf")
eq(Compass.Chosen(), pleaf, "own first: none of my own, the party's")
local own = { name = "Earthroot", kind = "herbs", north = -80, west = 0, misses = 0 }
table.insert(T.records(), own)
Compass.Reconcile({}, WoW.now)
eq(Compass.Chosen(), own, "own first: my farther node beats the nearer party one")
frames(1.1)
eq(Compass.Chosen(), own, "...kept by the ticker")
receive(msg(2, "765,10.0,0.0,Silverleaf"))
eq(Compass.Chosen(), own, "...and by a heartbeat")
Compass.Snooze("15")
eq(Compass.Chosen(), pleaf, "my only node snoozed: the party's")
Compass.ClearSnoozes()
eq(Compass.Chosen(), own, "...unsnoozed: mine again at once")
WoW.now = WoW.now + NR.db.interval + Compass.GRACE + 1     -- my sweeps stopped
receive(msg(3, "765,10.0,0.0,Silverleaf"))
eq(Compass.Chosen(), pleaf, "my sweeps stale: the party's")
Compass.Reconcile({}, WoW.now)
eq(Compass.Chosen(), own, "...a sweep again: mine at once")
NR.Set("compass", false)

--------------------------------------------------------------------------------
-- The beacon with the marker alone
--------------------------------------------------------------------------------

local sets, clears = 0, 0
local realSet, realClear = C_Map.SetUserWaypoint, C_Map.ClearUserWaypoint
C_Map.SetUserWaypoint = function(...) sets = sets + 1; return realSet(...) end
C_Map.ClearUserWaypoint = function(...) clears = clears + 1; return realClear(...) end

fresh()
NR.Set("marker", true)
frames(1)
frames(NR.Marker.SETTLE)
receive(msg(1, "765,30.0,0.0,Silverleaf"))
leaf = entry("Silverleaf")
eq(Compass.Chosen(), leaf, "the marker alone: the party node chosen")
check(not ring(), "...the ring hidden (compass off)")
check(WoW.waypoint ~= nil, "...the waypoint placed with no sweep")
eq(WoW.superTracked, "waypoint", "...and tracked")
check(WoW.waypoint and near(WoW.waypoint.x, 0.5, 1e-6) and near(WoW.waypoint.y, 0.5 - 30 / 3525, 1e-6),
      "...at the node's map point from the map read now")
WoW.navDistance = 30
frames(0.6)
eq(F.root._shown, true, "...the beacon shown")
check(F.label()._text:find("Silverleaf", 1, true), "...named")
local s0, c0 = sets, clears
frames(3)                                                  -- three ticks
receive(msg(2, "765,30.4,0.0,Silverleaf"))                 -- a heartbeat, a small correction
frames(1.1)
WoW.fire("MINIMAP_UPDATE_TRACKING")                        -- a local clear
frames(1.1)
eq(sets - s0, 0, "ticks, a heartbeat, a local clear: no waypoint set again")
eq(clears - c0, 0, "...and none cleared")
eq(F.root._shown, true, "...the beacon still shown")

-- Expiry between two ticks: the beacon lets go.
WoW.now = leaf.heard + Share.EXPIRE
NR.FarMarker.Reconcile()
eq(F.root._shown, false, "expired before the ticker: the beacon hidden")
eq(WoW.waypoint, nil, "...the waypoint cleared")

--------------------------------------------------------------------------------
-- The stars on a plate named as a party node within 15 yards
--------------------------------------------------------------------------------

local M = NR.Marker._test
local function plates(list) WoW.plates = list; WoW.fire("NAME_PLATE_UNIT_ADDED", list[1] and list[1].unit) end
local MYSTERY = { unit = "nameplate1", name = "Mystery Bloom", object = true, soft = true }   -- unknown here
fresh()
receive(msg(1, "765,10.0,0.0,Mystery Bloom"))
plates({ MYSTERY })
frames(1)
eq(M.root._shown, true, "a plate named as a party node 10 yards away: the stars")
plates({})
frames(1)
receive(msg(2, "765,16.0,0.0,Mystery Bloom"))
plates({ MYSTERY })
frames(1)
eq(M.root._shown, false, "...16 yards away: none")
plates({})
frames(1)
receive(msg(3, "765,10.0,0.0,Mystery Bloom"))
WoW.pos = { 0, 0, 2 }
plates({ MYSTERY })
frames(1)
eq(M.root._shown, false, "...in another instance: none")
WoW.pos = { 0, 0, 1 }
plates({})
frames(1)
NR.Set("marker", false)
C_Map.SetUserWaypoint, C_Map.ClearUserWaypoint = realSet, realClear

--------------------------------------------------------------------------------
-- The sonar on a node arriving (best effort)
--------------------------------------------------------------------------------

local rings = {}
local realSonar = NR.Alert.Sonar
NR.Alert.Sonar = function(x, y, kind)
    rings[#rings + 1] = { x = x, y = y, kind = kind }
    return realSonar(x, y, kind)
end
NR.db.ring = true

fresh()
receive(msg(1, "765,30.0,0.0,Silverleaf"))
eq(#rings, 0, "a sender's first snapshot: the silent baseline")
WoW.now = WoW.now + Share.QUIET + 0.5
receive(msg(2, "765,30.0,0.0,Silverleaf", "2449,0.0,40.0,Earthroot"))
eq(#rings, 1, "a node arriving: one ripple")
local r1 = rings[1]
check(r1 and near(r1.x, -40 / K(), 0.01) and near(r1.y, 0, 0.01), "...where it was drawn")
eq(r1 and r1.kind, "herbs", "...in its kind's colour")
receive(msg(3, "765,30.0,0.0,Silverleaf", "2449,0.0,40.0,Earthroot"))
WoW.tick()
eq(#rings, 1, "a heartbeat: no ripple again")
receive(msg(4, "765,30.0,0.0,Silverleaf"))
receive(msg(5, "765,30.0,0.0,Silverleaf", "2449,0.0,42.0,Earthroot"))   -- back, measured again
WoW.tick()
eq(#rings, 1, "a node gone and back within 120 s: no ripple")

-- Past the rim: pending, then rippling when it comes into view; not after 10 s.
receive(msg(6, "765,30.0,0.0,Silverleaf", "765,5000.0,0.0,Silverleaf"))
eq(#rings, 1, "arrived past the rim: no ripple yet")
WoW.pos = { 4990, 0, 1 }
WoW.tick()
eq(#rings, 2, "...came into view: its ripple")
WoW.pos = { 0, 0, 1 }
receive(msg(7, "765,30.0,0.0,Silverleaf", "765,-5000.0,0.0,Silverleaf"))
WoW.now = WoW.now + Share.PENDING + 1
WoW.tick()
WoW.pos = { -4990, 0, 1 }
WoW.tick()
eq(#rings, 2, "...one coming into view after 10 s: none")
WoW.pos = { 0, 0, 1 }

-- The ring setting off: none, and none later.
NR.db.ring = false
receive(msg(8, "765,30.0,0.0,Silverleaf", "765,-30.0,0.0,Silverleaf"))
WoW.tick()
NR.db.ring = true
WoW.tick()
eq(#rings, 2, "the sonar off: no ripple, and none once it's back on")

-- Snapshots queued during a loading screen arrive together after it: all baseline.
WoW.fire("LOADING_SCREEN_ENABLED")
WoW.fire("LOADING_SCREEN_DISABLED")
receive(msg(9, "765,30.0,0.0,Silverleaf"))
receive(msg(10, "765,30.0,0.0,Silverleaf", "2449,0.0,-60.0,Earthroot"))
check(entry("Earthroot") ~= nil, "a burst after a loading screen: accepted")
WoW.tick()
eq(#rings, 2, "...no ripple")
-- The loading screen emptied the memory: a node heard of before it is new after.
WoW.now = WoW.now + Share.QUIET + 0.5
receive(msg(11, "765,30.0,0.0,Silverleaf", "2449,0.0,-60.0,Earthroot", "2449,0.0,42.0,Earthroot"))
WoW.tick()
eq(#rings, 3, "...a node heard of before the loading screen ripples after it")

-- Under the receiver's own icon of its item: not until it shows.
NR.Set("icons", true)
fresh()
WoW.tracking[1].active = true
WoW.blips = { { "Silverleaf", 20, 20, kind = "herbs" } }
WoW.now = WoW.now + 1; NR.Step(WoW.now)
WoW.now = WoW.now + 1; NR.Step(WoW.now)
local own = T.records()[1]
WoW.tick()
check(own and own.frame and own.frame._shown, "my own icon drawn")
receive(msg(1, "2449,-60.0,0.0,Earthroot"))
WoW.now = WoW.now + Share.QUIET + 0.5
receive(msg(2, "2449,-60.0,0.0,Earthroot", ("765,%.1f,%.1f,Silverleaf"):format(own.north + 3, own.west)))
WoW.tick()
eq(#rings, 3, "arriving under my own icon of its item: no ripple")
WoW.tracking[1].active = false
NR.Set("icons", false)                                     -- my icons gone: the party node shows
WoW.tick()
eq(#rings, 4, "...its ripple once it shows")
NR.Alert.Sonar = realSonar

done("test_share2")
