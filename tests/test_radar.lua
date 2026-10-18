-- The radar's cadence (the owner, release check): about 4 yards of movement
-- between sweeps (2 made too much garbage, #11), so it follows the speed
-- (40% -> 60% -> 100%) as it changes; never faster than 0.5 s; standing still,
-- the idle interval (2 s by default).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
local NR = loadAddon()
NR.db.learn = false

-- Sweeps in a stretch of time, counted by the reads each makes.
local reads = 0
local real = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function() reads = reads + 1; return real() end
NR.Scan.Sweep()
local PER = reads
local function sweepsIn(seconds)
    reads = 0
    WoW.advance(seconds, 0.02)
    return math.floor(reads / PER + 0.5)
end

local function near(actual, expected, label)
    check(math.abs(actual - expected) <= 1, ("%s: %d sweeps, expected about %d"):format(label, actual, expected))
end

eq(NR.db.interval, 2, "the idle interval: 2 s by default")
WoW.speed = 0
sweepsIn(3)                                                -- settle
near(sweepsIn(10), 5, "standing still: every 2 s")

WoW.speed = 7 * 0.4                                        -- walking, 40%
eq(math.floor(NR.Interval() * 100 + 0.5), 143, "40%: every 1.43 s")
near(sweepsIn(10), 7, "40% for 10 s")

WoW.speed = 7 * 0.6
eq(math.floor(NR.Interval() * 100 + 0.5), 95, "60%: every 0.95 s")
near(sweepsIn(10), 10, "60% for 10 s")

WoW.speed = 7                                              -- running, 100%
eq(math.floor(NR.Interval() * 100 + 0.5), 57, "100%: every 0.57 s")
near(sweepsIn(10), 17, "100% for 10 s")

WoW.speed = 7 * 3                                          -- far faster than running
eq(NR.Interval(), 0.5, "never faster than 0.5 s")

WoW.speed = 0
eq(NR.Interval(), 2, "stopping: back to the idle interval")
NR.db.interval = 1
eq(NR.Interval(), 1, "the idle interval is a setting")
WoW.speed = 0.5                                            -- creeping: never slower than idle
eq(NR.Interval(), 1, "moving slowly: never slower than standing still")

-- An unreadable speed counts as standing still.
local realSpeed = GetUnitSpeed
GetUnitSpeed = function() return WoW.Secret("speed") end
eq(NR.Interval(), 1, "a secret speed: the idle interval")
GetUnitSpeed = realSpeed

C_TooltipInfo.GetMinimapMouseover = real
done("test_radar")
