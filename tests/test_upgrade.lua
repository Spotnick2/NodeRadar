-- Upgrade: the first port (#9) saved every default, learning on and a 0.5 s
-- interval among them. They're dropped once, so today's defaults apply; what
-- the player changed is kept, and so is what they set after the upgrade.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- NodeRadarDB as #9's initializer left it, with two settings the player changed.
local NR = loadAddon({ db = { enabled = true, sound = true, ring = true, chat = true, ping = false,
    learn = true, cooldown = 12, interval = 0.5, learned = { enUS = { Peacebloom = { kind = "herbs", source = "gather" } } } } })
local db = NR.db
eq(rawget(db, "learn"), nil, "#9's saved learn = true dropped")
eq(db.learn, false, "...so learning reads today's default: off")
eq(rawget(db, "interval"), nil, "#9's saved 0.5 s interval dropped")
eq(db.interval, 2, "...so the idle cadence is today's 2 s")
eq(rawget(db, "sound"), nil, "an old default equal to today's: dropped too")
eq(db.sound, true, "...and still on")
eq(db.chat, true, "a setting the player changed: kept")
eq(db.cooldown, 12, "...another")
eq(db.learned.enUS.Peacebloom.kind, "herbs", "the learned names kept")
eq(db.schema, 2, "migrated once")

-- After the upgrade, the player turns learning on: the next login keeps it.
SlashCmdList.NODERADAR("learn")
eq(rawget(db, "learn"), true, "/nr learn saves it")
WoW.fire("ADDON_LOADED", "NodeRadar")                      -- the next login, same saved table
eq(db.learn, true, "...and the next login keeps it (no second migration)")

eq(next(NR.failures), nil, "no failure: " .. tostring(next(NR.failures)))
done("test_upgrade")
