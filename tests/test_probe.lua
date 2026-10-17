-- NodeRadarProbe: a ForeverProbe module (the host loaded from its checkout,
-- harness.lua's loadForeverProbe). Its commands run on the stubbed client and
-- log what they read, never to chat. The client is modelled on rounds 1 and 2
-- (70450): a point is in screen pixels and counts only with the cursor on the
-- map or the soft cursor on. The ids procedure (round 3, #7) runs end to end:
-- names with colours, the tracking toggle, names paired with object IDs; its
-- radars stop with their step. Clients where a way doesn't work must not pass.
-- Every widget method it calls exists on 70450. Runs locally only (CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- What the host touches beyond the shared stub (all in the 70450 dump).
rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)
-- Frame stratas, as measured: "HIGHLIGHT" is a draw layer and throws (round 1).
local STRATAS = { BACKGROUND = true, LOW = true, MEDIUM = true, HIGH = true, DIALOG = true, FULLSCREEN = true,
                  FULLSCREEN_DIALOG = true, TOOLTIP = true }
function WoW.Methods.SetFrameStrata(w, s)
    if not STRATAS[s] then error("bad argument #1 to 'SetFrameStrata' (Usage: self:SetFrameStrata(strata))", 2) end
    w._strata = s
end

local FP = loadForeverProbe()
local T = loadProbe()._test
local S = FP.Steps
local db = NodeRadarProbeDB

-- The newest line matching a pattern, in the probe's saved log.
local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
-- The host polls a wait step about once a second.
local function poll() WoW.advance(1.1) end
-- Let a queued screenshot happen: the host's driver waits for the second to turn.
local function settle()
    for _ = 1, 30 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/ids"] end
local function result(i) return record().results[i] or {} end
local function enter(id) WoW.fire("OBJECT_ENTERED_AOI", WoW.objectGUID(id)) end
local function leave(id) WoW.fire("OBJECT_LEFT_AOI", WoW.objectGUID(id)) end

check(T.Probe.log == db.log, "its ForeverProbe log is NodeRadarProbeDB.log, bound at ADDON_LOADED")
check(logged("loaded %(1 loads%)"), "loaded")

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

WoW.blips = { { "Peacebloom", 30, -20 } }
for _, cmd in ipairs({ "state", "under", "vignettes", "sound", "ring", "point", "sweep", "sweep soft", "radar 1",
                       "stop", "soft on", "soft off", "ping 5 5" }) do
    fp("nr " .. cmd)
end
check(logged("minimap 198%.0x198%.0 at %(800%.0, 500%.0%) in its units; effective scale 1%.200"), "state: the map's rect")
check(logged("2 tracking types; gathering on: none"), "state: Find Herbs listed, off")
check(logged("mouseover: nil; cursor 0, 0; on the minimap false"), "under: nothing")
check(logged("0 vignettes"), "vignettes")
check(logged("PlaySound%(3175, Master%): returned willPlay=true"), "sound: MAP_PING")
check(logged("GetFileIDFromPath%(Interface\\Cooldown\\ping4%) = nil"), "ring: the texture looked up")
check(logged("point: no blip kept"), "point needs a kept blip")
check(logged("sweep screen: 0 names in 625 points"), "sweep, cursor off the map: nothing (round 1)")
check(logged("sweep screen soft: 1 names in 625 points, [%d.]+ ms: Peacebloom %(30, %-20%) x3 #ffffff"),
    "sweep soft: the blip, at the centre of its hits, with its colour")
check(logged("radar started with screen for 1 s"), "radar: screen pixels by default (round 2)")
check(logged("SetUsingSoftCursor%(true%)") and logged("SetUsingSoftCursor%(false%)"), "soft on and off")
check(logged("PingLocation%(5%.0, 5%.0%): returned; GetPingPosition 5, 5"), "ping: an offset")
check(logged("MINIMAP_PING unit=player x=5 y=5"), "...and its event, x and y in the right order")
eq(WoW.softCursor, false, "the soft cursor is left off")
eq(errors(), 0, "no command threw")
eq(#WoW.chat, 0, "nothing in chat")

--------------------------------------------------------------------------------
-- The procedure
--------------------------------------------------------------------------------

WoW.blips = {
    { "Peacebloom", 30, -20, kind = "herbs" },
    { "Burning Blade Medallion", -40, 60, colour = { 1, 0.82, 0 } },       -- a quest ready for turn-in
    { "Karuzo Loco", 5, 5, colour = { 0.25, 0.75, 0.25 } },               -- a group member
}

fp("steps nr ids")
eq(record().status, "active", "ids: started")
poll()
eq(record().at, 1, "waits for gathering tracking")
WoW.tracking[1].active = true
poll()
eq(result(1).status, "done", "Find Herbs on")
eq(result(2).status, "done", "the names read on arrival")
check(logged("sweep screen soft: 3 names .*Peacebloom %(30, %-20%) x3 #ffffff"), "...a herb, white")
check(logged("Burning Blade Medallion %(%-39, 61%) x%d+ #ffd100"), "...a quest, its colour")

S.Run()                                                    -- 3 toggle
check(T.state.toggle ~= nil, "the toggle started")
eq(WoW.tracking[1].active, false, "...Find Herbs went off")
WoW.drainTimers()
eq(WoW.tracking[1].active, true, "...and back on")
poll()                                                     -- 4
eq(result(4).check, "PASS", "the herb vanished while tracking was off, and tracking came back")
eq(#T.state.toggle.vanished, 1, "...only the herb")
eq(T.state.toggle.vanished[1], "Peacebloom", "...Peacebloom")
check(logged("toggle: back on true; .*; vanished while off and back: Peacebloom; gone and not back: nothing$"), "...logged")
S.Answer(true)                                             -- 5

WoW.leaveMap()                                             -- 6 walk
-- Sweeps while no object is in range pair nothing (they'd empty every pair).
fp("nr radar 1 soft")
WoW.advance(1.5)
eq(next(T.state.pairs), nil, "no pairs while nothing is in range")
enter(1618)                                                -- Peacebloom's node
enter(3000)                                                -- a chair
WoW.fire("OBJECT_ENTERED_AOI", "Player-4170-0A1B2C3D")
poll()
check(T.state.walk ~= nil and not T.state.walk.done, "the walk's radar started")
check(logged("AOI%+ GameObject 1618 %(GameObject%-0%-4170%-0%-12%-1618%-0000ABCDEF%)"), "a game object's ID from its GUID")
-- Back leaves the step: its radar stops by itself, no /fp nr stop.
local first = T.state.walk
S.Back()
eq(record().at, 5, "Back")
WoW.advance(1)
check(first.done, "Back stopped the walk's radar")
local frozen = first.sweeps
WoW.advance(2)
eq(first.sweeps, frozen, "...and it sweeps no more")
check(logged("radar stopped, its step was left: "), "...saying why")
S.Answer(true)                                             -- 5 again
poll()
check(T.state.walk ~= first and not T.state.walk.done, "back on the walk step, a new radar")
WoW.advance(1)
table.insert(WoW.blips, { "Silverleaf", -50, 40, kind = "herbs" })
leave(3000)
enter(1617)                                                -- Silverleaf's node
WoW.advance(1)
table.remove(WoW.blips, 1)                                 -- Peacebloom behind us
leave(1618)
WoW.advance(1)
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-3-4170-0-1-2366-0000", 2366)
check(logged("UNIT_SPELLCAST_SENT spell=2366 target=Silverleaf"), "a gathering cast's target logged")
WoW.closest[1617] = { 0.4, 0.6, 12 }
WoW.closestSecret = true
S.DoneByHand()
eq(result(7).status, "done", "stopped and paired on arrival")
check(T.state.walk.done, "...the radar really stopped")
check(logged("pairs: .*Peacebloom = %[1618%]"), "Peacebloom paired with its node's ID")
check(logged("pairs: .*Silverleaf = %[1617%]"), "Silverleaf with its")
check(logged("pairs: Burning Blade Medallion = %[%]"), "the quest with none")
check(logged("ClosestGameObjectPosition%(1617%): returned n=3 <secret>, <secret>, <secret>"), "a secret answer shown as such")
check(logged("AOI events: GameObject%+=3 GameObject%-=2 Player%+=1"), "the AOI events counted by kind")
eq(record().at, 8, "at the reload step")
eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "still nothing in chat")
eq(WoW.softCursor, false, "the soft cursor is off at the end")
fp("steps stop")

-- Stop during the walk: the radar stops with the procedure (Codex on #5).
fp("steps nr ids")
for _ = 1, 30 do if record().at < 6 then S.Skip() end end
eq(record().at, 6, "skipped to the walk")
poll()
local walk = T.state.walk
check(walk and not walk.done, "the walk's radar runs")
fp("steps stop")
eq(record().status, "stopped", "procedure stopped")
WoW.advance(1)
check(walk.done, "Stop stopped the radar")
frozen = walk.sweeps
WoW.advance(2)
eq(walk.sweeps, frozen, "...and it sweeps no more")
-- A radar from the command isn't the procedure's: it runs with none active.
fp("nr radar soft")
WoW.advance(2)
check(T.state.radar.sweeps >= 5 and not T.state.radar.done, "the command's radar keeps sweeping")
fp("nr stop")
check(T.state.radar.done, "...until /fp nr stop")

--------------------------------------------------------------------------------
-- Clients where a way doesn't work must not pass
--------------------------------------------------------------------------------

-- Tracking can't be turned back on from an addon: the toggle says so.
WoW.blips = { { "Peacebloom", 30, -20, kind = "herbs" } }
WoW.refuseTrackingOn = true
fp("nr toggle")
WoW.drainTimers()
eq(T.state.toggle.back, false, "a refused SetTracking on reads as not back on")
check(logged("toggle: back on false"), "...logged")
WoW.refuseTrackingOn = false
WoW.tracking[1].active = true

-- (Codex on #8) A herb someone else gathers mid-test vanishes and never comes
-- back: it's "gone", not a node.
WoW.blips = { { "Peacebloom", 30, -20, kind = "herbs" } }
fp("nr toggle")
WoW.flushTimers(1.5)                                       -- the middle sweep, tracking off
WoW.blips = {}                                             -- gathered by someone else
WoW.drainTimers()
eq(#T.state.toggle.vanished, 0, "a herb that never comes back isn't a node")
eq(T.state.toggle.gone[1], "Peacebloom", "...it's gone")
check(logged("gone and not back: Peacebloom"), "...logged")

-- (Codex on #8) A failed middle sweep is inconclusive, never "everything vanished".
WoW.blips = { { "Peacebloom", 30, -20, kind = "herbs" }, { "Burning Blade Medallion", -40, 60 } }
fp("nr toggle")
local rect = Minimap._rect
Minimap._rect = nil                                        -- the geometry unreadable for the middle sweep
WoW.flushTimers(1.5)
Minimap._rect = rect
WoW.drainTimers()
eq(#T.state.toggle.vanished, 0, "a failed middle sweep finds no node")
check(T.state.toggle.failed and T.state.toggle.failed:find("middle sweep failed"), "...inconclusive, saying why")
check(logged("INCONCLUSIVE: middle sweep failed"), "...logged")
eq(WoW.tracking[1].active, true, "...and tracking is back on")

-- (Codex on #8, follow-up) Point reads that fail in the middle sweep, the
-- geometry readable: the quest would seem to vanish and come back. Inconclusive.
WoW.blips = { { "Burning Blade Medallion", -40, 60 } }
fp("nr toggle")
WoW.mouseoverThrows = true
WoW.flushTimers(1.5)
WoW.mouseoverThrows = false
WoW.drainTimers()
eq(#T.state.toggle.vanished, 0, "a middle sweep with point errors finds no node")
check(T.state.toggle.failed and T.state.toggle.failed:find("middle sweep had 625 point errors in 625"),
    "...inconclusive, with the count: " .. tostring(T.state.toggle.failed))
eq(WoW.tracking[1].active, true, "...and tracking is back on")
WoW.blips = { { "Peacebloom", 30, -20, kind = "herbs" } }

-- Tracking that never goes off is inconclusive too.
WoW.refuseTrackingOff = true
fp("nr toggle")
WoW.drainTimers()
eq(T.state.toggle.failed, "tracking never went off", "tracking that stays on proves nothing")
WoW.refuseTrackingOff = false

-- The soft cursor does nothing: with the cursor off the map, no convention.
WoW.softIgnored = true
WoW.hover(30, -20)
fp("nr hover")
WoW.leaveMap()
fp("nr point soft")
WoW.drainTimers()
eq(#T.state.softPoints.working, 0, "a soft cursor that does nothing passes no convention")
eq(WoW.softCursor, false, "point soft turns the soft cursor off when it's done")
WoW.softIgnored = false

-- The mouseover never moves: the hover stays readable from anywhere, so the
-- far point reads it too and no convention may pass.
WoW.mouseoverStuck = true
WoW.hover(30, -20)
fp("nr hover")
WoW.cursorOnMap = false                                    -- the stuck client still reads the hover
fp("nr point")
WoW.drainTimers()
eq(#T.state.points.working, 0, "a mouseover that never moves passes no convention")
check(logged("point screen .*far STALE Peacebloom"), "...the far point caught it")
WoW.mouseoverStuck = false

--------------------------------------------------------------------------------
-- Every widget method called exists on this client (the dump's widget walk,
-- else a documented function of that name).
--------------------------------------------------------------------------------

local f = io.open(WoW.DUMP, "r")
if f then
    local widget, documented = {}, {}
    for line in f:lines() do
        local wm = line:match("^(%a+:%a+)%s*$")
        if wm then widget[wm] = true end
        local fn = line:match("^([%a_]+)%(")
        if fn then documented[fn] = true end
    end
    f:close()
    local n = 0
    for name in pairs(WoW.methodsCalled) do
        n = n + 1
        check(widget[name] or documented[name:match(":(%a+)$")], "method exists on Forever: " .. name)
    end
    for _, m in ipairs({ "UpdateMouseoverAtPoint", "SetUsingSoftCursor", "PingLocation", "GetPingPosition" }) do
        check(WoW.methodsCalled["Minimap:" .. m], "called on the Minimap: " .. m)
    end
    check(n >= 10, "recorded the method calls (" .. n .. ")")
else
    io.write("  method check SKIPPED (no API dump at " .. WoW.DUMP .. ")\n")
end

done("test_probe")
