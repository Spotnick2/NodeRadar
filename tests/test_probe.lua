-- NodeRadarProbe: a ForeverProbe module (the host loaded from its checkout,
-- harness.lua's loadForeverProbe). Its commands run on the stubbed client and
-- log what they read, never to chat. The soft procedure (round 2 of #2) runs
-- end to end on a client modelled on round 1: a point counts only with the
-- cursor on the map or the soft cursor on, in centre offsets. It finds that
-- convention both ways, finds none where the soft cursor does nothing or the
-- mouseover never moves, and its radars stop with their step. Every widget
-- method it calls exists on 70450. Runs locally only (CI skips it).
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
local function record() return FP.db.steps.records["NodeRadarProbe/soft"] end
local function result(i) return record().results[i] or {} end

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
check(logged("UpdateMouseoverAtPoint function, SetUsingSoftCursor function, PingLocation function, GetMinimapMouseover function"),
    "state: the APIs measured")
check(logged("mouseover: nil; cursor 0, 0; on the minimap false"), "under: nothing")
check(logged("0 vignettes"), "vignettes")
check(logged("PlaySound%(3175, Master%): returned willPlay=true"), "sound: MAP_PING")
check(logged("GetFileIDFromPath%(Interface\\Cooldown\\ping4%) = nil"), "ring: the texture looked up")
check(logged("point: no blip kept"), "point needs a kept blip")
check(logged("sweep center: 0 names in 625 points"), "sweep, cursor off the map: nothing (round 1)")
check(logged("sweep center soft: 1 names in 625 points, [%d.]+ ms: Peacebloom %(30, %-20%) x3"),
    "sweep soft: the blip, at the centre of its hits")
check(logged("radar started with center for 1 s"), "radar: centre offsets by default")
check(logged("SetUsingSoftCursor%(true%)") and logged("SetUsingSoftCursor%(false%)"), "soft on and off")
check(logged("PingLocation%(5%.0, 5%.0%): returned; GetPingPosition 5, 5"), "ping: an offset")
check(logged("MINIMAP_PING unit=player x=5 y=5"), "...and its event, x and y in the right order")
eq(WoW.softCursor, false, "the soft cursor is left off")
eq(errors(), 0, "no command threw")
eq(#WoW.chat, 0, "nothing in chat")

--------------------------------------------------------------------------------
-- The procedure
--------------------------------------------------------------------------------

fp("steps nr soft")
eq(record().status, "active", "soft: started")
poll()
eq(record().at, 1, "waits for gathering tracking")
WoW.tracking[1].active = true
poll()
eq(result(1).status, "done", "Find Herbs on")
eq(result(2).status, "done", "the state read on arrival")
eq(record().at, 3, "then waits for a hovered blip")

WoW.hover(31, -19)                                         -- 3 hover
poll()
settle()
eq(result(3).status, "done", "the hovered blip kept")
check(result(3).screenshots and #result(3).screenshots == 1, "...with a screenshot")
check(logged("hovered Peacebloom at cursor %(1116%.0, 696%.0%) px, %(31%.0, %-19%.0%) from the map's centre"),
    "...its pixels and centre offset logged")

poll()                                                     -- 4 conventions, cursor on the map
eq(record().at, 4, "waits while the cursor is on the blip")
eq(T.state.points, nil, "...trying nothing yet")
WoW.hover(-60, 50)                                         -- an empty spot
poll()
WoW.drainTimers()
poll()
eq(result(4).check, "PASS", "a convention read the blip, the cursor on an empty spot")
eq(#T.state.points.working, 1, "...exactly one")
eq(T.state.points.working[1], "center", "...centre offsets")
check(logged("point center %(31%.000, %-19%.000%): far nothing; at once Peacebloom; 0%.1 s later Peacebloom HIT"),
    "...logged with its arguments")

poll()
eq(result(5).check, "PASS", "the sweep found the blip where it is")
check(logged("sweep center: 1 names .*%(the kept blip, where it is%)"), "...said so")

WoW.leaveMap()                                             -- 6 conventions, soft cursor
poll()
check(T.state.softPoints ~= nil, "soft conventions started")
eq(WoW.softCursor, true, "...with the soft cursor on")
WoW.drainTimers()
poll()
eq(result(6).check, "PASS", "a convention read the blip with the soft cursor, the cursor off the map")
eq(T.state.softPoints.working[1], "center", "...centre offsets")
eq(WoW.softCursor, false, "...then the soft cursor off")
check(logged("point %(soft%): the blip read back with center; cursor on the map false"), "...logged")

eq(result(7).check, "PASS", "the soft sweep found the blip where it is")   -- 7 ran on arrival
eq(WoW.softCursor, false, "...and turned the soft cursor off")

poll()                                                     -- 8 own hover after soft
eq(record().at, 8, "waits for the cursor on the blip")
WoW.hover(31, -19)
poll()
eq(result(8).status, "done", "the player's own hover reads the blip again")

poll()                                                     -- 9 soft sweeps while hovering
check(T.state.hoverJob ~= nil, "hovered soft sweeps started")
WoW.advance(11)
eq(result(9).check, "PASS", "the mouseover read the blip after every sweep")
check(T.state.hoverJob.soft and T.state.hoverJob.sweeps >= 30, "...about 3 soft sweeps a second: " .. T.state.hoverJob.sweeps)
S.Answer(false)                                            -- 10

S.Run()                                                    -- 11 ping
settle()
eq(#WoW.pings, 2, "the kept blip pinged")
eq(WoW.pings[2][1], 31, "...at its offset x")
eq(WoW.pings[2][2], -19, "...and y")
check(result(11).screenshots and #result(11).screenshots == 1, "...with a screenshot")
S.Answer(true)                                             -- 12
S.Unsure()                                                 -- 13

WoW.leaveMap()                                             -- 14 walk
poll()
check(T.state.walk ~= nil and T.state.walk.soft, "the walk's radar started, soft")
-- Back leaves the step: its radar stops by itself, no /fp nr stop.
local first = T.state.walk
S.Back()
eq(record().at, 13, "Back")
WoW.advance(1)
check(first.done, "Back stopped the walk's radar")
local frozen = first.sweeps
WoW.advance(2)
eq(first.sweeps, frozen, "...and it sweeps no more")
check(logged("radar stopped, its step was left: "), "...saying why")
S.Unsure()                                                 -- 13 again
poll()
check(T.state.walk ~= first and not T.state.walk.done, "back on the walk step, a new radar")
table.insert(WoW.blips, { "Copper Vein", -50, 40 })
WoW.advance(1)
check(logged("radar %+[%d.]+ s: Copper Vein at %(%-51, 41%)"), "a node coming into range logged, where it is")
WoW.hover(-60, 50)
WoW.advance(1)
WoW.leaveMap()
S.DoneByHand()
eq(result(15).status, "done", "the radar stopped on arrival")
check(T.state.walk.done, "...really stopped")
check(T.state.walk.skipped >= 3, "...it skipped while the cursor was on the map")
check(logged("radar center soft: %d+ sweeps, %d+ skipped with the cursor on the map"), "...its summary logged")
S.Answer(true)                                             -- 16
WoW.files = { ["Interface\\Cooldown\\ping4"] = 131009 }
S.Run()                                                    -- 17 ring
settle()
eq(result(17).status, "done", "the ring shows (a real strata)")
check(result(17).screenshots and #result(17).screenshots == 1, "...with a screenshot")
S.Answer(true)                                             -- 18
eq(record().at, 19, "at the reload step")
eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "still nothing in chat")
eq(WoW.softCursor, false, "the soft cursor is off at the end")
fp("steps stop")

-- Stop during the walk: the radar stops with the procedure (Codex on #5).
fp("steps nr soft")
for _ = 1, 30 do if record().at < 14 then S.Skip() end end
eq(record().at, 14, "skipped to the walk")
WoW.leaveMap()
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
-- Clients where it doesn't work must not pass
--------------------------------------------------------------------------------

-- The soft cursor does nothing: with the cursor off the map, no convention.
WoW.softIgnored = true
WoW.hover(31, -19)
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
WoW.hover(31, -19)
fp("nr hover")
WoW.cursorOnMap = false                                    -- the stuck client still reads the hover
fp("nr point")
WoW.drainTimers()
eq(#T.state.points.working, 0, "a mouseover that never moves passes no convention")
check(logged("point center .*far STALE Peacebloom"), "...the far point caught it")
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
