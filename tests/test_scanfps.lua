-- #104: the background frame rate raised to 60 while the scan runs on this character
-- (`scanFps`, per character, off), only while a search is under way (and HOLD s after; the owner):
-- the player's maxFPSBk saved and put back when it ends,
-- a change by someone else kept and never claimed again until the option is off and on, nothing
-- written in combat, an uncapped or high value left alone, logout and login (ScanFps.lua).

local function fresh(opts)
    opts = opts or {}
    dofile("tests/wow_stubs.lua")
    dofile("tests/harness.lua")
    NodeRadar, NodeRadarDB, NodeRadarCharDB = nil, nil, nil
    WoW.build = "70862"
    WoW.tracking[1].active = true
    WoW.cvars.maxFPSBk = opts.fps or "30"
    WoW.cvars.useMaxFPSBk = opts.cap or "1"
    local db = opts.db or { moveScan = true, moveScanAsked = true }
    if opts.beforeLoad then opts.beforeLoad() end
    local NR = loadAddon({ db = db, charDb = opts.charDb or { scanFps = true } })
    NR.db.learn = false
    -- A search under way unless a case says otherwise (Locate's own windows are test_locate's).
    SEARCH = opts.search ~= false
    NR.Locate.Busy = function() return SEARCH end
    return NR
end
local function secs(s) for _ = 1, math.floor(s / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end end
local function fps() return WoW.cvars.maxFPSBk end

-- Off: nothing.
local NR = fresh({ charDb = {} })
secs(2)
check(fps() == "30" and NR.db.fpsClaim == nil, "the option off: maxFPSBk untouched")

-- On, the scan on: raised, the old value saved.
NR = fresh()
secs(1.5)
check(fps() == "60", "on, the scan on: maxFPSBk raised to 60 (got " .. tostring(fps()) .. ")")
check(NR.db.fpsClaim and NR.db.fpsClaim.old == "30" and NR.db.fpsClaim.ours == "60", "...the player's 30 saved")
-- The scan turned off: put back.
NR.Set("moveScan", false)
secs(1.5)
check(fps() == "30" and NR.db.fpsClaim == nil, "the scan off: 30 put back, the claim gone")
-- On again: raised again.
NR.Set("moveScan", true)
secs(1.5)
check(fps() == "60", "the scan on again: raised again")
-- A lasting reason it can't run (no gathering tracking): put back.
WoW.tracking[1].active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
secs(1.5)
check(fps() == "30" and NR.db.fpsClaim == nil, "no gathering tracking (the scan can't run): put back")
WoW.tracking[1].active = true
WoW.fire("MINIMAP_UPDATE_TRACKING")
secs(1.5)
check(fps() == "60", "tracking back: raised")

-- Only while a search is under way: none, nothing; it ends, put back HOLD s later; a new one
-- within HOLD keeps it raised.
NR = fresh({ search = false })
secs(3)
check(fps() == "30" and NR.db.fpsClaim == nil, "the scan on, no search: left at 30")
SEARCH = true
secs(1.2)
check(fps() == "60", "a search starts: raised")
SEARCH = false
secs(NR.ScanFps.HOLD - 1.5)
check(fps() == "60", "the search over: still raised within HOLD")
SEARCH = true
secs(1.2)
SEARCH = false
secs(NR.ScanFps.HOLD - 1.5)
check(fps() == "60", "a new search within HOLD: kept raised, no flap")
secs(3)
check(fps() == "30" and NR.db.fpsClaim == nil, "HOLD s after the last search: put back")
NR = fresh()
secs(1.5)

-- Someone else's change while claimed: kept, no claim again until the option is off and on.
C_CVar.SetCVar("maxFPSBk", "45")
secs(3)
check(fps() == "45" and NR.db.fpsClaim == nil and NR.charDb.scanFpsCancelled == true,
    "the player set 45: theirs kept, the claim dropped, cancelled (got " .. tostring(fps()) .. ")")
NR.Set("moveScan", false); secs(1.2); NR.Set("moveScan", true); secs(1.5)
check(fps() == "45", "...the scan off and on: still not claimed")
-- Even back to the old value by the player: cancelled, so not taken.
NR.charDb.scanFps = false; NR.ScanFps.Toggle()
NR.charDb.scanFps = true; NR.ScanFps.Toggle()
secs(1.5)
check(fps() == "60" and NR.db.fpsClaim.old == "45", "the option off and on: claimed again from 45")
NR.charDb.scanFps = false; NR.ScanFps.Toggle()
secs(0.2)
check(fps() == "45" and NR.db.fpsClaim == nil, "the option off: 45 put back at once")

-- Left alone: the cap off, an unlimited 0, a value at or above 60.
for _, case in ipairs({ { cap = "0", why = "the background cap off" }, { fps = "0", why = "unlimited (0)" },
                        { fps = "60", why = "already 60" }, { fps = "100", why = "above 60" } }) do
    NR = fresh({ fps = case.fps, cap = case.cap })
    local before = fps()
    secs(2)
    check(fps() == before and NR.db.fpsClaim == nil, case.why .. ": left alone")
end

-- Combat: nothing written; the put-back waits for its end.
NR = fresh()
secs(1.5)
check(fps() == "60", "(control) claimed")
WoW.combat = true
NR.Set("moveScan", false)
secs(3)
check(fps() == "60" and NR.db.fpsClaim ~= nil, "in combat: nothing written, the claim kept")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
secs(0.2)
check(fps() == "30" and NR.db.fpsClaim == nil, "combat over: put back")

-- An unreadable value, and a put-back that doesn't read back: the claim kept, tried again.
NR = fresh()
secs(1.5)
local realGet, realSet = C_CVar.GetCVar, C_CVar.SetCVar
C_CVar.GetCVar = function() return nil end
NR.Set("moveScan", false)
secs(2)
check(NR.db.fpsClaim ~= nil, "unreadable: the claim kept")
C_CVar.GetCVar = realGet
C_CVar.SetCVar = function() return true end          -- refused silently
secs(2)
check(fps() == "60" and NR.db.fpsClaim ~= nil, "a put-back that doesn't read back: the claim kept")
C_CVar.SetCVar = realSet
secs(1.5)
check(fps() == "30" and NR.db.fpsClaim == nil, "...tried again, put back")

-- Logout: ours put back, the claim kept; the next login judges it.
NR = fresh()
secs(1.5)
WoW.fire("PLAYER_LOGOUT")
check(fps() == "30" and NR.db.fpsClaim ~= nil, "logout: 30 put back, the claim kept")
local saved, savedChar = NR.db, NR.charDb
-- Login, the put-back stuck (30), the scan on: claimed again.
NR = fresh({ db = saved, charDb = savedChar })
secs(1.5)
check(fps() == "60" and NR.db.fpsClaim and NR.db.fpsClaim.old == "30", "login, the old value, the scan on: claimed again")
WoW.fire("PLAYER_LOGOUT")
saved, savedChar = NR.db, NR.charDb
-- Login, the scan off this time: the claim cleared, 30 left.
saved.moveScan = false
NR = fresh({ db = saved, charDb = savedChar })
secs(1.5)
check(fps() == "30" and NR.db.fpsClaim == nil, "login, the old value, the scan off: the claim cleared, 30 left")
-- Login, ours still there (the logout put-back didn't stick), the scan off: put back.
NR = fresh({ fps = "60", db = { moveScan = false, moveScanAsked = true, fpsClaim = { old = "30", ours = "60" } } })
secs(1.5)
check(fps() == "30" and NR.db.fpsClaim == nil, "login, ours still set, the scan off: put back")
-- Login, a third value: the player's, kept, cancelled.
NR = fresh({ fps = "45", db = { moveScan = true, moveScanAsked = true, fpsClaim = { old = "30", ours = "60" } } })
secs(2)
check(fps() == "45" and NR.db.fpsClaim == nil and NR.charDb.scanFpsCancelled == true,
    "login, someone else's 45: kept, the claim dropped, cancelled")
-- After login, the player setting the old value back is theirs too (only the login read takes it for ours).
NR = fresh()
secs(1.5)
C_CVar.SetCVar("maxFPSBk", "30")
secs(2)
check(fps() == "30" and NR.charDb.scanFpsCancelled == true, "the player putting 30 back mid-session: theirs, not claimed again")

-- Codex on PR #129.
-- 1. Our logout put-back's CVAR_UPDATE arriving late (measured for the marker's CVars): no check
-- after logout, so the claim and the option survive for the next login.
NR = fresh()
secs(1.5)
local realSet2 = C_CVar.SetCVar
C_CVar.SetCVar = function(name, value) WoW.cvars[name] = value; return true end   -- the event held back
WoW.fire("PLAYER_LOGOUT")
C_CVar.SetCVar = realSet2
WoW.fire("CVAR_UPDATE", "maxFPSBk", "30")                                          -- ...delivered late
secs(2)
check(fps() == "30" and NR.db.fpsClaim ~= nil and NR.charDb.scanFpsCancelled == nil,
    "a late CVAR_UPDATE after logout: the claim kept, the option not cancelled")

-- 2. A raise that takes but doesn't read back at once: the original kept, put back later.
NR = fresh({ search = false })
secs(1.5)
local realGet2, blind = C_CVar.GetCVar, false
C_CVar.GetCVar = function(name) if blind and name == "maxFPSBk" then blind = false; return nil end return realGet2(name) end
local realSet3 = C_CVar.SetCVar
C_CVar.SetCVar = function(name, value) realSet3(name, value); if name == "maxFPSBk" then blind = true end end
SEARCH = true
secs(1.2)
C_CVar.SetCVar = realSet3
check(fps() == "60" and NR.db.fpsClaim and NR.db.fpsClaim.old == "30", "a raise unreadable at once: the original saved")
secs(1.2)
check(NR.db.fpsClaim and not NR.db.fpsClaim.pending, "...confirmed at the next readable check")
NR.charDb.scanFps = false; NR.ScanFps.Toggle()
check(fps() == "30" and NR.db.fpsClaim == nil, "...and put back when the option goes off")
C_CVar.GetCVar = realGet2
-- A raise that didn't take at all: the pending claim dropped at the next check, nothing cancelled.
NR = fresh({ search = false })
secs(1.5)
local realSet4 = C_CVar.SetCVar
C_CVar.SetCVar = function() end
SEARCH = true
secs(1.2)
C_CVar.SetCVar = realSet4
SEARCH = false
secs(1.2)
check(fps() == "30" and NR.charDb.scanFpsCancelled == nil, "a raise that didn't take: nothing cancelled, 30 left")

-- A put-back that takes but doesn't read back at once: done at the next readable check, not taken
-- for someone else's change; a later search claims again without an off and on.
NR = fresh()
secs(1.5)
check(fps() == "60", "(control) claimed")
local realGet5, blind5 = C_CVar.GetCVar, false
C_CVar.GetCVar = function(name) if blind5 and name == "maxFPSBk" then blind5 = false; return nil end return realGet5(name) end
local realSet5 = C_CVar.SetCVar
C_CVar.SetCVar = function(name, value) realSet5(name, value); if name == "maxFPSBk" then blind5 = true end end
SEARCH = false
secs(NR.ScanFps.HOLD + 1.5)
C_CVar.SetCVar, C_CVar.GetCVar = realSet5, realGet5
secs(1.2)
check(fps() == "30" and NR.db.fpsClaim == nil and NR.charDb.scanFpsCancelled == nil,
    "a put-back unreadable at once: done at the next check, the option not cancelled")
SEARCH = true
secs(1.2)
check(fps() == "60", "...a new search claims again")

-- 3. The first read after login unreadable: the login check waits for a readable value.
local loginBlind = 2
NR = fresh({ db = { moveScan = true, moveScanAsked = true, fpsClaim = { old = "30", ours = "60" } },
    beforeLoad = function()
        local g = C_CVar.GetCVar
        C_CVar.GetCVar = function(name)
            if name == "maxFPSBk" and loginBlind > 0 then loginBlind = loginBlind - 1; return nil end
            return g(name)
        end
    end })
secs(3)
check(fps() == "60" and NR.charDb.scanFpsCancelled == nil and NR.db.fpsClaim and NR.db.fpsClaim.old == "30",
    "an unreadable first read at login: then 30 read as our put-back, claimed again, not cancelled")

done("test_scanfps")
