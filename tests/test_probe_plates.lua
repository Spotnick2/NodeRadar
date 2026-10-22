-- The plates procedure (/fp steps nr plates, #78): the game's soft-interact
-- nameplates on herbs and ores: the CVars set and read back, the plates held
-- in each view, a star of ours anchored to the soft target's plate, the range
-- from a plate going, a CVar changed in combat, what the client reset at a
-- reload; everything put back however the round ends, a change of the
-- player's kept. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.cvars.softTargetInteract = "1"
WoW.cvars.SoftTargetIconGameObject = "0"
WoW.cvars.SoftTargetInteractArc = "0"
WoW.cvars.SoftTargetInteractRange = "10.000000"
WoW.cvars.SoftTargetInteractOnlyInRange = "1"
WoW.cvars.SoftTargetInteractRangeIsHard = "0"           -- already as wanted: not saved
WoW.cvars.nameplateGameObjectMaxDistance = "40"
-- SoftTargetNameplateInteract absent on this client
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
WoW.pos = { 0, 0, 1 }
local NR = loadAddon()
NR.Track.SetSmart(false)
local FP = loadForeverProbe()
local NS = loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y)
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    nodes[#nodes + 1] = n
    return n
end
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
    end
    WoW.blips = list
end
local function errors()
    local c = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then c = c + 1 end end
    return c
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function record() return FP.db.steps.records["NodeRadarProbe/plates"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function tick(s) for _ = 1, math.floor(s / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end end
local function settle() for _ = 1, 4 do tick(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end end
local function run(i, s) for _ = 1, s * 2 do if result(i).status == nil then place(); NR.Step(WoW.now); tick(0.5) end end end

-- 1: set up: the CVars set and read back, the compass on.
WoW.combat = true
fp("steps nr plates")
tick(1.2)
eq(result(1).status, nil, "in combat: waits")
WoW.combat = false
tick(1.2)
eq(result(1).status, "done", "set up: " .. detail(1))
eq(WoW.cvars.softTargetInteract, "3", "...interact targeting on")
eq(WoW.cvars.SoftTargetInteractRange, "60", "...its range 60")
check(detail(1):find("SoftTargetNameplateInteract nil"), "...an absent CVar named, not set")
check(detail(1):find("SoftTargetInteractRange 10%.000000 %-> 60"), "...each one read back")
eq(db.plates.saved.SoftTargetInteractRangeIsHard, nil, "...one already as wanted: nothing to put back")
eq(NR.db.compass, true, "...NodeRadar's compass on for the records")

-- 2: two Silverleafs in view, one the soft target, and a creature's plate.
local a = node("Silverleaf", 0, 20)
local b = node("Silverleaf", 20, 0)
WoW.plates = {
    { unit = "nameplate1", name = "Silverleaf", object = true, soft = true },
    { unit = "nameplate2", name = "Silverleaf", object = true },
    { unit = "nameplate3", name = "Mottled Boar" },
}
run(2, 14)
eq(result(2).status, "done", "near: " .. detail(2))
check(detail(2):find("near: 3 plates: nameplate1 Silverleaf %(object%) SOFT %d+%.%d yd"), "...each plate, the soft one, its distance")
check(detail(2):find("nameplate3 Mottled Boar %? yd"), "...a creature's plate, no record")
check(#db.plates.samples >= 18, "...sampled every half second")
settle()
S.Answer(true)                                             -- 3

-- 4: a star of ours at the bottom of the soft target's plate.
run(4, 8)
eq(result(4).status, "done", "the star: " .. detail(4))
local star = NS._platesTest.star()
local p1 = C_NamePlate.GetNamePlateForUnit("nameplate1")
check(star and star._shown and star._points[1][2] == p1 and star._points[1][3] == "BOTTOM", "...anchored to its plate's bottom")
eq(star._parent, UIParent, "...a child of UIParent, not of Blizzard's plate")
settle()
S.Answer(true)                                             -- 5

-- 6: behind a rock: the plate's alpha read.
WoW.plates[1].alpha = 0.4
run(6, 14)
eq(result(6).status, "done", "the rock: " .. detail(6))
check(detail(6):find("alpha 0%.4/0%.4"), "...the plate's alpha and its effective alpha")
settle()
S.Answer(false)                                            -- 7
S.Skip()                                                   -- 8: a slope
S.Skip()                                                   -- 9

-- 10: the plate goes walking away: its last distance.
tick(1.2)
eq(star._shown, false, "the star put away")
table.remove(WoW.plates, 1)
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
tick(1.2)
eq(result(10).status, "done", "the range: " .. detail(10))
check(detail(10):find("the plate went: Silverleaf at %d+%.%d yd"), "...with its distance")

-- 11: a CVar changed in combat and back.
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
tick(1.2)
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
tick(1.2)
eq(result(11).status, "done", "combat: " .. detail(11))
check(detail(11):find("in combat: SetCVar %-> true, read 59; back %-> true, read 60"), "...set and read back")

-- 12, 13: a reload; the client setting one back as it enters the world.
WoW.fire("PLAYER_LOGOUT")
FP.run = FP.run + 1
WoW.cvars.SoftTargetIconGameObject = "0"
WoW.fire("PLAYER_ENTERING_WORLD")
WoW.drainTimers()
WoW.fire("PLAYER_LOGIN")
S.Resume()
eq(result(12).status, "done", "reloaded")
tick(0.5)
eq(result(13).status, "done", "after the reload: " .. detail(13))
check(detail(13):find("after the reload: SoftTargetIconGameObject 0"), "...the one the client reset")
check(detail(13):find("at entering the world: SoftTargetIconGameObject 0; 2 s after: SoftTargetIconGameObject 0"),
    "...read as it entered the world, and after")

-- 14: the summary: everything put back.
tick(0.5)
eq(result(14).status, "done", "the summary: " .. detail(14))
eq(WoW.cvars.softTargetInteract, "1", "...interact targeting as it was")
eq(WoW.cvars.SoftTargetInteractRange, "10.000000", "...its range as it was")
eq(WoW.cvars.nameplateGameObjectMaxDistance, "40", "...the plates' distance as it was")
eq(NR.db.compass, false, "...NodeRadar's compass as it was")
eq(NS._platesTest.watch.on, nil, "...the sampler gone")
eq(db.plates.saved, nil, "...nothing left to put back")
fp("steps stop")

-- Stopped after the setup: put back, but a change of the player's kept.
fp("steps nr plates")
tick(1.2)
eq(WoW.cvars.SoftTargetInteractRange, "60", "a new round: the range 60")
WoW.cvars.SoftTargetInteractArc = "1"                      -- the player's own change
fp("steps stop")
tick(1)
eq(WoW.cvars.softTargetInteract, "1", "stopped: interact targeting put back")
eq(WoW.cvars.SoftTargetInteractRange, "10.000000", "...its range")
eq(WoW.cvars.SoftTargetInteractArc, "1", "...the player's change kept")
eq(NR.db.compass, false, "...NodeRadar's compass as it was")
eq(db.plates.saved, nil, "...nothing left to put back")

-- The ablation: the plate here needs SoftTargetNameplateInteract and
-- SoftTargetIconGameObject, nothing else; each CVar put back alone in turn.
local function arec() return FP.db.steps.records["NodeRadarProbe/ablate"] end
local function ares(i) return arec().results[i] or {} end
local function adetail(i) return tostring(ares(i).detail or ares(i).lastError) end
local function plateNeeds()
    local on = WoW.cvars.SoftTargetNameplateInteract == "1" and WoW.cvars.SoftTargetIconGameObject == "1"
    WoW.plates = on and { { unit = "nameplate4", name = "Silverleaf", object = true, soft = true } } or {}
end
WoW.pos = { a.north - 13, a.west, 1 }                     -- 13 yards from a
WoW.cvars.SoftTargetNameplateInteract = "0"                -- this time the client has it
fp("steps nr ablate")
tick(1.2)
eq(ares(1).status, "done", "the ablation set up: " .. adetail(1))
for _ = 1, 120 do
    if ares(2).status == nil then plateNeeds(); place(); NR.Step(WoW.now); tick(0.5) end
end
eq(ares(2).status, "done", "the ablation: " .. adetail(2))
check(adetail(2):find("Silverleaf at 13%.%d yd"), "...at 13 yards")
check(adetail(2):find("without SoftTargetNameplateInteract: NO PLATE"), "...the plate's CVar needed")
check(adetail(2):find("without SoftTargetIconGameObject: NO PLATE"), "...the object icon's needed")
check(adetail(2):find("without SoftTargetInteractArc: the plate kept"), "...the arc not")
check(adetail(2):find("without nameplateGameObjectMaxDistance: the plate kept"), "...the plates' distance not")
check(not adetail(2):find("come back"), "...the plate back after each, ours set again")
tick(1)
eq(ares(3).status, "done", "the summary: " .. adetail(3))
eq(WoW.cvars.softTargetInteract, "1", "...everything put back")
eq(WoW.cvars.SoftTargetInteractRange, "10.000000", "...the range too")
fp("steps stop")

-- softmark: NodeRadar's own marker in game; the probe turns it on and watches.
local function mrec() return FP.db.steps.records["NodeRadarProbe/softmark"] end
local function mres(i) return mrec().results[i] or {} end
local function mdetail(i) return tostring(mres(i).detail or mres(i).lastError) end
local function mrun(i, s) for _ = 1, s * 2 do if mres(i).status == nil then place(); NR.Step(WoW.now); tick(0.5) end end end
WoW.cvars.SoftTargetIconGameObject = "0"
WoW.plates = {}
fp("steps nr softmark")
tick(1.2)
eq(mres(1).status, "done", "softmark set up: " .. mdetail(1))
eq(NR.db.marker, true, "...NodeRadar's marker on")
check(mdetail(1):find("softTargetInteract 3 %(claimed, old 1%)"), "...NodeRadar's own claims read")
WoW.plates = { { unit = "nameplate5", name = "Silverleaf", object = true, soft = true } }
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
mrun(2, 3)
eq(mres(2).status, "done", "the stars near: " .. mdetail(2))
check(mdetail(2):find("near: the stars on nameplate5 Silverleaf"), "...on the soft target's plate")
settle()
S.Answer(true)                                             -- 3
S.Skip()                                                   -- 4: a slope
S.Skip()                                                   -- 5
S.Skip()                                                   -- 6: a rock
S.Skip()                                                   -- 7
NR.Track.Set(765, false)                                   -- Silverleaf skipped
mrun(8, 3)
eq(mres(8).status, "done", "a skipped node: " .. mdetail(8))
check(mdetail(8):find("a skipped Silverleaf targeted at .- no stars"), "...no stars")
NR.Track.Set(765, true)
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
tick(1.2)
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
tick(1.2)
eq(mres(9).status, "done", "combat: " .. mdetail(9))
check(mdetail(9):find("off in combat: softTargetInteract 3 %(claimed"), "...off in combat, nothing written")
check(mdetail(9):find("on again: softTargetInteract 3 %(claimed, old 1%)"), "...on again after")
WoW.fire("PLAYER_LOGOUT")
FP.run = FP.run + 1
WoW.fire("PLAYER_LOGIN")
S.Resume()
tick(0.5)
eq(mres(11).status, "done", "after the reload: " .. mdetail(11))
fp("steps stop")
tick(1)
eq(NR.db.marker, false, "stopped: NodeRadar's marker as it was")
eq(WoW.cvars.softTargetInteract, "1", "...its CVars put back by NodeRadar")
eq(NR.db.compass, false, "...the compass as it was")

eq(errors(), 0, "no step threw")
for _, l in ipairs(WoW.chat) do check(not l:find("plates"), "nothing of the probe in chat: " .. l) end
done("test_probe_plates")
