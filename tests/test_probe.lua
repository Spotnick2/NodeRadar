-- NodeRadarProbe: a ForeverProbe module (the host loaded from its checkout,
-- harness.lua's loadForeverProbe). Its commands run on the stubbed client and
-- log what they read, never to chat; the blips procedure runs end to end on a
-- client whose UpdateMouseoverAtPoint takes centre offsets, finds exactly
-- that convention, and finds none on a client that ignores the call. Every
-- widget method it calls exists on 70425. Runs locally only (CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- What the host touches beyond the shared stub (all in the 70425 dump).
rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

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
local function record() return FP.db.steps.records["NodeRadarProbe/blips"] end
local function result(i) return record().results[i] or {} end

check(T.Probe.log == db.log, "its ForeverProbe log is NodeRadarProbeDB.log, bound at ADDON_LOADED")
check(logged("loaded %(1 loads%)"), "loaded")

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

WoW.blips = { { "Peacebloom", 30, -20 } }
for _, cmd in ipairs({ "state", "under", "vignettes", "sound", "ring", "point", "sweep", "radar 1", "stop" }) do
    fp("nr " .. cmd)
end
check(logged("minimap 198%.0x198%.0 at %(800%.0, 500%.0%) in its units; effective scale 1%.200"), "state: the map's rect")
check(logged("2 tracking types; gathering on: none"), "state: Find Herbs listed, off")
check(logged("UpdateMouseoverAtPoint function, GetMinimapMouseover function"), "state: the candidate APIs")
check(logged("mouseover: nil; cursor 0, 0; on the minimap false"), "under: nothing")
check(logged("0 vignettes"), "vignettes")
check(logged("PlaySound%(3175, Master%): returned willPlay=true"), "sound: MAP_PING")
check(logged("GetFileIDFromPath%(Interface\\Cooldown\\ping4%) = nil"), "ring: the texture looked up")
check(logged("point: no blip kept"), "point needs a kept blip")
check(logged("sweep center: 1 names in 625 points, [%d.]+ ms: Peacebloom %(25, %-23%)"), "sweep: centre offsets find the blip")
check(logged("sweep screen: 0 names"), "...pixels don't, on this client")
check(logged("radar screen: 0 sweeps"), "radar ran (the first convention: no blip kept yet) and stopped")
eq(errors(), 0, "no command threw")
eq(#WoW.chat, 0, "nothing in chat")

--------------------------------------------------------------------------------
-- The procedure
--------------------------------------------------------------------------------

fp("steps nr blips")
eq(record().status, "active", "blips: started")
S.Next()                                                   -- 1 go outdoors
poll()
eq(record().at, 2, "waits for gathering tracking")
WoW.tracking[1].active = true
poll()
eq(result(2).status, "done", "Find Herbs on")
eq(result(3).status, "done", "the state read on arrival")
eq(record().at, 4, "then waits for a hovered blip")
poll()
eq(record().at, 4, "...still, with nothing hovered")

WoW.hover(31, -19)                                         -- 4 hover
poll()
settle()
eq(result(4).status, "done", "the hovered blip kept")
check(result(4).screenshots and #result(4).screenshots == 1, "...with a screenshot")
check(logged("hovered Peacebloom at cursor %(1116%.0, 696%.0%) px, %(31%.0, %-19%.0%) from the map's centre"),
    "...its pixels and centre offset logged")

poll()                                                     -- 5 conventions
eq(record().at, 5, "waits while the cursor is on the map")
eq(T.state.points, nil, "...trying nothing yet")
WoW.cursorOnMap, WoW.mouseoverAt = false, nil              -- the client's hover goes with the cursor
poll()
WoW.drainTimers()
poll()
eq(result(5).check, "PASS", "a convention read the blip")
eq(#T.state.points.working, 1, "...exactly one")
eq(T.state.points.working[1], "center", "...centre offsets")
check(logged("point center %(31%.000, %-19%.000%): far nothing; at once Peacebloom; 0%.1 s later Peacebloom HIT"),
    "...logged with its arguments")
check(logged("point screen %(1116%.000, 696%.000%): far nothing; at once nil"), "...pixels read nothing")

S.Run()                                                    -- 6 sweep
eq(result(6).check, "PASS", "the sweep found the hovered blip")
S.Answer(false)                                            -- 7

poll()                                                     -- 8 sweeps while hovering
eq(record().at, 8, "waits for the cursor on the blip")
WoW.hover(31, -19)
poll()
check(T.state.hoverJob ~= nil, "hovered sweeps started")
WoW.advance(11)
eq(result(8).check, "PASS", "the mouseover read the blip after every sweep (put back on the cursor)")
check(T.state.hoverJob.sweeps >= 30, "...about 3 sweeps a second: " .. T.state.hoverJob.sweeps)
S.Answer(false)                                            -- 9

WoW.mounted = true                                         -- 10 mount
WoW.fire("PLAYER_MOUNT_DISPLAY_CHANGED")
eq(result(10).check, "PASS", "mounted")
check(logged("PLAYER_MOUNT_DISPLAY_CHANGED; IsMounted true"), "...the event logged")

WoW.cursorOnMap, WoW.mouseoverAt = false, nil              -- 11 ride
poll()
check(T.state.ride ~= nil, "the radar started")
-- Back leaves the step: its radar stops by itself, no /fp nr stop.
local first = T.state.ride
S.Back()
eq(record().at, 10, "Back to the mount step")
WoW.advance(1)
check(first.done, "Back stopped the ride's radar")
local frozen = first.sweeps
WoW.advance(2)
eq(first.sweeps, frozen, "...and it sweeps no more")
check(logged("radar stopped, its step was left: "), "...saying why")
WoW.fire("PLAYER_MOUNT_DISPLAY_CHANGED")                   -- 10 again
poll()
check(T.state.ride ~= first and not T.state.ride.done, "back on the ride step, a new radar")
table.insert(WoW.blips, { "Copper Vein", -50, 40 })
WoW.advance(1)
check(logged("radar %+[%d.]+ s: Copper Vein at %(%-55, 41%)"), "a node coming into range logged")
WoW.cursorOnMap = true
WoW.advance(1)
WoW.cursorOnMap = false
S.DoneByHand()
eq(result(12).status, "done", "the radar stopped on arrival")
check(T.state.ride.done, "...really stopped")
check(T.state.ride.skipped >= 3, "...it skipped while the cursor was on the map")
check(logged("radar center: %d+ sweeps, %d+ skipped with the cursor on the map"), "...its summary logged")
S.Answer(true)                                             -- 13

S.Run()                                                    -- 14 MAP_PING
S.Answer(true)                                             -- 15
WoW.refusedSounds[8332] = true
S.Run()                                                    -- 16 v1's sound
check(logged("PlaySound%(8332, Master%): returned willPlay=false"), "a refused kit logged as willPlay=false")
S.Answer(false)                                            -- 17
WoW.files = { ["Interface\\Cooldown\\ping4"] = 130843 }
S.Run()                                                    -- 18 ring
settle()
check(result(18).screenshots and #result(18).screenshots == 1, "the ring screenshot")
check(logged("= 130843"), "...its file ID logged")
S.Answer(true)                                             -- 19
eq(record().at, 20, "at the reload step")
eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "still nothing in chat")
fp("steps stop")

-- Stop during the ride: the radar stops with the procedure (Codex on #5).
fp("steps nr blips")
for _ = 1, 20 do if record().at < 11 then S.Skip() end end
eq(record().at, 11, "skipped to the ride")
poll()
local ride = T.state.ride
check(ride and not ride.done, "the ride's radar runs")
fp("steps stop")
eq(record().status, "stopped", "procedure stopped")
WoW.advance(1)
check(ride.done, "Stop stopped the radar")
frozen = ride.sweeps
WoW.advance(2)
eq(ride.sweeps, frozen, "...and it sweeps no more")
-- A radar from the command isn't the procedure's: it runs with none active.
fp("nr radar")
WoW.advance(2)
check(T.state.radar.sweeps >= 5 and not T.state.radar.done, "the command's radar keeps sweeping")
fp("nr stop")
check(T.state.radar.done, "...until /fp nr stop")

--------------------------------------------------------------------------------
-- A client that ignores UpdateMouseoverAtPoint: the hover stays readable from
-- anywhere, so the far point reads it too and no convention may pass.
--------------------------------------------------------------------------------

WoW.mouseoverStuck, WoW.mouseoverPoint = true, nil
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
    check(WoW.methodsCalled["Minimap:UpdateMouseoverAtPoint"], "the candidate was called on the Minimap")
    check(n >= 10, "recorded the method calls (" .. n .. ")")
else
    io.write("  method check SKIPPED (no API dump at " .. WoW.DUMP .. ")\n")
end

done("test_probe")
