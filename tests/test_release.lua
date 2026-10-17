-- The release procedure (/fp steps nr release, #3): NodeRadarProbe driving
-- NodeRadar end to end on the stubbed client. The global cooldown of the
-- restore, seen and not seen; NodeRadar's learning paused for the probe's own
-- toggle and put back (also after a reload); learning by toggle and by
-- gathering; alerts counted; /nr test; a pending restore after a reload; the
-- persistence mark. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)
C_AddOns.IsAddOnLoaded = function(name) return name == "GlassMiniMap", name == "GlassMiniMap" end

WoW.tracking[1].active = true                              -- Find Herbs, before the login
local NR = loadAddon()
local FP = loadForeverProbe()
local T = loadProbe()._test
local S = FP.Steps
local db = NodeRadarProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 30 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/release"] end
local function result(i) return record().results[i] or {} end

-- The global cooldown, by the command: none when the restore costs none.
WoW.trackingGCD = false
fp("nr toggle gcd")
WoW.flushTimers(1.5)
WoW.advance(2.2)
WoW.drainTimers()
check(T.state.gcd and T.state.gcd.done and not T.state.gcd.seen, "no global cooldown: none seen")
check(logged("gcd after the restore: none seen"), "...logged")
WoW.trackingGCD = true

WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
fp("steps nr release")
poll()
eq(result(1).status, "done", "NodeRadar ready")
eq(result(2).status, "done", "the state read on arrival")
check(logged("NodeRadar: learn true, cooldown 5, interval 0%.5; learned 0 nodes and 0 others; skins GlassMiniMap"),
    "...NodeRadar's settings and the skin logged")

S.Run()                                                    -- 3 toggle
eq(NR.db.learn, false, "NodeRadar's learning paused for the probe's toggle")
eq(db.restoreLearn, true, "...its setting saved first")
WoW.flushTimers(1.5)                                       -- off, middle, restore (the GCD starts)
WoW.advance(2.2)                                           -- the watch
WoW.drainTimers()                                          -- the after sweep
poll()
eq(result(4).check, "PASS", "the restore measured")
check(T.state.gcd.seen, "...the global cooldown seen")
check(logged("gcd after the restore: SEEN .*action slots 1 2 3"), "...on the action bar's slots")
eq(NR.db.learn, true, "NodeRadar's learning put back")
eq(db.restoreLearn, nil, "...nothing left to restore")
S.Answer(true)                                             -- 5

-- 6: learning by toggle, NodeRadar's own experiment.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" }, { "Earthroot", -40, 50, kind = "herbs" } }
WoW.advance(12)                                            -- NodeRadar's gap since an experiment, and its own
poll()
eq(result(6).status, "done", "NodeRadar learned a name by itself")
check(tostring(result(6).detail):find("Earthroot = herbs"), "...Earthroot: " .. tostring(result(6).detail))

WoW.fire("UNIT_SPELLCAST_SENT", "player", "Mageroyal", "Cast-1", 2366)   -- 7 gather
poll()
eq(result(7).status, "done", "learned by gathering")
check(tostring(result(7).detail):find("Mageroyal = herbs"), "...Mageroyal")

poll()                                                     -- 8 walk
table.insert(WoW.blips, { "Silverleaf", 60, 10, kind = "herbs" })
WoW.advance(2)
check(logged("NodeRadar alert: Silverleaf"), "NodeRadar's alert counted")
S.DoneByHand()
S.Answer(true)                                             -- 9

S.Run()                                                    -- 10 /nr test
settle()
check(result(10).screenshots and #result(10).screenshots == 1, "the test alert, with a screenshot")
check(logged("NodeRadar alert: test"), "...NodeRadar's own alert")
S.Answer(true)                                             -- 11

S.Run()                                                    -- 12 off, as mid-experiment
eq(WoW.tracking[1].active, false, "tracking off")
eq(NR.charDb.pendingRestore, 2383, "...a restore pending, as NodeRadar would have it")
S.Skip()                                                   -- 13 the reload (simulated: the next login)
NR.charDb.pendingRestore = nil                             -- a broken restore: nothing pending, tracking off
poll()
eq(result(14).status, nil, "tracking still off: the step waits, however clear the pending flag")
NR.charDb.pendingRestore = 2383
WoW.fire("PLAYER_ENTERING_WORLD", false, true)
WoW.advance(3)                                             -- the restore, then its 2.5 s "after"
poll()
poll()
eq(result(14).status, "done", "NodeRadar restored tracking after the reload")
check(WoW.tracking[1].active, "...tracking on")

S.Run()                                                    -- 15 mark
eq(NR.db.cooldown, 7, "the mark: cooldown 7")
S.Skip()                                                   -- 16 the full exit (simulated)
eq(result(17).check, "PASS", "settings and learned names survived (in memory here; the real test is the exit)")
eq(NR.db.cooldown, 5, "...the cooldown put back")
eq(record().at, 18, "at the last reload")

-- A reload between the pause and the resume: learning comes back at login.
NR.db.learn = false
db.restoreLearn = true
WoW.fire("PLAYER_LOGIN")
eq(NR.db.learn, true, "learning put back at login after an interrupted toggle")
eq(db.restoreLearn, nil, "...once")

done("test_release")
