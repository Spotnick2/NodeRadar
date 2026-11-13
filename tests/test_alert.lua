-- Alert: per node name, a rise in its number of blips is a new node; a blink at
-- the map's edge, the player's zoom or a tracking change doesn't alert, the swap
-- indoors or out does (#63); the cooldown; the ring on each blip of the name;
-- Blizzard's ping solo only.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true                              -- Find Herbs on before the login
local NR = loadAddon()
NR.db.interval = 0.5                                       -- a quick idle cadence: these test behaviour, not cadence
local Alert, Learn = NR.Alert, NR.Learn
NR.db.learn = false                                        -- no experiments here

local function sounds()
    local n = 0
    for _, s in ipairs(WoW.sounds) do if s[1] == 3175 then n = n + 1 end end
    return n
end
local function rings()
    local shown = {}
    for _, f in ipairs(WoW.frames) do
        if f._parent == Minimap and f._strata == "HIGH" and f._shown then
            local p = f._points[#f._points]
            shown[#shown + 1] = { p[4], p[5] }
        end
    end
    return shown
end
local function hideRings()
    for _, f in ipairs(WoW.frames) do if f._parent == Minimap and f._strata == "HIGH" then f._shown = false end end
end

-- The first sweep after the login: a new area, so a node in view alerts.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
WoW.advance(0.6)
eq(sounds(), 1, "a node in view at login alerts (a new area)")
local r = rings()
eq(#r, 1, "...one ring")
check(r[1] and math.abs(r[1][1] - 30) < 7 and math.abs(r[1][2] + 20) < 7, "...on the node's blip")

-- Nothing new: no alert.
hideRings()
WoW.advance(6)
eq(sounds(), 1, "the same node: no new alert")

-- A second node of the same name: a rise; rings on both (which one is new can't be told).
table.insert(WoW.blips, { "Wilted Peacebloom", -60, 40, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), 2, "a second node of the name alerts")
eq(#rings(), 2, "...a ring on each blip of the name")

-- A non-node name: no alert.
hideRings()
WoW.advance(6)
table.insert(WoW.blips, { "Carry Your Weight", 80, -80 })
NR.db.learned.enUS = NR.db.learned.enUS or {}
NR.db.learned.enUS["Carry Your Weight"] = { kind = false, source = "toggle" }
WoW.advance(0.6)
eq(sounds(), 2, "a name that isn't a node never alerts")

-- A blink at the map's edge: gone, then back within 20 s: no alert.
WoW.advance(6)
table.remove(WoW.blips, 2)                                 -- the second Peacebloom leaves
WoW.advance(1)
table.insert(WoW.blips, { "Wilted Peacebloom", -60, 40, kind = "herbs" })
WoW.advance(1)
eq(sounds(), 2, "a node blinking at the edge doesn't alert again")

-- The cooldown: two new nodes 1 s apart, one alert.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
WoW.advance(25)                                            -- the blink window passes
local before = sounds()
table.insert(WoW.blips, { "Silverleaf", -40, -40, kind = "herbs" })
WoW.advance(0.6)
table.insert(WoW.blips, { "Stunted Silverleaf", 40, 60, kind = "herbs" })
WoW.advance(1)
eq(sounds(), before + 1, "two new nodes inside the cooldown: one alert")

-- The player's zoom (a SetZoom call, then the client's event): the counts
-- start over, silently.
local function zoom(z)
    Minimap:SetZoom(z)
    WoW.fire("MINIMAP_UPDATE_ZOOM")
end
WoW.advance(6)
before = sounds()
zoom(1)
table.insert(WoW.blips, { "Silverleaf", 70, 10, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), before, "after a zoom, the first sweep is a silent baseline")
zoom(0)
WoW.advance(0.6)

-- A call to the zoom already set: no event, nothing reset (#63), even before
-- the event of the call that set it.
WoW.advance(6)
Minimap:SetZoom(1)                                         -- its event comes later
WoW.advance(0.6)
before = sounds()
Minimap:SetZoom(1)
table.insert(WoW.blips, { "Silverleaf", -70, 30, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), before + 1, "a call to the same zoom: a new node still alerts")
WoW.fire("MINIMAP_UPDATE_ZOOM")
zoom(0)
WoW.advance(0.6)

-- Out of a cave or a tunnel: the client swaps the zoom with no call and fires
-- the event; the history is kept, so the ore in view on the way out alerts (#63).
WoW.advance(6)
local minerals = { name = "Find Minerals", spellID = 2580, active = true }
table.insert(WoW.tracking, minerals)
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.skillLines[186] = { skillID = 186, name = "Mining", rank = 50, modifier = 0, maxRank = 75 }
NR.db.learned.enUS = NR.db.learned.enUS or {}
NR.db.learned.enUS["Copper Vein"] = { kind = "ore", source = "gather" }
NR.db.learned.enUS["Tin Vein"] = { kind = "ore", source = "gather" }
WoW.advance(0.6)
WoW.advance(6)
before = sounds()
WoW.indoors = true
Minimap._zoom = 5                                          -- the indoor zoom, as left
WoW.fire("MINIMAP_UPDATE_ZOOM")
local outside = WoW.blips
WoW.blips = { outside[1] }                                 -- the smaller view inside
WoW.advance(0.6)
WoW.advance(25)                                            -- past the blink window
WoW.indoors = false
Minimap._zoom = 0
WoW.fire("MINIMAP_UPDATE_ZOOM")
local back = { "Copper Vein", 60, -50, kind = "ore" }
WoW.blips = { outside[1], back }
WoW.advance(0.6)
eq(sounds(), before + 1, "out of a tunnel: the ore in view alerts")
-- A short visit: what dropped on the way in and is back within 20 s is the same node.
WoW.advance(6)
before = sounds()
WoW.indoors = true
Minimap._zoom = 5
WoW.fire("MINIMAP_UPDATE_ZOOM")
WoW.blips = { outside[1] }
WoW.advance(0.6)
WoW.indoors = false
Minimap._zoom = 0
WoW.fire("MINIMAP_UPDATE_ZOOM")
WoW.blips = { outside[1], back }
WoW.advance(0.6)
eq(sounds(), before, "a short visit: the ore seen before going in doesn't alert again")
-- Inside at the indoor zoom (5), the player zooms out to 0, the outdoor zoom
-- remembered before the swap: still the player's zoom, silent.
WoW.advance(25)
before = sounds()
WoW.indoors = true
Minimap._zoom = 5
WoW.fire("MINIMAP_UPDATE_ZOOM")
WoW.advance(0.6)
zoom(0)
table.insert(WoW.blips, { "Tin Vein", 30, 30, kind = "ore" })
WoW.advance(0.6)
eq(sounds(), before, "the player's zoom inside, back to the outdoor level: a silent baseline")
WoW.indoors = false
WoW.fire("MINIMAP_UPDATE_ZOOM")
WoW.blips = { outside[1], back }
WoW.advance(0.6)
-- A zoom the client reports as unreadable: a reset, as before.
WoW.advance(6)
before = sounds()
Minimap._zoom = WoW.Secret("zoom")
WoW.fire("MINIMAP_UPDATE_ZOOM")
table.insert(WoW.blips, { "Copper Vein", -30, 70, kind = "ore" })      -- no recent drop of its name
WoW.advance(0.6)
eq(sounds(), before, "an unreadable zoom: a silent baseline")
WoW.advance(6)
Minimap:SetZoom(WoW.Secret("zoom"))                        -- a call while it's still unreadable
table.insert(WoW.blips, { "Copper Vein", -50, -50, kind = "ore" })
WoW.advance(0.6)
eq(sounds(), before, "...and a call while unreadable: a silent baseline too")
Minimap._zoom = 0
WoW.fire("MINIMAP_UPDATE_ZOOM")
WoW.blips = { outside[1] }
minerals.active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.advance(0.6)

-- The map resized (Edit Mode, a skin): silent too.
local rect = Minimap._rect
Minimap._rect = { 800, 500, 180, 180 }
table.insert(WoW.blips, { "Silverleaf", 50, -60, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), before, "after the map changed size, a silent baseline")
Minimap._rect = rect
WoW.advance(0.6)

-- A tracking change: silent too.
WoW.fire("MINIMAP_UPDATE_TRACKING")
table.insert(WoW.blips, { "Silverleaf", -70, -10, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), before, "after a tracking change, a silent baseline")

-- A zone change: from zero, so the new area's nodes alert.
WoW.advance(6)
WoW.fire("ZONE_CHANGED_NEW_AREA")
WoW.advance(0.6)
eq(sounds(), before + 1, "a new area's nodes alert")

-- Settings: no sound, no ring, a chat line; Blizzard's ping solo only.
NR.db.sound, NR.db.ring, NR.db.chat, NR.db.ping = false, false, true, true
hideRings()
WoW.advance(6)
before = sounds()
newChat()
table.insert(WoW.blips, { "Earthroot", 20, 20, kind = "herbs" })
NR.db.learned.enUS.Earthroot = { kind = "herbs", source = "gather" }
WoW.advance(0.6)
eq(sounds(), before, "sound off: no sound")
eq(#rings(), 0, "ring off: no ring")
local line = newChat()[1]
check(line and line:find("Earthroot"), "a chat line naming it: " .. tostring(line))
eq(#WoW.pings, 1, "solo: Blizzard's ping")
eq(WoW.pings[1][1] > 15 and WoW.pings[1][2] > 15, true, "...on the node")
WoW.group = true
WoW.advance(6)
table.insert(WoW.blips, { "Earthroot", -20, -50, kind = "herbs" })
WoW.advance(0.6)
eq(#WoW.pings, 1, "in a group: no ping (it's sent to the group)")
WoW.group = false

-- The radar off: no sweep at all.
NR.db.enabled = false
local reads = 0
local real = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function() reads = reads + 1; return real() end
WoW.advance(2)
eq(reads, 0, "radar off: no sweep")
NR.db.enabled = true
WoW.tracking[1].active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.advance(2)
eq(reads, 0, "no gathering tracking on: no sweep")
WoW.tracking[1].active = true
WoW.fire("MINIMAP_UPDATE_TRACKING")
-- GamePadEnable is on by default on a keyboard client (release check, 70450):
-- it alone must not stop the radar.
WoW.cvars.GamePadEnable = "1"
WoW.advance(1)
check(reads > 0, "GamePadEnable alone: the radar sweeps")
reads = 0
WoW.cvars.GamePadEnable = nil
WoW.gamepadUI = true
WoW.advance(2)
eq(reads, 0, "the gamepad on: no sweep")
WoW.gamepadUI = false
WoW.advance(1)
check(reads > 0, "...and sweeping again")
C_TooltipInfo.GetMinimapMouseover = real

-- The sonar: our own art, drawn additively, green for herbs and gold for ore.
NR.db.sound, NR.db.ring, NR.db.chat, NR.db.ping = true, true, false, false
hideRings()
WoW.advance(6)
table.insert(WoW.blips, { "Copper Vein", -50, 60, kind = "herbs" })     -- shown under Find Herbs here
NR.db.learned.enUS["Copper Vein"] = { kind = "ore", source = "gather" }
WoW.advance(0.6)
local sonar
for _, f in ipairs(WoW.frames) do
    if f._parent == Minimap and f._strata == "HIGH" and f._shown and f.kind == "ore" then sonar = f end
end
check(sonar, "an ore's sonar")
local parts = sonar and { sonar.rings[1], sonar.rings[2], sonar.glow } or {}
for i, part in ipairs(parts) do
    check(part.tex._file and part.tex._file:find("^Interface\\AddOns\\NodeRadar\\Media\\Sonar"), "part " .. i .. ": our own texture")
    check(part.tex._vertex and part.tex._vertex[1] == 1.0 and part.tex._vertex[2] == 0.8, "part " .. i .. ": gold for ore")
    check(part.anim and part.anim._playing, "part " .. i .. ": animating")
end
check(WoW.methodsCalled["Texture:SetBlendMode"], "drawn additively (no square around it)")
for _, f in ipairs({ "Media/SonarRing.tga", "Media/SonarGlow.tga" }) do
    check(io.open(f, "rb") ~= nil, f .. " ships")
end

-- Gathering a node, then another of its name comes into range: it alerts (not
-- taken for the first one blinking at the edge), even right after a blink.
local function drop(blip)
    for i, b in ipairs(WoW.blips) do if b == blip then table.remove(WoW.blips, i) end end
end
hideRings()
WoW.advance(6)
local herb = { "Peacebloom", 40, 40, kind = "herbs" }
NR.db.learned.enUS.Peacebloom = { kind = "herbs", source = "gather" }
table.insert(WoW.blips, herb)
WoW.advance(0.6)
WoW.advance(6)
drop(herb)                                                 -- it blinks at the edge
WoW.advance(1)
table.insert(WoW.blips, herb)
WoW.advance(1)
before = sounds()
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "Cast-9", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-9", 2366)            -- gathered
drop(herb)
WoW.advance(1)
table.insert(WoW.blips, { "Peacebloom", -70, -30, kind = "herbs" })     -- the next one, 1 s later
WoW.advance(1)
eq(sounds(), before + 1, "after gathering one, the next of its name alerts, a blink 3 s before or not")
-- A gather that didn't go through (interrupted; another cast's success): the
-- node is still there, and leaving the map's edge and coming back is a blink.
WoW.advance(25)
local edge = { "Peacebloom", 95, 0, kind = "herbs" }
table.insert(WoW.blips, edge)
WoW.advance(0.6)
WoW.advance(6)
before = sounds()
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "Cast-10", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-11", 2366)
drop(edge)
WoW.advance(1)
table.insert(WoW.blips, edge)
WoW.advance(1)
eq(sounds(), before, "an interrupted gather: the node that left and came back is a blink")

-- A second node of a name coming in beside the first (Codex, PR #12): two
-- blips, a rise, an alert; at 26 units the wide grid alone merged them.
WoW.blips = { { "Peacebloom", 0, 0, kind = "herbs" } }
WoW.advance(25)                                            -- past the blink window of the earlier drops
before = sounds()
table.insert(WoW.blips, { "Peacebloom", 26, 0, kind = "herbs" })
WoW.advance(1)
eq(sounds(), before + 1, "a second Peacebloom 26 units from the first alerts")
-- And a third in the chain (Codex again): five running columns, still a rise.
WoW.advance(6)
before = sounds()
table.insert(WoW.blips, { "Peacebloom", 52, 0, kind = "herbs" })
WoW.advance(1)
eq(sounds(), before + 1, "a third Peacebloom in the chain alerts")

-- /nr test.
NR.db.sound = true
before = sounds()
SlashCmdList.NODERADAR("test")
eq(sounds(), before + 1, "/nr test sounds")
eq(WoW.softCursor, false, "the soft cursor off at the end")

--------------------------------------------------------------------------------
-- #137: from 70862 the scan's alert is one moment. A presence read's rise holds its sound
-- until a node of it is located (the sound and the sonar together), no search of it is open,
-- or HOLD seconds pass. Driven by hand: the scan itself stays off.
--------------------------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
NodeRadar, NodeRadarDB, NodeRadarCharDB = nil, nil, nil
WoW.build = "70862"
WoW.tracking[1].active = true
WoW.pos = { 1000, 2000, 0, 0 }
NR = loadAddon({ db = { moveScanAsked = true } })
NR.db.learn, NR.db.cooldown = false, 0
local A = NR.Alert
local open = {}                                            -- the names with a search open
NR.Locate.Searching = function(name) return open[name] == true end
local sonarCalls, realSonar = 0, A.Sonar
A.Sonar = function(...) sonarCalls = sonarCalls + 1; return realSonar(...) end
local function node(name, dn)
    return { name = name or "Silverleaf", kind = "herbs", north = WoW.pos[1] + (dn or 30), west = WoW.pos[2] }
end
-- A baseline of `n` Silverleaf, then a rise to `to` at `t` (now). Returns the sounds and sonars so far.
local function rise(t, n, to, name)
    name = name or "Silverleaf"
    A.Reset("test")
    A.Counts({ [name] = n }, t - 1, nil, nil, math.huge)
    A.Counts({ [name] = to }, t, nil, nil, math.huge, 0)
    return sounds(), sonarCalls
end
local function tickTo(t)
    while WoW.now < t do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end
end

-- Held, then located: one sound and one sonar, in one call.
local t = WoW.now + 10
WoW.now = t
open.Silverleaf = true
local s0, r0 = rise(t, 1, 2)
eq(sounds(), s0, "a scan's rise: held, no sound yet")
A.Flush(t + 0.5)
eq(sounds(), s0, "...a search open: still held")
A.Located(node(), t + 0.6)
check(sounds() == s0 + 1 and sonarCalls == r0 + 1, "located: its sound and its sonar in one call")
tickTo(t + 3)
eq(sounds(), s0 + 1, "...and nothing more after HOLD")

-- The deadline: still searching after HOLD, the sound plays (Alert's own timer).
t = WoW.now + 10
WoW.now = t
s0 = rise(t, 1, 2)
tickTo(t + A.HOLD - 0.1)
eq(sounds(), s0, "searching, before HOLD: held")
tickTo(t + A.HOLD + 0.1)
eq(sounds(), s0 + 1, "...past HOLD: the sound plays on its own")

-- No search open (a rotating map, a backoff, a search that ran out): at once, at NR.Located.
open = {}
t = WoW.now + 10
WoW.now = t
s0, r0 = rise(t, 1, 2)
NR.Located({}, t)
check(sounds() == s0 + 1 and sonarCalls == r0, "no search open: the sound at once, no sonar")

-- During a burst only the deadline plays it (the window being read isn't queued).
local realBursting = NR.MoveScan.Bursting
NR.MoveScan.Bursting = function() return true end
t = WoW.now + 10
WoW.now = t
s0 = rise(t, 1, 2)
A.Flush(t + 0.5)
eq(sounds(), s0, "a burst under way: no search open isn't judged yet")
A.Flush(t + A.HOLD)
eq(sounds(), s0 + 1, "...the deadline still plays it")
NR.MoveScan.Bursting = realBursting

-- Two holds overlapping (cooldown 0): the first plays before the second is held, each once.
open = { Silverleaf = true, ["Wilted Peacebloom"] = true }
t = WoW.now + 10
WoW.now = t
s0 = rise(t, 1, 2)
A.Counts({ Silverleaf = 2, ["Wilted Peacebloom"] = 1 }, t + 0.5, nil, nil, math.huge, 0)
eq(sounds(), s0 + 1, "a second batch held: the first plays first")
A.Located(node("Wilted Peacebloom"), t + 0.7)
eq(sounds(), s0 + 2, "...the second at its location")
A.Located(node(), t + 0.8)
tickTo(t + 4)
eq(sounds(), s0 + 2, "...each once")

-- A gather during a hold: played before its token retires; a record a moment later ripples only.
t = WoW.now + 10
WoW.now = t
s0, r0 = rise(t, 1, 2)
A.Gathered("Silverleaf", t + 0.3)
eq(sounds(), s0 + 1, "a gather during a hold: the held sound plays first")
A.Located(node(), t + 0.5)
check(sounds() == s0 + 1 and sonarCalls == r0 + 1, "...a node located just after: its sonar, no second sound")
WoW.pos = { WoW.pos[1] + 100, WoW.pos[2], 0, 0 }           -- away from the gathered one (Alert.NEAR)
-- A fall during a hold: the same.
t = WoW.now + 10
WoW.now = t
s0, r0 = rise(t, 1, 2)
A.Counts({ Silverleaf = 1 }, t + 0.4, nil, nil, math.huge, 0)
eq(sounds(), s0 + 1, "a fall during a hold: the held sound plays first")
A.Located(node(), t + 0.6)
check(sounds() == s0 + 1 and sonarCalls == r0 + 1, "...a node located just after: its sonar, no second sound")
-- A location 2 s after the emission, no token left: the full alert, as before.
A.Located(node("Silverleaf", -40), t + 2.5)
eq(sounds(), s0 + 2, "a location 2 s after the emission, no token: the full alert")

-- A stall past OWED_TTL (the client frozen): one sound, one sonar a node, in either order.
local function stall(timerFirst, nodes)
    t = WoW.now + 10
    WoW.now = t
    local s, r = rise(t, 1, 2)
    local late = t + A.OWED_TTL + 1
    if timerFirst then WoW.now = late; WoW.tick(0.05) end
    for i = 1, nodes do A.Located(node("Silverleaf", 20 * i), late) end
    WoW.now = late
    return sounds() - s, sonarCalls - r
end
for _, first in ipairs({ true, false }) do
    for _, n in ipairs({ 1, 2 }) do
        local s, r = stall(first, n)
        check(s == 1 and r == n, ("a stall past OWED_TTL, %s first, %d located: one sound, %d sonar (%d, %d)"):format(
            first and "the timer" or "the location", n, n, s, r))
    end
end

-- Two nodes of the risen name located within the second: a sonar each, one sound (two tokens,
-- or one token and the name's sound just played).
for _, to in ipairs({ 3, 2 }) do
    t = WoW.now + 10
    WoW.now = t
    s0, r0 = rise(t, 1, to)
    A.Located(node("Silverleaf", 20), t + 0.4)
    A.Located(node("Silverleaf", -20), t + 0.7)
    check(sounds() == s0 + 1 and sonarCalls == r0 + 2, ("a rise of %d, two located within the second: one sound, two sonars"):format(to - 1))
end

-- A reset, a new area, the scan turned off: the held sound plays; the radar turned off: dropped.
local function heldThen(f)
    t = WoW.now + 10
    WoW.now = t
    local s = rise(t, 1, 2)
    f(t)
    local played = sounds() - s
    tickTo(t + 3)
    return played, sounds() - s
end
local a, b2 = heldThen(function() A.Reset("zoom") end)
check(a == 1 and b2 == 1, "a reset: the held sound plays at once, once")
a, b2 = heldThen(function(now) A.NewArea(now) end)
check(a == 1 and b2 == 1, "a new area: the held sound plays at once, once")
a, b2 = heldThen(function() NR.Set("moveScan", false) end)
check(a == 1 and b2 == 1, "the scan turned off: the held sound plays at once")
a, b2 = heldThen(function() NR.Set("enabled", false) end)
check(a == 0 and b2 == 0, "the radar turned off: the held sound dropped")
NR.Set("enabled", true)
a, b2 = heldThen(function() NR.db.enabled = false end)
check(b2 == 0, "the radar off by the deadline: dropped")
NR.db.enabled = true

-- The sweep's path (blips given) fires at once, as before.
t = WoW.now + 10
WoW.now = t
A.Reset("test")
A.Counts({ Silverleaf = 1 }, t - 1, { Silverleaf = { { x = 0, y = 0 } } })
s0 = sounds()
A.Counts({ Silverleaf = 2 }, t, { Silverleaf = { { x = 0, y = 0 }, { x = 20, y = 20 } } }, nil, nil, 0)
eq(sounds(), s0 + 1, "blips given (the sweep's path): the sound at once")
done("test_alert")
