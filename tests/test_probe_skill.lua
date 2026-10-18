-- The skill and cultivation procedures (/fp steps nr skill, /fp steps nr
-- cultivation, #26): NodeRadarProbe reading the gathering skill lines, a
-- node's world tooltip, a skill-up, and Cultivation's two IDs and cooldown on
-- the stubbed client. A secret skill or cooldown never throws and never
-- passes as a number. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

-- What these procedures read beyond the shared stub (all in the 70450 dump).
WoW.skillLines = { [182] = { skillID = 182, name = "Herbalism", rank = 40, modifier = 0, maxRank = 75 } }
rawset(_G, "C_SkillInfo", { GetSkillLineInfoByID = function(id) return WoW.skillLines[id] end })
WoW.knownSpells = {}
rawset(_G, "C_SpellBook", { IsSpellKnown = function(id) return WoW.knownSpells[id] == true end })
WoW.race = { "Orc", "Orc", 2 }
rawset(_G, "UnitRace", function() return unpack(WoW.race) end)
WoW.worldTooltip = nil                                     -- the lines under the world cursor
C_TooltipInfo.GetWorldCursor = function()
    if not WoW.worldTooltip then return nil end
    local lines = {}
    for _, l in ipairs(WoW.worldTooltip) do
        lines[#lines + 1] = { leftText = l[1], leftColor = { r = l[2][1], g = l[2][2], b = l[2][3], a = 1 } }
    end
    return { type = 13, lines = lines }
end
WoW.spellCooldowns = {}
C_Spell.GetSpellCooldown = function(id)
    return WoW.spellCooldowns[id] or { startTime = 0, duration = 0, isEnabled = true, isActive = false, modRate = 1 }
end

local NR = loadAddon()
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
local function record(name) return FP.db.steps.records["NodeRadarProbe/" .. name] end
local function result(name, i) return record(name).results[i] or {} end
local RED, WHITE = { 1, 0.13, 0.13 }, { 1, 1, 1 }

--------------------------------------------------------------------------------
-- skill
--------------------------------------------------------------------------------

fp("steps nr skill")
eq(record("skill").status, "active", "skill: started")
eq(result("skill", 1).status, "done", "the skills read on arrival")
check(logged("skill 182 %(Herbalism%): .*rank.*40"), "Herbalism logged in full")
check(logged("skill 186 %(Mining%): nil"), "...Mining absent, said so")
check(logged("race Orc"), "...the race")
check(logged("Cultivation 20552: known false") and logged("Cultivation 1312643: known false"), "...both Cultivation IDs")

-- The hover waits for a node NodeRadar knows: not nothing, not another object.
poll()
eq(record("skill").at, 2, "waits with nothing under the cursor")
WoW.worldTooltip = { { "Mailbox", WHITE } }
poll()
eq(record("skill").at, 2, "...nor on an object that isn't a node")
WoW.worldTooltip = { { "Silverleaf", WHITE }, { "Requires Herbalism (50)", RED } }
poll()
settle()
eq(result("skill", 2).status, "done", "a node under the cursor completes it")
eq(db.skillTooltips[1].label, "above", "...its tooltip saved")
eq(db.skillTooltips[1].lines[2], "Requires Herbalism (50) [ff2121]", "...each line with its colour")
check(logged("world tooltip, above: Silverleaf %[ffffff%] | Requires Herbalism"), "...and logged")

WoW.fire("UI_ERROR_MESSAGE", 51, "Requires Herbalism 50")
eq(result("skill", 3).status, "event", "the refusal completes the gather step")
check(logged("UI_ERROR_MESSAGE type=51 message=Requires Herbalism 50"), "...the boot frame logs its type")
S.Answer(false)                                            -- 4: it didn't gather

WoW.worldTooltip = { { "Wilted Peacebloom", WHITE } }
poll()
settle()
eq(result("skill", 5).status, "done", "a gatherable node's tooltip")
eq(db.skillTooltips[2].label, "gatherable", "...saved after the first")

poll()
eq(record("skill").at, 6, "waits for a skill-up")
WoW.skillLines[182].modifier = 5                           -- gear changes the bonus, not the rank
poll()
eq(record("skill").at, 6, "...a bonus alone isn't a skill-up")
WoW.skillLines[182].rank = 41
WoW.fire("SKILL_LINES_CHANGED")
check(logged("SKILL_LINES_CHANGED: Herbalism 41%+5/75, Mining none"), "the event logs the ranks")
poll()
eq(result("skill", 6).status, "done", "the skill-up completes it")
check(tostring(result("skill", 6).detail):find("Herbalism 41+5/75, Mining none", 1, true), "...with the new rank")
fp("steps stop")

-- A secret skill line never throws and never reads as a number.
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = WoW.Secret("rank"), modifier = WoW.Secret("mod"),
                        maxRank = 75 }
WoW.worldTooltip = nil
fp("steps nr skill")
eq(result("skill", 1).status, "done", "a secret skill still completes the read")
check(tostring(result("skill", 1).detail):find("Herbalism nil+nil/75 (secret), Mining none", 1, true),
    "...said secret, no number: " .. tostring(result("skill", 1).detail))
fp("steps stop")
WoW.skillLines[182] = { skillID = 182, name = "Herbalism", rank = 41, modifier = 0, maxRank = 75 }

--------------------------------------------------------------------------------
-- cultivation
--------------------------------------------------------------------------------

WoW.race = { "Tauren", "Tauren", 6 }
WoW.knownSpells[20552] = true
fp("steps nr cultivation")
eq(result("cultivation", 1).status, "done", "cultivation: read on arrival")
check(logged("Cultivation 20552: known true"), "...20552 known")
local before = #db.log
poll()
poll()
eq(record("cultivation").at, 2, "waits for the cast")
eq(#db.log, before, "...quietly: no line per poll")
WoW.spellCooldowns[1312643] = { startTime = 100, duration = 900, isEnabled = true, isActive = true, modRate = 1 }
poll()
eq(result("cultivation", 2).status, "done", "a cooldown running completes it")
check(tostring(result("cultivation", 2).detail):find("1312643 cooling"), "...naming the ID that cools")
poll()
eq(record("cultivation").at, 3, "waits for combat")
WoW.combat = true
WoW.spellCooldowns[1312643] = { startTime = WoW.Secret("start"), duration = WoW.Secret("dur"),
                                isEnabled = true, isActive = WoW.Secret("active"), modRate = 1 }
poll()
eq(result("cultivation", 3).status, "done", "in combat: read")
check(tostring(result("cultivation", 3).detail):find("1312643: .*<secret>"), "...a secret cooldown shown as secret")
WoW.combat = false
fp("steps stop")

-- A secret cooldown completes the cast step too (that's the finding).
fp("steps nr cultivation")
poll()
eq(result("cultivation", 2).status, "done", "a secret cooldown completes the cast step")
check(tostring(result("cultivation", 2).detail):find("cooldown secret"), "...saying so")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
check(NR.db ~= nil, "NodeRadar loaded beside the probe")

done("test_probe_skill")
