-- Learn: which names are nodes. The library and gathering casts; the toggle
-- experiment end to end on the stubbed client (a herb blip shows only while
-- its tracking is on, as measured in round 3); every case the plan's review
-- raised: a name that never comes back, a failed sweep, tracking that stays on,
-- a cast, combat, death, movement, a zone change or a loading screen between
-- off and on, the player changing tracking, a reload, a restore that never
-- succeeds, the gamepad; and both gathering trackings on.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local NR = loadAddon()
local Learn = NR.Learn

-- Every SetTracking call, in order.
local calls = {}
local realSet = C_Minimap.SetTracking
C_Minimap.SetTracking = function(i, on)
    calls[#calls + 1] = { i, on }
    return realSet(i, on)
end

WoW.tracking[1].active = true                              -- Find Herbs
local QUEST = { "Carry Your Weight", 80, -80 }

-- A quiet map, past the gap since the last experiment; then the blips.
local function ready(blips)
    WoW.blips = {}
    WoW.advance(11)
    check(not Learn.Busy(), "(no experiment left running)")
    calls = {}
    WoW.blips = blips
end

-- Advance until an experiment starts (the next radar sweep).
local function start()
    for _ = 1, 10 do
        WoW.advance(0.1)
        if Learn.Busy() then return true end
    end
    return false
end

local function herbsOn() return WoW.tracking[1].active == true end

local function turnedOn()
    for _, c in ipairs(calls) do if c[2] == true then return true end end
    return false
end

--------------------------------------------------------------------------------
-- The library and gathering
--------------------------------------------------------------------------------

eq(Learn.Kind("Wilted Peacebloom"), "herbs", "the shipped library knows Wilted Peacebloom")
eq(Learn.Kind("Earthroot"), nil, "an unknown name")
WoW.locale = "deDE"
eq(Learn.Kind("Wilted Peacebloom"), nil, "the library is per locale")
WoW.locale = "enUS"

WoW.fire("UNIT_SPELLCAST_SENT", "player", "Copper Vein", "Cast-1", 2575)
eq(Learn.Kind("Copper Vein"), "ore", "Mining's target learned as ore")
eq(NR.db.learned.enUS["Copper Vein"].source, "gather", "...from gathering")
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Mageroyal", "Cast-2", 2368)
eq(Learn.Kind("Mageroyal"), "herbs", "another rank of Herb Gathering, by its name")
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Mottled Boar", "Cast-3", 116)
eq(Learn.Kind("Mottled Boar"), nil, "a Frostbolt's target isn't a node")
WoW.fire("UNIT_SPELLCAST_SENT", "player", WoW.Secret("t"), "Cast-4", 2366)
WoW.fire("UNIT_SPELLCAST_SENT", "party1", "Peacebloom", "Cast-5", 2366)
eq(Learn.Kind("Peacebloom"), nil, "a secret target, or someone else's cast, learns nothing")
-- Gathering beats the toggle, both ways.
Learn.Record("Kingsblood", false, "toggle")
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Kingsblood", "Cast-6", 2366)
eq(Learn.Kind("Kingsblood"), "herbs", "gathering overrides a toggle's 'not a node'")
eq(Learn.Record("Kingsblood", false, "toggle"), false, "...and a toggle never overrides gathering")
eq(Learn.Kind("Kingsblood"), "herbs", "...still herbs")
Learn.Forget("Kingsblood")
eq(Learn.Kind("Kingsblood"), nil, "forget")

--------------------------------------------------------------------------------
-- The experiment
--------------------------------------------------------------------------------

-- The good case: the herb vanishes and comes back; the quest stays.
ready({ { "Earthroot", 30, -20, kind = "herbs" }, QUEST })
check(start(), "an unknown name starts an experiment")
eq(herbsOn(), false, "...Find Herbs off")
eq(NR.charDb.pendingRestore, 2383, "...the restore saved first")
WoW.advance(6)
eq(Learn.Kind("Earthroot"), "herbs", "the herb learned (gone with tracking off, back after)")
eq(NR.db.learned.enUS.Earthroot.source, "toggle", "...from the toggle")
eq(Learn.Kind("Carry Your Weight"), false, "the quest learned as not a node (it stayed)")
check(herbsOn(), "Find Herbs back on")
eq(NR.charDb.pendingRestore, nil, "the pending restore cleared")
eq(calls[1][2], false, "...off, then")
eq(calls[2][2], true, "...on")
Learn.Forget("Carry Your Weight")

-- Nothing to learn: no experiment.
ready({ { "Earthroot", 30, -20, kind = "herbs" } })
check(not start(), "known names start nothing")

-- Each case: the name, what happens between off and on, and the checks.
local function case(name, between, after)
    ready({ { name, 30, -20, kind = "herbs" }, QUEST })
    check(start(), name .. ": started")
    between()
    WoW.advance(6)
    after()
    Learn.Forget(name)
    Learn.Forget("Carry Your Weight")
end

case("Briarthorn", function()
    WoW.advance(1.6)                                       -- the middle sweep done
    WoW.blips = { QUEST }                                  -- gathered by someone else
end, function()
    eq(Learn.Kind("Briarthorn"), nil, "a herb that never comes back stays unknown")
    check(herbsOn(), "...tracking back on")
end)

case("Swiftthistle", function()
    WoW.mouseoverThrows = true
    WoW.advance(1.6)
    WoW.mouseoverThrows = false
end, function()
    eq(Learn.Kind("Swiftthistle"), nil, "a failed middle sweep learns nothing")
    eq(Learn.Kind("Carry Your Weight"), nil, "...not even the quest")
    check(herbsOn(), "...tracking back on")
end)

WoW.refuseTrackingOff = true
case("Bruiseweed", function() end, function()
    eq(Learn.Kind("Bruiseweed"), nil, "tracking that stays on learns nothing")
    eq(NR.charDb.pendingRestore, nil, "...and leaves no restore pending")
end)
WoW.refuseTrackingOff = false

case("Wild Steelbloom", function()
    WoW.casting = "Fireball"
    WoW.advance(2)
    eq(herbsOn(), false, "no restore while casting")
    check(not turnedOn(), "...not even tried")
    WoW.casting = nil
end, function()
    check(herbsOn(), "restored once the cast ended")
    eq(Learn.Kind("Wild Steelbloom"), "herbs", "...and still learned (a cast voids nothing)")
end)

case("Grave Moss", function()
    WoW.combat = true
    WoW.advance(2)
    eq(herbsOn(), false, "no restore in combat")
    WoW.combat = false
    WoW.fire("PLAYER_REGEN_ENABLED")
end, function()
    check(herbsOn(), "restored after combat")
end)

case("Liferoot", function()
    WoW.dead = true
    WoW.fire("PLAYER_DEAD")
    WoW.advance(2)
    eq(herbsOn(), false, "no restore while dead")
    WoW.dead = false
end, function()
    eq(Learn.Kind("Liferoot"), nil, "death voids the experiment")
    check(herbsOn(), "...restored once alive")
end)

case("Fadeleaf", function()
    WoW.advance(0.3)
    WoW.speed = 7
    WoW.advance(0.2)
    WoW.speed = 0                                          -- moved and stopped between steps
end, function()
    eq(Learn.Kind("Fadeleaf"), nil, "moving at any moment voids it")
    check(herbsOn(), "...restored")
end)

case("Goldthorn", function() WoW.fire("ZONE_CHANGED_NEW_AREA") end, function()
    eq(Learn.Kind("Goldthorn"), nil, "a zone change voids it")
    check(herbsOn(), "...restored")
end)

case("Khadgar's Whisker", function()
    WoW.fire("LOADING_SCREEN_ENABLED")
    WoW.advance(2)
    eq(herbsOn(), false, "no restore during a loading screen")
    WoW.fire("LOADING_SCREEN_DISABLED")
end, function()
    eq(Learn.Kind("Khadgar's Whisker"), nil, "a loading screen voids it")
    check(herbsOn(), "...restored after it")
end)

case("Firebloom", function()
    WoW.advance(1.2)
    WoW.tracking[1].active = true                          -- the player turns it back on
    WoW.fire("MINIMAP_UPDATE_TRACKING")
end, function()
    eq(Learn.Kind("Firebloom"), nil, "the player turning tracking on voids it")
    check(not turnedOn(), "...and we never cast it again")
    check(herbsOn(), "...it's on, the player's way")
end)

WoW.tracking[2].active = true                              -- the Auctioneer, a town tracker
case("Purple Lotus", function()
    WoW.tracking[2].active = false                         -- the player turns it off
    WoW.fire("MINIMAP_UPDATE_TRACKING")
end, function()
    eq(Learn.Kind("Purple Lotus"), nil, "the player changing another tracking voids it")
    eq(WoW.tracking[2].active, false, "...and that tracking is left as they set it")
    check(herbsOn(), "...ours restored")
end)

case("Arthas' Tears", function()
    WoW.advance(0.3)
    WoW.cvars.GamePadEnable = "1"
end, function()
    WoW.cvars.GamePadEnable = nil
    eq(Learn.Kind("Arthas' Tears"), nil, "the gamepad coming on voids it")
    check(herbsOn(), "...restored")
end)

-- The player turns tracking off after our restore: theirs to keep off.
ready({ { "Sungrass", 30, -20, kind = "herbs" }, QUEST })
check(start(), "Sungrass: started")
WoW.advance(2.2)                                           -- off, middle, restored
check(herbsOn(), "restored")
WoW.advance(1.2)
WoW.tracking[1].active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.advance(5)
eq(herbsOn(), false, "a tracking the player turned off after our restore stays off")
eq(NR.charDb.pendingRestore, nil, "...with no restore pending")
check(not Learn.Busy(), "...the experiment over")
WoW.tracking[1].active = true
Learn.Forget("Carry Your Weight")

-- (Codex on #9) The player turns it off within a second of our confirmed restore:
-- still theirs, never cast again.
ready({ { "Peacebloom", 30, -20, kind = "herbs" }, QUEST })
check(start(), "Peacebloom: started")
WoW.advance(1.6)                                           -- off, middle, restore called
check(herbsOn(), "restored")
WoW.advance(0.2)                                           -- the restore seen
calls = {}
WoW.tracking[1].active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.advance(5)
eq(herbsOn(), false, "turned off 0.2 s after our restore: stays off")
eq(#calls, 0, "...no SetTracking at all")
eq(NR.charDb.pendingRestore, nil, "...no restore pending")
check(not Learn.Busy(), "...the experiment over")
WoW.tracking[1].active = true
Learn.Forget("Carry Your Weight")

-- The same when the tick sees it off before the event comes.
ready({ { "Peacebloom", 30, -20, kind = "herbs" }, QUEST })
check(start(), "Peacebloom again: started")
WoW.advance(1.8)
check(herbsOn(), "restored")
calls = {}
WoW.tracking[1].active = false                             -- no event yet
WoW.advance(5)
eq(herbsOn(), false, "seen off by the tick after our restore: stays off")
eq(#calls, 0, "...no SetTracking at all")
WoW.tracking[1].active = true
Learn.Forget("Carry Your Weight")

-- And after a reload's restore.
ready({})
WoW.tracking[1].active = false
NR.charDb.pendingRestore = 2383
WoW.fire("PLAYER_ENTERING_WORLD", false, true)
WoW.advance(0.3)
check(herbsOn(), "the reload's restore ran")
calls = {}
WoW.tracking[1].active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.advance(5)
eq(herbsOn(), false, "turned off right after a reload's restore: stays off")
eq(#calls, 0, "...no SetTracking at all")
eq(NR.charDb.pendingRestore, nil, "...nothing pending")
WoW.tracking[1].active = true

-- A restore that never succeeds: said in chat, and retried until it does.
WoW.refuseTrackingOn = true
ready({ { "Ghost Mushroom", 30, -20, kind = "herbs" }, QUEST })
newChat()
check(start(), "Ghost Mushroom: started")
WoW.advance(13)
local said = false
for _, l in ipairs(newChat()) do if l:find("turned Find Herbs off to learn a node and couldn't turn it back on") then said = true end end
check(said, "a failed restore is said in chat, naming the tracking")
WoW.refuseTrackingOn = false
WoW.advance(5)
check(herbsOn(), "...and restored once the client takes it")
Learn.Forget("Ghost Mushroom")
Learn.Forget("Carry Your Weight")

-- A reload between off and on: the next login restores it.
ready({})
WoW.tracking[1].active = false
NR.charDb.pendingRestore = 2383
WoW.fire("PLAYER_ENTERING_WORLD", false, true)
WoW.advance(4)
check(herbsOn(), "a pending restore runs at the next login")
eq(NR.charDb.pendingRestore, nil, "...and is cleared")
-- Another character's login doesn't touch it (the restore is per character).
WoW.tracking[1].active = false
NR.charDb = {}
WoW.fire("PLAYER_ENTERING_WORLD", false, true)
WoW.advance(4)
eq(herbsOn(), false, "another character has nothing pending: no restore")
WoW.tracking[1].active = true

-- The spell on cooldown, or learning off: no experiment.
WoW.cooling[2383] = true
ready({ { "Icecap", 30, -20, kind = "herbs" } })
check(not start(), "no experiment while the tracking spell is on cooldown")
WoW.cooling[2383] = nil
NR.db.learn = false
ready({ { "Icecap", 30, -20, kind = "herbs" } })
check(not start(), "no experiment with learning off")
NR.db.learn = true

--------------------------------------------------------------------------------
-- Both gathering trackings on: a name is "not a node" only once it survived both.
--------------------------------------------------------------------------------

table.insert(WoW.tracking, { name = "Find Minerals", spellID = 2580, active = true })
ready({ { "Tin Vein", -40, 50, kind = "ore" }, QUEST })
check(start(), "both on: an experiment")
WoW.advance(6)
eq(Learn.Kind("Tin Vein"), nil, "toggling herbs: the ore stayed, not yet known")
eq(Learn.Kind("Carry Your Weight"), nil, "...the quest too: ore not tried yet")
ready({ { "Tin Vein", -40, 50, kind = "ore" }, QUEST })
check(start(), "...a second experiment")
eq(WoW.tracking[3].active, false, "...toggling Find Minerals this time")
WoW.advance(6)
eq(Learn.Kind("Tin Vein"), "ore", "the ore learned on the Find Minerals toggle")
eq(Learn.Kind("Carry Your Weight"), false, "the quest, having survived both, is not a node")
check(WoW.tracking[1].active and WoW.tracking[3].active, "both trackings on at the end")

eq(WoW.softCursor, false, "the soft cursor off at the end")
done("test_learn")
