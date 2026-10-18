-- Only nodes the player can gather (#26): a node whose known requirement is
-- above the player's skill (rank + bonus) neither alerts nor spends the
-- cooldown; anything unknown or unreadable alerts. Herbs above the skill still
-- alert while the Tauren's Cultivation is ready, its state read only on
-- SPELL_UPDATE_COOLDOWN. The setting, /nr skill and the Options checkbox.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local LIB = { enUS = { ["Peacebloom"] = "herbs", ["Mageroyal"] = "herbs", ["Briarthorn"] = "herbs",
                       ["Tin Vein"] = "ore", ["Lone Herb"] = "herbs", ["Odd Herb"] = "herbs" } }
local NR = loadAddon({ library = LIB })
NR.NODE_INFO = { enUS = { ["Peacebloom"] = { skill = 1, item = 2447 }, ["Mageroyal"] = { skill = 50, item = 785 },
                          ["Briarthorn"] = { skill = 70, item = 2450 }, ["Tin Vein"] = { skill = 65, item = 2771 },
                          ["Odd Herb"] = { item = 1 } } }
NR.db.learn = false
local Alert = NR.Alert
local db = NR.db

local HERB, MINING = 182, 186
local function skill(line, rank, modifier)
    WoW.skillLines[line] = { skillID = line, rank = rank, modifier = modifier or 0, maxRank = 300 }
end
skill(HERB, 40)
skill(MINING, 40)

-- One sweep's result: one blip per name given.
local function result(names)
    local byName = {}
    for _, n in ipairs(names) do byName[n] = { { name = n, x = 0, y = 0 } } end
    return { byName = byName }
end
-- From a fresh area (every name in view is a rise), well past any cooldown:
-- the names that alerted, as one string.
local t = 1000
local function fresh(names)
    t = t + 100
    WoW.now = t
    Alert.NewArea(t)
    local fired = Alert.Update(result(names), t)
    return fired and table.concat(fired, ",") or "nothing"
end

eq(db.skillOnly, true, "on by default")
eq(rawget(db, "skillOnly"), nil, "...and not saved until the player sets it")

-- The rule.
eq(fresh({ "Mageroyal" }), "nothing", "a node above the skill (50 at 40): no alert")
eq(fresh({ "Peacebloom" }), "Peacebloom", "one within it: alerts")
skill(HERB, 50)
eq(fresh({ "Mageroyal" }), "Mageroyal", "at exactly the requirement: alerts")
skill(HERB, 45, 5)
eq(fresh({ "Mageroyal" }), "Mageroyal", "the bonus counts (45 + 5)")
skill(HERB, 45, 4)
eq(fresh({ "Mageroyal" }), "nothing", "...45 + 4 doesn't reach it")
eq(fresh({ "Lone Herb" }), "Lone Herb", "no info: alerts")
eq(fresh({ "Odd Herb" }), "Odd Herb", "info without a skill: alerts")
eq(fresh({ "Tin Vein" }), "nothing", "ore reads Mining (40, needs 65)")
skill(MINING, 65)
eq(fresh({ "Tin Vein" }), "Tin Vein", "...and alerts at 65")

-- Unreadable skills alert.
WoW.skillLines[HERB] = nil
eq(fresh({ "Mageroyal" }), "Mageroyal", "no Herbalism line: alerts")
WoW.skillLines[HERB] = { rank = WoW.Secret("rank"), modifier = 0 }
eq(fresh({ "Mageroyal" }), "Mageroyal", "a secret rank: alerts, and nothing threw")
WoW.skillLines[HERB] = { rank = 10, modifier = WoW.Secret("bonus") }
eq(fresh({ "Mageroyal" }), "Mageroyal", "a secret bonus: alerts (it might reach)")
WoW.skillLines[HERB] = "throw"
eq(fresh({ "Mageroyal" }), "Mageroyal", "a throw: alerts")
skill(HERB, 40)

-- A learned kind that disagrees with the library: the library's info doesn't apply.
db.learned.enUS = { ["Mageroyal"] = { kind = "ore", source = "gather", build = "70450" } }
eq(NR.Learn.Info("Mageroyal"), nil, "a learned kind disagreeing: no info")
eq(fresh({ "Mageroyal" }), "Mageroyal", "...so it alerts")
db.learned.enUS = { ["Mageroyal"] = { kind = "herbs", source = "gather", build = "70450" } }
eq(NR.Learn.Info("Mageroyal").skill, 50, "a learned kind agreeing: the info applies")
db.learned.enUS = { ["Mageroyal"] = { kind = false, source = "toggle", build = "70450" } }
eq(NR.Learn.Info("Mageroyal"), nil, "learned 'not a node': no info")
eq(fresh({ "Mageroyal" }), "nothing", "...and not a node: never alerts")
db.learned.enUS = {}

-- The setting off: every node alerts.
db.skillOnly = false
eq(fresh({ "Mageroyal" }), "Mageroyal", "the setting off: alerts")
db.skillOnly = nil

-- A mixed rise alerts for the gatherable name only.
eq(fresh({ "Mageroyal", "Peacebloom" }), "Peacebloom", "mixed: only the one within the skill")

-- A rise of only unreachable names spends no cooldown.
t = t + 100
WoW.now = t
Alert.NewArea(t)
eq(Alert.Update(result({ "Mageroyal" }), t), nil, "Mageroyal rises: nothing")
eq(table.concat(Alert.Update(result({ "Mageroyal", "Peacebloom" }), t + 1) or {}, ","), "Peacebloom",
    "...and a Peacebloom a second later still alerts")

-- A skill-up alone doesn't make a node already on the map new.
t = t + 100
WoW.now = t
Alert.NewArea(t)
Alert.Update(result({ "Mageroyal" }), t)
skill(HERB, 60)
eq(Alert.Update(result({ "Mageroyal" }), t + 10), nil, "a skill-up: the Mageroyal already counted doesn't alert")
skill(HERB, 40)

--------------------------------------------------------------------------------
-- Cultivation (20552): herbs above the skill alert while it's ready.
--------------------------------------------------------------------------------

local CULT = 20552
local function cooldown(cd)
    WoW.spellCooldowns[CULT] = cd
    WoW.fire("SPELL_UPDATE_COOLDOWN")
end
eq(fresh({ "Mageroyal" }), "nothing", "not a Tauren: no help")
WoW.knownSpells[CULT] = true
eq(fresh({ "Mageroyal" }), "Mageroyal", "known, no event yet: ready, so herbs above the skill alert")
skill(MINING, 40)
eq(fresh({ "Tin Vein" }), "nothing", "...never ore (Tin Vein 65 at Mining 40)")
cooldown({ startTime = t, duration = 1.5, isEnabled = true, isActive = true, isOnGCD = true, modRate = 1 })
eq(fresh({ "Mageroyal" }), "Mageroyal", "only the global cooldown: still ready")
cooldown({ startTime = t + 100, duration = 900, isEnabled = true, isActive = true, isOnGCD = false, modRate = 1 })
eq(fresh({ "Mageroyal" }), "nothing", "on its 15-minute cooldown: herbs above the skill filtered")
eq(fresh({ "Peacebloom" }), "Peacebloom", "...herbs within it still alert")
t = t + 900
eq(fresh({ "Mageroyal" }), "Mageroyal", "the cooldown's end passed, no event since: ready again")
-- In combat the durations are secret: cooling until the next event says otherwise.
cooldown({ startTime = WoW.Secret("start"), duration = WoW.Secret("dur"), isEnabled = true, isActive = true,
           isOnGCD = false, modRate = WoW.Secret("rate") })
eq(fresh({ "Mageroyal" }), "nothing", "cooling with secret durations: filtered")
t = t + 5000
eq(fresh({ "Mageroyal" }), "nothing", "...until an event, however long")
cooldown({ startTime = 0, duration = 0, isEnabled = true, isActive = false, modRate = 1 })
eq(fresh({ "Mageroyal" }), "Mageroyal", "an event says it's ready: alerts")
-- Unreadable answers count as ready.
cooldown({ startTime = t, duration = 900, isEnabled = true, isActive = true, isOnGCD = false, modRate = 1 })
cooldown({ startTime = t, duration = 900, isEnabled = true, isActive = true, modRate = 1 })
eq(fresh({ "Mageroyal" }), "Mageroyal", "no isOnGCD: unknown, so ready")
cooldown({ startTime = t, duration = 900, isEnabled = true, isActive = true, isOnGCD = "yes", modRate = 1 })
eq(fresh({ "Mageroyal" }), "Mageroyal", "a non-boolean isOnGCD: ready")
cooldown("throw")
eq(fresh({ "Mageroyal" }), "Mageroyal", "a throw: ready")
cooldown({ startTime = t, duration = 900, isEnabled = true, isActive = WoW.Secret("active"), isOnGCD = false, modRate = 1 })
eq(fresh({ "Mageroyal" }), "Mageroyal", "a secret isActive: ready")
-- Forgetting it (another character): no help, whatever the state.
cooldown({ startTime = 0, duration = 0, isEnabled = true, isActive = false, modRate = 1 })
WoW.knownSpells[CULT] = nil
eq(fresh({ "Mageroyal" }), "nothing", "not known: no help even when 'ready'")

--------------------------------------------------------------------------------
-- /nr skill and the Options checkbox
--------------------------------------------------------------------------------

local O = NR.Options._test
O.panel:Show()
local cb = O.checks.skillOnly
check(cb, "an Options checkbox for it")
eq(cb:GetChecked(), true, "...checked by default")
SlashCmdList.NODERADAR("skill")
eq(db.skillOnly, false, "/nr skill turns it off (db.skillOnly, not db.skill)")
eq(rawget(db, "skill"), nil, "...writes no stray setting")
O.panel:Hide()
O.panel:Show()
eq(cb:GetChecked(), false, "...and the checkbox agrees")
WoW.click(cb)
eq(rawget(db, "skillOnly"), true, "a click turns it back on, saved")
SlashCmdList.NODERADAR("status")
check(chatHas("only nodes you can gather"), "/nr status shows it")
SlashCmdList.NODERADAR("help")
check(chatHas("/nr skill"), "/nr help lists it")

eq(next(NR.failures), nil, "no failure recorded: " .. tostring(next(NR.failures)))
checkMethods({})

done("test_skill")
